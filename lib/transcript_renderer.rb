# frozen_string_literal: true

# Shared markdown-to-HTML conversion for transcripts.
# Used by both RssGenerator (podcast feed HTML) and SiteGenerator (static site).
module TranscriptRenderer
  # Converts a transcript/script body (after header extraction) to HTML.
  # When vocab: true (default), renders vocabulary section with linked bold words.
  # When vocab: false, strips vocabulary section and removes bold markers (for podcast apps).
  def render_body_html(body, vocab: true)
    transcript_body, vocab_body = split_vocabulary_section(body)
    vocab_lemmas = vocab && vocab_body ? parse_vocab_lemmas(vocab_body) : nil

    paragraphs = transcript_body.strip.split(/\n{2,}/).map do |block|
      block = block.strip
      if block.start_with?("## ")
        "<h2>#{escape_html(block.sub(/^## /, ""))}</h2>"
      elsif block.match?(/\A- \[.+\]\(.+\)/)
        items = block.split("\n").map do |line|
          line = line.strip.sub(/^- /, "")
          linkify_markdown(line)
        end
        "<ul>#{items.map { |i| "<li>#{i}</li>" }.join}</ul>"
      else
        html = escape_html(block)
        if vocab_lemmas
          html = linkify_vocab_words(html, vocab_lemmas)
        else
          html = strip_bold_markers(html)
        end
        "<p>#{html}</p>"
      end
    end

    result = paragraphs.join("\n")
    result += "\n" + render_vocabulary_html(vocab_body) if vocab && vocab_body
    result
  end

  # Removes **bold** markers, keeping the text inside.
  def strip_bold_markers(html)
    html.gsub(/\*\*([^*]+)\*\*/, '\1')
  end

  def escape_html(text)
    text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  def linkify_markdown(text)
    text.gsub(/\[([^\]]+)\]\(([^)]+)\)/) do
      title = escape_html(Regexp.last_match(1))
      url = escape_html(Regexp.last_match(2))
      "<a href=\"#{url}\">#{title}</a>"
    end
  end

  def split_vocabulary_section(body)
    if body.include?("## Vocabulary")
      parts = body.split("## Vocabulary", 2)
      [parts[0], parts[1]]
    else
      [body, nil]
    end
  end

  def parse_vocab_lemmas(vocab_body)
    lemmas = {}
    vocab_body.scan(/\*\*(\w+)\*\*\s*\(/).each do |match|
      lemma = match[0]
      lemmas[lemma.downcase] = lemma
    end

    vocab_body.scan(/_Original:\s*(\w+)_/).each do |match|
      word = match[0]
      vocab_body.scan(/\*\*(\w+)\*\*.*?_Original:\s*#{Regexp.escape(word)}_/) do
        lemmas[word.downcase] = Regexp.last_match(1)
      end
    end

    lemmas.empty? ? nil : lemmas
  end

  def linkify_vocab_words(html, vocab_lemmas)
    html.gsub(/\*\*([^*]+)\*\*/) do
      word = Regexp.last_match(1)
      lemma = vocab_lemmas[word.downcase] || word.downcase
      anchor = vocab_anchor(lemma)
      "<a href=\"##{anchor}\" class=\"vocab-word\">#{word}</a>"
    end
  end

  def vocab_anchor(lemma)
    "vocab-#{lemma.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')}"
  end

  def render_vocabulary_html(vocab_body)
    lines = ["<div class=\"vocabulary\">", "<h2>Vocabulary</h2>"]
    current_level = nil

    vocab_body.each_line do |line|
      line = line.strip
      next if line.empty?

      if line.match?(/\A\*\*[A-Z]\d\*\*\z/)
        lines << "</dl>" if current_level
        current_level = line.gsub("**", "")
        lines << "<h3>#{escape_html(current_level)}</h3>"
        lines << "<dl>"
      elsif line.start_with?("- **") && current_level
        if line =~ /\A- \*\*(.+?)\*\*\s*\(([^)]+)\)\s*(?:—\s*(.+))?\z/
          lemma = Regexp.last_match(1)
          pos = Regexp.last_match(2)
          rest = Regexp.last_match(3) || ""

          anchor = vocab_anchor(lemma)

          original = nil
          if rest =~ /(.+?)\s*_Original:\s*(.+?)_\s*\z/
            rest = Regexp.last_match(1).strip
            original = Regexp.last_match(2).strip
          end

          dt = "<dt id=\"#{anchor}\"><strong>#{escape_html(lemma)}</strong> <span class=\"pos\">(#{escape_html(pos)})</span></dt>"
          dd_parts = []
          dd_parts << escape_html(rest) unless rest.empty?
          dd_parts << "<span class=\"original\">#{escape_html(original)}</span>" if original
          dd = "<dd>#{dd_parts.join(' ')}</dd>"

          lines << dt
          lines << dd
        end
      end
    end

    lines << "</dl>" if current_level
    lines << "</div>"
    lines.join("\n")
  end
end
