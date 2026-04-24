# frozen_string_literal: true

require "httparty"
require "json"
require_relative "../loggable"
require_relative "../retryable"
require_relative "../http_retryable"

class LingQAgent
  include Loggable
  include Retryable
  include HttpRetryable

  BASE_URL = "https://www.lingq.com/api"
  MAX_RETRIES = 3

  def initialize(logger: nil, api_key: nil)
    @logger = logger
    @api_key = api_key || ENV.fetch("LINGQ_API_KEY") { raise "LINGQ_API_KEY not set (use ## LingQ token: or LINGQ_API_KEY env var)" }
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
    body[:accent] = accent if accent
    body[:description] = description if description
    body[:originalUrl] = original_url if original_url

    # Build multipart form
    body[:audio] = File.open(audio_path, "rb")
    body[:image] = File.open(image_path, "rb") if image_path && File.exist?(image_path)

    url = "#{BASE_URL}/v3/#{language}/lessons/"
    lesson_id = post_with_retry(url, body)

    elapsed = (Time.now - start).round(2)
    log("Lesson created: ID #{lesson_id} (#{elapsed}s)")

    # Set tags via PATCH (multipart form sends tags[] which LingQ ignores)
    patch_tags(language, lesson_id, tags) if tags&.any?

    # Trigger timestamp generation (non-fatal)
    generate_timestamps(language, lesson_id)

    lesson_id
  ensure
    body[:audio]&.close if body.is_a?(Hash) && body[:audio].respond_to?(:close)
    body[:image]&.close if body.is_a?(Hash) && body[:image].respond_to?(:close)
  end

  private

  def format_text(text)
    text.gsub(/\*\*([^*]+)\*\*/, '\1').split("\n").reject(&:empty?).join("\n")
  end

  def post_with_retry(url, body)
    with_retries(max: MAX_RETRIES, on: HTTP_EXCEPTIONS) do
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
    end
  end

  def patch_tags(language, lesson_id, tags)
    url = "#{BASE_URL}/v3/#{language}/lessons/#{lesson_id}/"
    response = HTTParty.patch(
      url,
      headers: {
        "Authorization" => "Token #{@api_key}",
        "Content-Type" => "application/json"
      },
      body: { tags: tags }.to_json,
      timeout: 30
    )
    log("Tags set: #{tags.join(', ')}") if response.code.between?(200, 299)
  rescue => e
    log("Warning: setting tags failed: #{e.message} (non-fatal)")
  end

  def generate_timestamps(language, lesson_id)
    url = "#{BASE_URL}/v3/#{language}/lessons/#{lesson_id}/timestamps/"
    log("Requesting timestamp generation for lesson #{lesson_id}")

    with_retries(max: MAX_RETRIES, on: HTTP_EXCEPTIONS) do
      response = HTTParty.post(
        url,
        headers: {
          "Authorization" => "Token #{@api_key}",
          "Content-Type" => "application/json"
        },
        body: "[]",
        timeout: 30
      )

      case response.code
      when 200..299
        log("Timestamp generation triggered")
      when *RETRIABLE_CODES
        raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
      else
        log("Warning: timestamp generation returned HTTP #{response.code}: #{parse_error(response)} (non-fatal)")
      end
    end
  rescue => e
    log("Warning: timestamp generation failed: #{e.message} (non-fatal)")
  end

end
