# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "vocabulary_annotator")
require_relative File.join(root, "lib", "vocab_ledger")
require_relative File.join(root, "lib", "vocab_cache")
require_relative File.join(root, "lib", "known_vocabulary")
require_relative File.join(root, "lib", "site_generator")
require_relative File.join(root, "lib", "transcript_parser")
require_relative File.join(root, "lib", "transcript_renderer")
require_relative File.join(root, "lib", "episode_filtering")
require_relative File.join(root, "lib", "episode_naming")

module PodgenCLI
  class RevocabCommand
    include PodcastCommand
    include TranscriptRenderer

    def initialize(args, options)
      require "optparse"
      @include_words = Set.new
      @target_language = nil
      OptionParser.new do |opts|
        opts.on("--missing-only", "Only annotate transcripts without existing vocabulary") { @missing_only = true }
        opts.on("--include WORDS", "Force-include these lemmas (comma-separated)") { |v| @include_words = Set.new(v.split(",").map { |w| w.strip.downcase }) }
        opts.on("--target LANG", "Target language for definitions (e.g. Polish, English)") { |v| @target_language = v }
        opts.on("--date DATE", "Episode date (YYYY-MM-DD)") { |v| @episode_id = v }
        opts.on("--from DATE", "First episode date to include (YYYY-MM-DD)") { |v| @from = parse_date_option!(v) }
        opts.on("--to DATE", "Last episode date to include (YYYY-MM-DD)") { |v| @to = parse_date_option!(v) }
        opts.on("--limit N", Integer, "Only the earliest N transcripts of the selection") do |v|
          raise OptionParser::InvalidArgument, "--limit #{v} (must be positive)" unless v.positive?
          @limit = v
        end
        opts.on("--no-ledger", "Ignore earlier episodes' vocabulary (no spaced re-exposure, no key terms)") { @no_ledger = true }
        opts.on("--no-cache", "Enrich every lemma afresh (neither read nor write vocab_cache.yml)") { @no_cache = true }
      end.parse!(args)

      @podcast_name = args.shift
      @episode_id ||= args.shift
      reject_leftover_args!(args)
      @options = options
      @dry_run = options[:dry_run] || false
    end

    def run
      code = require_podcast!("revocab")
      return code if code

      load_config!
      logger = build_logger

      unless @config.vocabulary_level
        $stderr.puts "Error: No vocabulary level configured in guidelines.md (## Vocabulary / level: B2)"
        return 2
      end

      unless ENV["ANTHROPIC_API_KEY"] && !ENV["ANTHROPIC_API_KEY"].empty?
        $stderr.puts "Error: ANTHROPIC_API_KEY not set"
        return 2
      end

      transcripts = resolve_transcripts
      if transcripts.empty?
        $stderr.puts "No transcripts found#{@episode_id ? " matching '#{@episode_id}'" : ""}"
        return 1
      end

      language = @config.transcription_language
      cutoff = @config.vocabulary_level
      vocab_max = @config.vocabulary_max
      vocab_filters = @config.vocabulary_filters
      target_languages = if @target_language
        @target_language.split(",").map(&:strip)
      else
        @config.vocabulary_target_languages
      end
      known = KnownVocabulary.for_config(@config)
      known_lemmas = known.lemma_set(language)

      annotator = VocabularyAnnotator.new(
        ENV["ANTHROPIC_API_KEY"],
        logger: logger
      )

      selected, skipped = select_transcripts(transcripts)

      if @dry_run
        selected.each { |path| puts "  [dry-run] #{File.basename(path, "_transcript.md")}" }
        puts "[dry-run] #{selected.length} transcript(s) selected"
        return 0
      end

      puts "Re-annotating #{selected.length} transcript(s) (#{language}, #{cutoff}+ cutoff, definitions in #{target_languages.join(', ')})"

      processed = 0
      failed = []
      cache = @no_cache ? nil : VocabCache.for_config(@config)
      selected.each do |path|
        basename = File.basename(path, "_transcript.md")
        puts "  #{basename}..."
        # The ledger as of this episode: only the transcripts before it.
        ledger = @no_ledger ? nil : VocabLedger.for_config(@config, before: basename)
        status = process_transcript(path, annotator: annotator, language: language, cutoff: cutoff,
                          known_lemmas: known_lemmas, max: vocab_max, filters: vocab_filters,
                          logger: logger, include_words: @include_words,
                          target_languages: target_languages,
                          ledger: ledger, cache: cache, episode: basename)
        case status
        when :annotated then processed += 1
        when :failed then failed << basename
        else skipped += 1
        end
      end

      if processed > 0
        puts "Regenerating site..."
        SiteGenerator.new(config: @config, clean: true).generate
      elsif failed.empty?
        puts "No transcripts needed annotation"
      end

      tally = "re-annotated #{processed}, skipped #{skipped}, failed #{failed.length}"
      tally += " (#{failed.join(", ")})" if failed.any?
      puts tally
      failed.any? ? 1 : 0
    end

    private

    def build_logger
      quiet = @options[:verbosity] == :quiet
      logger = Object.new
      logger.define_singleton_method(:log) { |msg| puts msg unless quiet }
      logger.define_singleton_method(:error) { |msg| $stderr.puts msg }
      logger.define_singleton_method(:phase_start) { |_| }
      logger.define_singleton_method(:phase_end) { |_| }
      logger
    end

    def resolve_transcripts
      dir = @config.episodes_dir

      paths = if @episode_id
        pattern = File.join(dir, "*#{@episode_id}_transcript.md")
        Dir.glob(pattern).sort
      else
        EpisodeFiltering.all_transcripts(dir)
      end
      return paths unless @from || @to

      paths.select do |path|
        date = EpisodeNaming.parse_date(path)
        date && (!@from || date >= @from) && (!@to || date <= @to)
      end
    end

    # --missing-only, then --limit (the earliest N of what is left).
    # Returns [selected paths, count skipped for already having vocabulary].
    def select_transcripts(transcripts)
      selected = transcripts
      if @missing_only
        selected = transcripts.reject do |path|
          has_vocab = File.read(path).include?("## Vocabulary")
          puts "  #{File.basename(path, "_transcript.md")} (skipped, has vocabulary)" if has_vocab && @options[:verbosity] == :verbose
          has_vocab
        end
      end
      skipped = transcripts.length - selected.length
      selected = selected.first(@limit) if @limit
      [selected, skipped]
    end

    def parse_date_option!(value)
      raise Date::Error unless value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.iso8601(value)
    rescue Date::Error
      raise OptionParser::InvalidArgument, "#{value} (expected YYYY-MM-DD)"
    end

    def process_transcript(path, annotator:, language:, cutoff:, known_lemmas:, max:, filters:, logger:, include_words: Set.new, target_languages: ["English"],
      ledger: nil, cache: nil, episode: nil)
      parsed = TranscriptParser.parse_file(path)
      unless parsed.transcript_section
        logger.log("Skipping #{File.basename(path)}: no ## Transcript section")
        return :skipped
      end

      # Strip bold markers from previous annotation
      body = strip_bold_markers(parsed.body)

      # Re-annotate
      marked_body, vocabulary_md = annotator.annotate(
        body,
        language: language,
        cutoff: cutoff,
        known_lemmas: known_lemmas,
        max: max,
        filters: filters,
        include_words: include_words,
        target_languages: target_languages,
        ledger: ledger,
        cache: cache,
        episode: episode
      )

      # Rewrite transcript file
      vocab = vocabulary_md.empty? ? nil : vocabulary_md
      TranscriptParser.write(path,
        title: parsed.title,
        description: parsed.description,
        body: marked_body,
        vocabulary: vocab)

      logger.log("Vocabulary re-annotated: #{File.basename(path)}")
      :annotated
    rescue => e # skippable per-file: the remaining transcripts are still processed; counted, exit 1
      logger.error("Failed to re-annotate #{File.basename(path)}: #{e.class}: #{e.message}")
      :failed
    end
  end
end
