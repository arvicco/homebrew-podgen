# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "vocabulary_annotator")
require_relative File.join(root, "lib", "known_vocabulary")
require_relative File.join(root, "lib", "site_generator")
require_relative File.join(root, "lib", "transcript_renderer")

module PodgenCLI
  class RevocabCommand
    include PodcastCommand
    include TranscriptRenderer

    def initialize(args, options)
      require "optparse"
      OptionParser.new do |opts|
        opts.on("--missing-only", "Only annotate transcripts without existing vocabulary") { @missing_only = true }
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
      known = KnownVocabulary.for_config(@config)
      known_lemmas = known.lemma_set(language)

      annotator = VocabularyAnnotator.new(
        ENV["ANTHROPIC_API_KEY"],
        model: "claude-sonnet-4-6",
        logger: logger
      )

      puts "Re-annotating #{transcripts.length} transcript(s) (#{language}, #{cutoff}+ cutoff)"

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
                          known_lemmas: known_lemmas, max: vocab_max, filters: vocab_filters, logger: logger)
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

    def process_transcript(path, annotator:, language:, cutoff:, known_lemmas:, max:, filters:, logger:)
      text = File.read(path)

      # Split into header (title + description) and body
      parts = text.split("## Transcript", 2)
      unless parts.length == 2
        logger.log("Skipping #{File.basename(path)}: no ## Transcript section")
        return
      end

      header = parts.first
      body = parts.last

      # Strip existing vocabulary section
      body, _old_vocab = split_vocabulary_section(body)

      # Strip bold markers from previous annotation
      body = strip_bold_markers(body.strip)

      # Re-annotate
      marked_body, vocabulary_md = annotator.annotate(
        body,
        language: language,
        cutoff: cutoff,
        known_lemmas: known_lemmas,
        max: max,
        filters: filters
      )

      # Rewrite transcript file
      new_text = header + "## Transcript\n\n" + marked_body
      new_text += "\n\n" + vocabulary_md unless vocabulary_md.empty?
      File.write(path, new_text)

      logger.log("Vocabulary re-annotated: #{File.basename(path)}")
    rescue => e
      logger.error("Failed to re-annotate #{File.basename(path)}: #{e.message}")
    end
  end
end
