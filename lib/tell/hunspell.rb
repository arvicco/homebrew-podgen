# frozen_string_literal: true

require "open3"
require "set"
require "tempfile"

module Tell
  # Wraps hunspell + unmunch for morphological inflection expansion.
  # Optional dependency — gracefully returns nil/empty when not installed.
  class Hunspell
    DICT_MAP = {
      "sl" => "sl_SI", "hr" => "hr_HR", "sr" => "sr_Latn",
      "it" => "it_IT", "de" => "de_DE", "fr" => "fr_FR",
      "es" => "es_ES", "pt" => "pt_PT", "en" => "en_US",
      "nl" => "nl_NL", "pl" => "pl_PL", "cs" => "cs_CZ",
      "sk" => "sk_SK", "ro" => "ro_RO", "hu" => "hu_HU",
      "da" => "da_DK", "sv" => "sv_SE", "no" => "nb_NO",
      "fi" => "fi_FI", "et" => "et_EE", "lt" => "lt_LT",
      "lv" => "lv_LV", "el" => "el_GR", "tr" => "tr_TR",
      "ru" => "ru_RU", "uk" => "uk_UA", "bg" => "bg_BG"
    }.freeze

    DICT_DIRS = [
      File.join(Dir.home, "Library", "Spelling"),
      "/Library/Spelling",
      "/usr/share/hunspell",
      "/usr/local/share/hunspell"
    ].freeze

    class << self
      def available?
        return @available unless @available.nil?

        @available = begin
          h = Open3.capture3("hunspell", "--version")
          u = Open3.capture3("unmunch", stdin_data: "")
          h[2].success? && u[2].exitstatus != 127
        rescue Errno::ENOENT
          false
        end
      end

      def supports?(lang)
        return false unless available?

        dict = dict_for(lang)
        return false unless dict

        !!find_dic_path(dict)
      end

      # Expand a lemma into all inflected forms via hunspell stemming + unmunch.
      # Returns array of forms, or empty array if unavailable/not in dictionary.
      def expand(lemma, lang:)
        return [] unless supports?(lang)

        dict = dict_for(lang)
        dic_path, aff_path = utf8_paths(dict)
        return [] unless dic_path && aff_path

        dic_content = File.read(dic_path, encoding: "UTF-8")

        # Get dictionary roots for the lemma
        roots = stem(lemma, dict)

        # For verbs (-ati/-iti/-eti), also find entries sharing the verb stem
        # e.g., "zlekniti" → stem "zlekn" finds zleknem/F, zlekne/V, zleknil/A etc.
        verb_stem = lemma.sub(/(?:ova|eva|a|i|e)ti\z/, "")
        entries = if verb_stem != lemma && verb_stem.length >= 3
          dic_content.lines.select do |l|
            word = l.split("/").first.strip
            word.start_with?(verb_stem) && word.length <= verb_stem.length + 3
          end
        else
          # Non-verb: find exact root entries only (root or root/FLAGS)
          roots.flat_map do |root|
            dic_content.lines.select { |l| l.strip == root || l.start_with?("#{root}/") }
          end
        end

        return [] if entries.empty?

        # Expand via unmunch
        Tempfile.create(["hunspell_expand", ".dic"]) do |f|
          f.write("#{entries.length}\n")
          entries.each { |e| f.write(e) }
          f.flush

          stdout, _, status = Open3.capture3("unmunch", f.path, aff_path)
          return [] unless status.success?

          # Filter to forms sharing the verb stem or shortest root
          prefix = verb_stem != lemma ? verb_stem : roots.min_by(&:length)
          stdout.lines.map(&:strip).reject(&:empty?)
            .select { |form| form.start_with?(prefix) }
            .uniq
        end
      end

      def dict_for(lang)
        DICT_MAP[lang]
      end

      private

      # Stem a word using hunspell -s. Returns array of dictionary roots.
      def stem(word, dict)
        stdout, _, status = Open3.capture3("hunspell", "-d", dict, "-s",
                                           stdin_data: word)
        return [] unless status.success?

        stdout.lines.flat_map { |l| l.strip.split(/\s+/).drop(1) }.uniq
      end

      # Find the .dic file path for a dictionary name.
      def find_dic_path(dict)
        DICT_DIRS.each do |dir|
          path = File.join(dir, "#{dict}.dic")
          return path if File.exist?(path)
        end
        nil
      end

      # Ensure UTF-8 versions of .dic and .aff files exist (cached in /tmp).
      # Returns [dic_path, aff_path] or [nil, nil].
      def utf8_paths(dict)
        @utf8_cache ||= {}
        return @utf8_cache[dict] if @utf8_cache.key?(dict)

        dic_path = find_dic_path(dict)
        return @utf8_cache[dict] = [nil, nil] unless dic_path

        aff_path = dic_path.sub(/\.dic$/, ".aff")
        return @utf8_cache[dict] = [nil, nil] unless File.exist?(aff_path)

        # Check if already UTF-8
        aff_header = File.read(aff_path, 100, encoding: "BINARY")
        if aff_header.include?("SET UTF-8")
          return @utf8_cache[dict] = [dic_path, aff_path]
        end

        # Convert to UTF-8 in /tmp
        encoding = aff_header[/SET\s+(\S+)/, 1] || "ISO-8859-2"
        utf8_dic = "/tmp/hunspell_#{dict}_utf8.dic"
        utf8_aff = "/tmp/hunspell_#{dict}_utf8.aff"

        unless File.exist?(utf8_dic) && File.exist?(utf8_aff)
          system("iconv", "-f", encoding, "-t", "UTF-8", dic_path, out: utf8_dic)
          aff_content, _, _ = Open3.capture3("iconv", "-f", encoding, "-t", "UTF-8", aff_path)
          File.write(utf8_aff, aff_content.sub(/SET\s+\S+/, "SET UTF-8"))
        end

        @utf8_cache[dict] = [utf8_dic, utf8_aff]
      end
    end
  end
end
