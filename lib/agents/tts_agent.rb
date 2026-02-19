# frozen_string_literal: true

require "httparty"
require "json"
require "fileutils"
require "tmpdir"

class TTSAgent
  BASE_URL = "https://api.elevenlabs.io/v1/text-to-speech"
  MAX_CHARS = 9_500 # Safety margin below eleven_multilingual_v2's 10,000 limit
  MAX_RETRIES = 3
  RETRIABLE_CODES = [429, 503].freeze

  def initialize(logger: nil, voice_id_override: nil)
    @logger = logger
    @api_key = ENV.fetch("ELEVENLABS_API_KEY") { raise "ELEVENLABS_API_KEY environment variable is not set" }
    @voice_id = voice_id_override || ENV.fetch("ELEVENLABS_VOICE_ID") { raise "ELEVENLABS_VOICE_ID environment variable is not set" }
    @model_id = ENV.fetch("ELEVENLABS_MODEL_ID", "eleven_multilingual_v2")
    @output_format = ENV.fetch("ELEVENLABS_OUTPUT_FORMAT", "mp3_44100_128")
  end

  # Input: array of { name:, text: } segment hashes
  # Output: ordered array of file paths to MP3 files
  def synthesize(segments)
    audio_paths = []
    previous_request_ids = []

    segments.each_with_index do |segment, idx|
      log("Synthesizing segment #{idx + 1}/#{segments.length}: #{segment[:name]} (#{segment[:text].length} chars)")
      start = Time.now

      chunks = split_text(segment[:text])

      chunks.each_with_index do |chunk, chunk_idx|
        log("  Chunk #{chunk_idx + 1}/#{chunks.length} (#{chunk.length} chars)") if chunks.length > 1

        audio_data, request_id = synthesize_chunk(
          text: chunk,
          previous_request_ids: previous_request_ids.last(3)
        )

        path = File.join(Dir.tmpdir, "podgen_#{idx}_#{chunk_idx}_#{Process.pid}.mp3")
        File.open(path, "wb") { |f| f.write(audio_data) }

        audio_paths << path
        previous_request_ids << request_id if request_id

        log("  Saved #{File.size(path)} bytes → #{path}")
      end

      elapsed = (Time.now - start).round(2)
      log("  Done in #{elapsed}s")
    end

    audio_paths
  end

  private

  def synthesize_chunk(text:, previous_request_ids: [])
    url = "#{BASE_URL}/#{@voice_id}?output_format=#{@output_format}"

    body = {
      text: text,
      model_id: @model_id,
      voice_settings: {
        stability: 0.5,
        similarity_boost: 0.75,
        style: 0.0,
        use_speaker_boost: true
      }
    }
    body[:previous_request_ids] = previous_request_ids unless previous_request_ids.empty?

    retries = 0
    begin
      retries += 1

      response = HTTParty.post(
        url,
        headers: {
          "xi-api-key" => @api_key,
          "Content-Type" => "application/json",
          "Accept" => "audio/mpeg"
        },
        body: body.to_json,
        timeout: 120
      )

      case response.code
      when 200
        [response.body, response.headers["request-id"]]
      when *RETRIABLE_CODES
        raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
      else
        raise "TTS failed: HTTP #{response.code}: #{parse_error(response)}"
      end

    rescue RetriableError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
      if retries <= MAX_RETRIES
        sleep_time = 2**retries
        log("  Retry #{retries}/#{MAX_RETRIES} in #{sleep_time}s: #{e.message}")
        sleep(sleep_time)
        retry
      else
        raise "TTS failed after #{MAX_RETRIES} retries: #{e.message}"
      end
    end
  end

  def split_text(text)
    return [text] if text.length <= MAX_CHARS

    chunks = []
    remaining = text.dup

    while remaining.length > MAX_CHARS
      split_at = remaining.rindex(/\n\n/, MAX_CHARS) ||
                 remaining.rindex(/(?<=[.!?])\s+/, MAX_CHARS) ||
                 remaining.rindex(/[,;:]\s+/, MAX_CHARS) ||
                 remaining.rindex(/\s+/, MAX_CHARS) ||
                 find_safe_split_point(remaining, MAX_CHARS)
      split_at = [split_at, 1].max

      chunks << remaining[0...split_at].strip
      remaining = remaining[split_at..].strip
    end

    chunks << remaining unless remaining.empty?
    chunks
  end

  # Walk backward from max_pos to find a safe split point that doesn't
  # break a multi-byte UTF-8 character or grapheme cluster.
  def find_safe_split_point(text, max_pos)
    pos = max_pos
    # Walk backward to find an ASCII char or whitespace boundary
    while pos > 0
      char = text[pos]
      break if char && (char.ascii_only? || char.match?(/\s/))
      pos -= 1
    end
    # If we walked all the way back, just use max_pos (degenerate case)
    pos > 0 ? pos : max_pos
  end

  def parse_error(response)
    parsed = JSON.parse(response.body)
    detail = parsed["detail"]
    detail.is_a?(Hash) ? "#{detail['code']}: #{detail['message']}" : detail.to_s
  rescue JSON::ParserError
    response.body[0..200]
  end

  def log(message)
    if @logger
      @logger.log("[TTSAgent] #{message}")
    else
      puts "[TTSAgent] #{message}"
    end
  end

  class RetriableError < StandardError; end
end
