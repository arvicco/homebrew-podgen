# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "vocabulary_annotator")
require_relative File.join(root, "lib", "known_vocabulary")
require_relative File.join(root, "lib", "site_generator")
require_relative File.join(root, "lib", "transcript_parser")
require_relative File.join(root, "lib", "transcript_renderer")

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
      end.parse!(args)

      @podcast_name = args.shift
      @episode_id = args.shift
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
      target_language = @target_language || @config.vocabulary_target_language
      known = KnownVocabulary.for_config(@config)
      known_lemmas = known.lemma_set(language)

      annotator = VocabularyAnnotator.new(
        ENV["ANTHROPIC_API_KEY"],
        model: "claude-sonnet-4-6",
        logger: logger
      )

      puts "Re-annotating #{transcripts.length} transcript(s) (#{language}, #{cutoff}+ cutoff, definitions in #{target_language})"

      processed = 0
      transcripts.each do |path|
        basename = File.basename(path, "_transcript.md")

        if @missing_only && File.read(path).include?("## Vocabulary")
          puts "  #{basename} (skipped, has vocabulary)" if @options[:verbosity] == :verbose
          next
        end

        if @dry_run
          puts "  [dry-run] #{basename}"
          next
        end

        puts "  #{basename}..."
        process_transcript(path, annotator: annotator, language: language, cutoff: cutoff,
                          known_lemmas: known_lemmas, max: vocab_max, filters: vocab_filters,
                          logger: logger, include_words: @include_words,
                          target_language: target_language)
        processed += 1
      end

      if !@dry_run && processed > 0
        puts "Regenerating site..."
        SiteGenerator.new(config: @config, clean: true).generate
      elsif processed == 0 && !@dry_run
        puts "No transcripts needed annotation"
      end

      0
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

      if @episode_id
        pattern = File.join(dir, "*#{@episode_id}_transcript.md")
        Dir.glob(pattern).sort
      else
        Dir.glob(File.join(dir, "*_transcript.md")).sort
      end
    end

    def process_transcript(path, annotator:, language:, cutoff:, known_lemmas:, max:, filters:, logger:, include_words: Set.new, target_language: "English")
      parsed = TranscriptParser.parse(path)
      unless parsed.transcript_section
        logger.log("Skipping #{File.basename(path)}: no ## Transcript section")
        return
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
        target_language: target_language
      )

      # Rewrite transcript file
      vocab = vocabulary_md.empty? ? nil : vocabulary_md.split("## Vocabulary", 2).last
      TranscriptParser.write(path,
        title: parsed.title,
        description: parsed.description,
        body: marked_body,
        vocabulary: vocab)

      logger.log("Vocabulary re-annotated: #{File.basename(path)}")
    rescue => e
      logger.error("Failed to re-annotate #{File.basename(path)}: #{e.message}")
    end
  end
end
