# frozen_string_literal: true

require "uri"

module UrlCleaner
  TRACKING_PARAMS = %w[
    utm_source utm_medium utm_campaign utm_term utm_content utm_id
    fbclid gclid gclsrc dclid
    mc_cid mc_eid
    msclkid twclid
    _ga _gl
    ref src
  ].freeze

  TRACKING_PATTERN = /\A(#{TRACKING_PARAMS.map { |p| Regexp.escape(p) }.join("|")})\z/i

  def self.clean(url)
    uri = URI.parse(url)
    return url unless uri.query

    cleaned = URI.decode_www_form(uri.query)
      .reject { |k, _| k.match?(TRACKING_PATTERN) }

    uri.query = cleaned.empty? ? nil : URI.encode_www_form(cleaned)
    uri.fragment = nil if uri.fragment&.match?(/\A(:\~:text=|xtor=)/)
    uri.to_s
  rescue URI::InvalidURIError
    url
  end
end
