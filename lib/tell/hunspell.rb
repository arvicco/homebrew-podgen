# frozen_string_literal: true

require "open3"
require "set"
require "tempfile"
require_relative "../atomic_writer"

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

    # Bumped when the conversion changes, so older /tmp caches are ignored.
    CACHE_VERSION = 2

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

        index = dic_word_index(dict, dic_path)

        # Get dictionary roots for the lemma
        roots = stem(lemma, dict)

        # For verbs (-ati/-iti/-eti), also find entries sharing the verb stem
        # e.g., "zlekniti" → stem "zlekn" finds zleknem/F, zlekne/V, zleknil/A etc.
        verb_stem = lemma.sub(/(?:ova|eva|a|i|e)ti\z/, "")
        entries = if verb_stem != lemma && verb_stem.length >= 3
          index.flat_map do |word, lines|
            next [] unless word.start_with?(verb_stem) && word.length <= verb_stem.length + 3
            lines
          end
        else
          # Non-verb: find exact root entries only
          roots.flat_map { |root| index[root] }
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
          forms = stdout.lines.map(&:strip).reject(&:empty?)
            .select { |form| form.start_with?(prefix) }
            .uniq
          # A root whose forms do not include the lemma is a different word
          # ("nuovamente" → "nuovo", "farcela" → "fare"): expand nothing.
          return (forms.include?(lemma) ? forms : []) if verb_stem == lemma

          # The stem search also reaches other words ("leteti" → "leta",
          # years): keep only forms that stem back to one of the lemma's roots.
          root_set = Set.new(roots)
          stems = stems_of(forms, dict)
          forms.select { |form| form == lemma || stems.fetch(form, []).any? { |r| root_set.include?(r) } }
        end
      end

      def dict_for(lang)
        DICT_MAP[lang]
      end

      # In-memory cache: dict name → { word => [dic_content_lines] }.
      # Avoids re-reading and re-parsing the .dic file on every expand() call.
      def dic_word_index(dict, dic_path)
        @dic_index_cache ||= {}
        @dic_index_cache[dict] ||= begin
          idx = Hash.new { |h, k| h[k] = [] }
          File.foreach(dic_path, encoding: "UTF-8") do |line|
            word = line.split("/", 2).first.to_s.strip
            next if word.empty?
            idx[word] << line
          end
          idx
        end
      end

      # Test/dev helper — clear the in-memory cache. Production code never
      # calls this; the cache is per-process and lives until exit.
      def clear_cache!
        @dic_index_cache = nil
      end

      private

      # Stem a word using hunspell -s. Returns array of dictionary roots.
      def stem(word, dict)
        stdout, _, status = Open3.capture3("hunspell", "-d", dict, "-s",
                                           stdin_data: word)
        return [] unless status.success?

        stdout.lines.flat_map { |l| l.strip.split(/\s+/).drop(1) }.uniq
      end

      # Stem many words in one `hunspell -s` call: { word => [roots] }
      # (a word hunspell does not know has no entry).
      def stems_of(words, dict)
        stdout, stderr, status = Open3.capture3("hunspell", "-d", dict, "-s",
                                                stdin_data: words.join("\n"))
        unless status.success?
          $stderr.puts "warn: hunspell -s failed (#{dict}): #{stderr.to_s.lines.first.to_s.strip} — verb forms kept to the lemma"
          return {}
        end

        stdout.lines.each_with_object(Hash.new { |h, k| h[k] = [] }) do |line, map|
          word, root = line.strip.split(/\s+/, 2)
          map[word] << root if word && root
        end
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

        # Already UTF-8: use the originals
        encoding = aff_encoding(aff_path)
        return @utf8_cache[dict] = [dic_path, aff_path] if encoding.casecmp?("UTF-8")

        # Convert to UTF-8 in the cache dir; the version in the name keeps a
        # cache written by an older conversion path from being reused.
        utf8_dic = File.join(cache_dir, "hunspell_#{dict}_utf8_v#{CACHE_VERSION}.dic")
        utf8_aff = File.join(cache_dir, "hunspell_#{dict}_utf8_v#{CACHE_VERSION}.aff")

        unless File.exist?(utf8_dic) && File.exist?(utf8_aff)
          dic_content = iconv_utf8(dic_path, encoding)
          aff_content = iconv_utf8(aff_path, encoding)
          return @utf8_cache[dict] = [nil, nil] unless dic_content && aff_content

          AtomicWriter.write(utf8_dic, dic_content)
          AtomicWriter.write(utf8_aff, aff_content.sub(/^SET\s+\S+/, "SET UTF-8"))
        end

        @utf8_cache[dict] = [utf8_dic, utf8_aff]
      end

      # The .aff file's SET line (anywhere in the file, not only its header);
      # ISO-8859-2 when it has none.
      def aff_encoding(aff_path)
        File.foreach(aff_path, encoding: "BINARY") do |line|
          encoding = line[/\ASET\s+(\S+)/, 1]
          return encoding if encoding
        end
        "ISO-8859-2"
      end

      # The file converted to UTF-8, or nil (with a warning) when iconv fails.
      def iconv_utf8(path, encoding)
        stdout, stderr, status = Open3.capture3("iconv", "-f", encoding, "-t", "UTF-8", path)
        return stdout if status.success?

        $stderr.puts "warn: iconv #{encoding} → UTF-8 failed (#{File.basename(path)}): #{stderr.to_s.lines.first.to_s.strip} — no inflection expansion"
        nil
      end

      # Where converted dictionaries are cached (a seam for tests).
      def cache_dir
        "/tmp"
      end
    end
  end
end
