# frozen_string_literal: true

require "anthropic"
require "base64"
require "json"

# Ranks candidate cover images using a single batched Claude vision call.
# Each candidate gets a combined score (fits_fairytale_cover + matches_episode_description),
# with hard veto flags (has_watermark, !composition_ok) and a tie-breaker
# bonus for has_title_text.
#
# Returned candidates preserve the original metadata from ImageSearcher and
# add: :score (Integer 2-20), :has_title_text, :has_watermark, :composition_ok,
# :reasons (String), :vetoed (Boolean — true if watermark or bad composition).
#
# Sort order: vetoed last; among non-vetoed, has_title_text first, then
# score DESC.
class ImageRanker
  DEFAULT_MODEL = "claude-sonnet-4-6"
  MEDIA_TYPES = {
    ".jpg"  => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png"  => "image/png",
    ".webp" => "image/webp",
    ".gif"  => "image/gif"
  }.freeze

  def initialize(model: nil, logger: nil)
    @model = model || DEFAULT_MODEL
    @client = Anthropic::Client.new
    @logger = logger
  end

  def rank(candidates, title:, description:)
    return [] if candidates.nil? || candidates.empty?

    response = @client.messages.create(
      model: @model,
      max_tokens: 2000,
      messages: [{ role: "user", content: build_content(candidates, title, description) }]
    )

    parsed = parse_response(response)
    return [] if parsed.nil?

    annotated = candidates.each_with_index.map do |c, i|
      r = parsed.find { |row| row["index"] == i } || {}
      score = r["fits_fairytale_cover"].to_i + r["matches_episode_description"].to_i
      vetoed = r["has_watermark"] || r["composition_ok"] == false
      c.merge(
        score: score,
        has_title_text: r["has_title_text"] == true,
        has_watermark: r["has_watermark"] == true,
        composition_ok: r["composition_ok"] != false,
        reasons: r["reasons"].to_s,
        vetoed: !!vetoed
      )
    end

    annotated.sort_by.with_index do |c, i|
      [c[:vetoed] ? 1 : 0, c[:has_title_text] ? 0 : 1, -c[:score], i]
    end
  end

  private

  def build_content(candidates, title, description)
    blocks = [{ type: "text", text: prompt_intro(title, description, candidates.length) }]
    candidates.each_with_index do |c, i|
      blocks << { type: "text", text: "Image #{i} (index #{i}):" }
      blocks << {
        type: "image",
        source: {
          type: "base64",
          media_type: media_type_for(c[:ext]),
          data: Base64.strict_encode64(File.binread(c[:path]))
        }
      }
    end
    blocks << { type: "text", text: prompt_schema }
    blocks
  end

  def prompt_intro(title, description, n)
    <<~TEXT
      You are evaluating #{n} candidate image#{n == 1 ? "" : "s"} for use as cover art for a podcast episode.

      Episode title: #{title}
      Episode description: #{description.to_s.empty? ? "(none)" : description}

      For each image evaluate:
      1. fits_fairytale_cover (1-10): Does it look like illustration suitable for a children's fairytale podcast cover? Higher for evocative illustrations; lower for stock photos, screenshots, clipart, or unrelated content.
      2. matches_episode_description (1-10): How well does the image content match the episode title and description?
      3. has_title_text (boolean): Does the image already contain visible text matching or related to the episode title? (Bonus if true.)
      4. has_watermark (boolean): Does the image contain a watermark, logo overlay, or copyright notice that would be ugly on a cover? (Veto if true.)
      5. composition_ok (boolean): Is the composition usable for a square or near-square cover — clear focal point, not extreme aspect ratio, not visually cluttered? (Veto if false.)
      6. reasons: one short sentence explaining your scoring.
    TEXT
  end

  def prompt_schema
    <<~TEXT
      Return ONLY valid JSON, no prose, no markdown fences. Schema:
      {
        "rankings": [
          {
            "index": 0,
            "fits_fairytale_cover": 8,
            "matches_episode_description": 9,
            "has_title_text": false,
            "has_watermark": false,
            "composition_ok": true,
            "reasons": "..."
          }
        ]
      }
    TEXT
  end

  def media_type_for(ext)
    MEDIA_TYPES[ext.to_s.downcase] || "image/jpeg"
  end

  def parse_response(response)
    text = response.content.first.text rescue nil
    return nil unless text
    json = text.strip.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\z/, "")
    data = JSON.parse(json)
    data["rankings"]
  rescue JSON::ParserError => e
    log("malformed JSON: #{e.message}")
    nil
  end

  def log(msg)
    @logger&.log("[ImageRanker] #{msg}")
  end
end
