# frozen_string_literal: true

# Shared markdown-to-HTML conversion for transcripts.
# Used by both RssGenerator (podcast feed HTML) and SiteGenerator (static site).
module TranscriptRenderer
  # Converts a transcript/script body (after header extraction) to HTML.
  # When vocab: true (default), renders vocabulary section with linked bold words.
  # When vocab: false, strips vocabulary section and removes bold markers (for podcast apps).
  def render_body_html(body, vocab: true)
    transcript_body, vocab_body = split_vocabulary_section(body)
    vocab_entries = vocab && vocab_body ? parse_vocab_entries(vocab_body) : nil

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
        if vocab_entries
          html = linkify_vocab_words(html, vocab_entries)
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
    entries = parse_vocab_entries(vocab_body)
    return nil unless entries

    lemmas = {}
    entries.each { |key, entry| lemmas[key] = entry[:lemma] }
    lemmas
  end

  def parse_vocab_entries(vocab_body)
    entries = {}

    vocab_body.each_line do |line|
      line = line.strip
      entry = parse_vocab_line(line)
      next unless entry

      entries[entry[:lemma].downcase] = entry
      if entry[:original]
        entry[:original].split(/,\s*/).each do |form|
          entries[form.strip.downcase] = entry
        end
      end
    end

    entries.empty? ? nil : entries
  end

  def linkify_vocab_words(html, vocab_entries)
    html.gsub(/\*\*([^*]+)\*\*/) do
      word = Regexp.last_match(1)
      entry = vocab_entries[word.downcase]
      lemma = entry ? entry[:lemma] : word.downcase
      anchor = vocab_anchor(lemma)

      tip = if entry
        head = "<strong>#{escape_html(entry[:lemma])}</strong>"
        head += " <span class=\"ipa\">#{escape_html(entry[:ipa])}</span>" if entry[:ipa]
        head += " <span class=\"pos\">(#{escape_html(entry[:pos])})</span>"
        head += " <span class=\"original\">#{escape_html(entry[:original])}</span>" if entry[:original]
        defn = escape_html(entry[:definition]) unless entry[:definition].empty?
        "<span class=\"vocab-tip\">#{head}#{defn ? "<span class=\"vocab-tip-def\">#{defn}</span>" : ""}</span>"
      end

      "<a href=\"##{anchor}\" class=\"vocab-word\">#{word}#{tip}</a>"
    end
  end

  def vocab_anchor(lemma)
    "vocab-#{lemma.downcase.gsub(/[^\p{L}\p{N}]+/, '-').gsub(/^-|-$/, '')}"
  end

  def render_vocabulary_html(vocab_body)
    lines = ["<div class=\"vocabulary\">", "<h2>Vocabulary</h2>", "<dl>"]

    vocab_body.each_line do |line|
      line = line.strip
      next if line.empty?
      next if line.match?(/\A\*\*[A-Z]\d\*\*\z/) # skip old-format level headers

      entry = parse_vocab_line(line)
      next unless entry

      anchor = vocab_anchor(entry[:lemma])
      dt_parts = "<strong>#{escape_html(entry[:lemma])}</strong>"
      dt_parts += " <span class=\"ipa\">#{escape_html(entry[:ipa])}</span>" if entry[:ipa]
      dt_parts += " <span class=\"pos\">(#{escape_html(entry[:pos])})</span>"
      dt_parts += " <span class=\"original\">#{escape_html(entry[:original])}</span>" if entry[:original]
      lines << "<dt id=\"#{anchor}\">#{dt_parts}</dt>"
      lines << "<dd>#{escape_html(entry[:definition])}</dd>" unless entry[:definition].empty?
    end

    lines << "</dl>"
    lines << "</div>"
    lines.join("\n")
  end

  private

  def parse_vocab_line(line)
    return unless line =~ /\A- \*\*(.+?)\*\*\s*(?:(\/[^\/]+\/)\s*)?\(([^)]+)\)\s*(?:\*([^*]+)\*\s*)?(?:—\s*(.+))?\z/

    lemma = Regexp.last_match(1)
    ipa = Regexp.last_match(2)
    pos = Regexp.last_match(3)
    original = Regexp.last_match(4)
    rest = Regexp.last_match(5) || ""

    # Backward compat: old format used _Original: word_ at end of definition
    if original.nil? && rest =~ /(.+?)\s*_Original:\s*(.+?)_\s*\z/
      rest = Regexp.last_match(1).strip
      original = Regexp.last_match(2).strip
    end

    { lemma: lemma, ipa: ipa, pos: pos, definition: rest, original: original }
  end
end
