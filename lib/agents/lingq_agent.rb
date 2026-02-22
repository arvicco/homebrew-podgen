# frozen_string_literal: true

require "httparty"
require "json"

class LingQAgent
  BASE_URL = "https://www.lingq.com/api"
  MAX_RETRIES = 3
  RETRIABLE_CODES = [429, 503].freeze

  def initialize(logger: nil)
    @logger = logger
    @api_key = ENV.fetch("LINGQ_API_KEY") { raise "LINGQ_API_KEY environment variable is not set" }
  end

  # Upload a lesson to LingQ.
  # Required: title, text, audio_path, language (ISO-639-1 code)
  # Optional: collection, level, tags, image_path, accent, status, description, original_url
  def upload(title:, text:, audio_path:, language:, collection: nil, level: nil,
             tags: nil, image_path: nil, accent: nil, status: nil, description: nil, original_url: nil)
    start = Time.now
    log("Uploading lesson: \"#{title}\" (language: #{language})")

    formatted_text = format_text(text)

    body = {
      title: title,
      text: formatted_text,
      status: status || "private"
    }
    body[:collection] = collection if collection
    body[:level] = level.to_s if level
    body[:tags] = tags if tags&.any?
    body[:accent] = accent if accent
    body[:description] = description if description
    body[:original_url] = original_url if original_url

    # Build multipart form
    body[:audio] = File.open(audio_path, "rb")
    body[:image] = File.open(image_path, "rb") if image_path && File.exist?(image_path)

    url = "#{BASE_URL}/v3/#{language}/lessons/"
    lesson_id = post_with_retry(url, body)

    elapsed = (Time.now - start).round(2)
    log("Lesson created: ID #{lesson_id} (#{elapsed}s)")

    # Trigger timestamp generation (non-fatal)
    generate_timestamps(language, lesson_id)

    lesson_id
  ensure
    body[:audio]&.close if body.is_a?(Hash) && body[:audio].respond_to?(:close)
    body[:image]&.close if body.is_a?(Hash) && body[:image].respond_to?(:close)
  end

  private

  def format_text(text)
    text.split("\n").reject(&:empty?).join("\n")
  end

  def post_with_retry(url, body)
    retries = 0
    begin
      retries += 1

      response = HTTParty.post(
        url,
        headers: { "Authorization" => "Token #{@api_key}" },
        body: body,
        timeout: 120
      )

      case response.code
      when 201
        parsed = JSON.parse(response.body)
        parsed["id"]
      when *RETRIABLE_CODES
        raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
      else
        raise "LingQ upload failed: HTTP #{response.code}: #{parse_error(response)}"
      end

    rescue RetriableError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
      if retries <= MAX_RETRIES
        sleep_time = 2**retries
        log("Retry #{retries}/#{MAX_RETRIES} in #{sleep_time}s: #{e.message}")
        sleep(sleep_time)
        retry
      else
        raise "LingQ upload failed after #{MAX_RETRIES} retries: #{e.message}"
      end
    end
  end

  def generate_timestamps(language, lesson_id)
    url = "#{BASE_URL}/v3/#{language}/lessons/#{lesson_id}/timestamps/"
    log("Requesting timestamp generation for lesson #{lesson_id}")

    response = HTTParty.post(
      url,
      headers: {
        "Authorization" => "Token #{@api_key}",
        "Content-Type" => "application/json"
      },
      timeout: 30
    )

    if response.code >= 200 && response.code < 300
      log("Timestamp generation triggered")
    else
      log("Warning: timestamp generation returned HTTP #{response.code} (non-fatal)")
    end
  rescue => e
    log("Warning: timestamp generation failed: #{e.message} (non-fatal)")
  end

  def parse_error(response)
    parsed = JSON.parse(response.body)
    if parsed.is_a?(Hash)
      parsed["detail"] || parsed["message"] || parsed.to_s
    else
      parsed.to_s
    end
  rescue JSON::ParserError
    response.body[0..200]
  end

  def log(message)
    if @logger
      @logger.log("[LingQAgent] #{message}")
    else
      puts "[LingQAgent] #{message}"
    end
  end

  class RetriableError < StandardError; end
end
