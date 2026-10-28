# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "known_vocabulary")
require_relative File.join(root, "lib", "vocab_ledger")
require_relative File.join(root, "lib", "vocab_cache")

module PodgenCLI
  class VocabCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      @lang = nil
      @min = 3

      OptionParser.new do |opts|
        opts.on("--lang CODE", "Language code (default: from config); edit: target language") { |l| @lang = l }
        opts.on("--min N", Integer, "review: lemmas explained at least N times (default 3)") { |n| @min = n }
        opts.on("--promote", "review: add every listed lemma to known vocabulary") { @promote = true }
        opts.on("--translation TEXT", "edit: cached translation") { |t| @translation = t }
        opts.on("--definition TEXT", "edit: cached definition") { |d| @definition = d }
      end.parse!(args)

      @subcommand = args.shift
      @podcast_name = args.shift
      @word = args.shift
      reject_leftover_args!(args)
    end

    def run
      case @subcommand
      when "add"    then add_word
      when "remove" then remove_word
      when "list"   then list_words
      when "review" then review_words
      when "edit"   then edit_word
      else usage; 2
      end
    end

    private

    def add_word
      code = require_podcast!("vocab add")
      return code if code
      return missing_word("add") unless @word

      load_config!
      lang = resolve_language
      return 2 unless lang

      kv = KnownVocabulary.for_config(@config)
      if kv.add(lang, @word)
        puts "Added '#{@word.downcase}' to known vocabulary (#{lang})"
      else
        puts "Already known: '#{@word.downcase}' (#{lang})"
      end
      0
    end

    def remove_word
      code = require_podcast!("vocab remove")
      return code if code
      return missing_word("remove") unless @word

      load_config!
      lang = resolve_language
      return 2 unless lang

      kv = KnownVocabulary.for_config(@config)
      if kv.remove(lang, @word)
        puts "Removed '#{@word.downcase}' from known vocabulary (#{lang})"
      else
        puts "Not found: '#{@word.downcase}' (#{lang})"
      end
      0
    end

    def list_words
      code = require_podcast!("vocab list")
      return code if code

      load_config!
      lang = resolve_language
      return 2 unless lang

      kv = KnownVocabulary.for_config(@config)
      words = kv.lemmas(lang)

      if words.empty?
        puts "No known vocabulary words for #{lang}"
      else
        puts "Known vocabulary (#{lang}): #{words.length} words"
        words.each { |w| puts "  #{w}" }
      end
      0
    end

    # Lemmas explained >= @min times in the show's transcripts, minus the
    # known ones; --promote adds them all to known_vocabulary.yml.
    def review_words
      code = require_podcast!("vocab review")
      return code if code

      load_config!
      lang = resolve_language
      return 2 unless lang

      kv = KnownVocabulary.for_config(@config)
      known = kv.lemma_set(lang)
      rows = VocabLedger.build(@config.episodes_dir).top_explained(min: @min)
        .reject { |row| known.include?(row[:lemma]) }

      if rows.empty?
        puts "No lemmas explained #{@min}+ times outside known vocabulary (#{lang})"
        return 0
      end

      puts "Lemmas explained #{@min}+ times (#{lang}): #{rows.length}"
      width = rows.map { |row| row[:lemma].length }.max
      rows.each { |row| puts format("  %-#{width}s  %3d  %s", row[:lemma], row[:count], row[:last]) }

      if @promote
        added = rows.count { |row| kv.add(lang, row[:lemma]) }
        puts "Promoted #{added} lemma(s) to known vocabulary (#{lang})"
      end
      0
    end

    # Overwrites one language's cached translation/definition for a lemma.
    def edit_word
      unless @podcast_name && @word && @lang && @translation
        $stderr.puts "Usage: podgen vocab edit <podcast> <lemma> --lang LANGUAGE --translation TEXT [--definition TEXT]"
        return 2
      end
      code = require_podcast!("vocab edit")
      return code if code

      load_config!
      cache = VocabCache.for_config(@config)
      cache.set(@word, @lang, translation: @translation, definition: @definition)
      cache.save
      puts "Cached #{@word.downcase} (#{@lang})"
      0
    end

    def resolve_language
      lang = @lang || @config.transcription_language
      unless lang
        $stderr.puts "No language configured. Use --lang or set language in ## Audio section."
        return nil
      end
      lang
    end

    def missing_word(subcommand)
      $stderr.puts "Usage: podgen vocab #{subcommand} <podcast> <word> [--lang CODE]"
      2
    end

    def usage
      $stderr.puts "Usage: podgen vocab <add|remove|list|review|edit> <podcast> [word] [--lang CODE]"
      $stderr.puts
      $stderr.puts "Subcommands:"
      $stderr.puts "  add <podcast> <word>      Add word to known vocabulary"
      $stderr.puts "  remove <podcast> <word>   Remove word from known vocabulary"
      $stderr.puts "  list <podcast>            List known vocabulary words"
      $stderr.puts "  review <podcast>          Lemmas explained --min N (3) times; --promote adds them"
      $stderr.puts "  edit <podcast> <lemma>    Set a cached gloss: --lang LANGUAGE --translation T [--definition D]"
      $stderr.puts
      $stderr.puts "Options:"
      $stderr.puts "  --lang CODE   Language code (default: from podcast config)"
    end
  end
end
