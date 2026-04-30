# frozen_string_literal: true

require_relative "url_cleaner"

# Pure renderer: turns a structured script (the shape ScriptArtifact reads/writes)
# into the markdown view written to <basename>_script.md.
#
# Markdown is a derived view; the script JSON is the source of truth. This
# class exists so the markdown can be regenerated at any time (e.g. after
# changing ## Links config) without re-running script generation.
module ScriptRenderer
  # Render a script hash to a markdown string.
  # links_config shape (or nil to disable):
  #   { show: true, position: "inline" | "bottom", title: "More info"?, max: Integer? }
  def self.render(script, links_config: nil)
    position = links_config&.dig(:position) || "bottom"
    max = links_config&.dig(:max)

    out = +""
    out << "# #{script[:title]}\n\n"

    Array(script[:segments]).each do |seg|
      out << "## #{seg[:name]}\n\n"
      out << "#{seg[:text]}\n\n"

      if links_config && position == "inline" && seg[:sources]&.any?
        out << render_sources(seg[:sources], max: max)
      end
    end

    if links_config && position == "bottom"
      sources = script[:sources]
      if sources && !sources.empty?
        title = links_config[:title] || "More info"
        out << "## #{title}\n\n"
        out << render_sources(sources, max: max)
      end
    end

    out
  end

  def self.render_sources(sources, max: nil)
    sources = sources.first(max) if max
    out = +""
    sources.each do |src|
      clean_url = UrlCleaner.clean(src[:url])
      out << "- [#{src[:title]}](#{clean_url})\n"
    end
    out << "\n"
    out
  end
end
