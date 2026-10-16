# frozen_string_literal: true

require "optparse"
require_relative "cli/version"

module PodgenCLI
  # One source of truth for dispatch and the help screen (P4-6): each entry is
  # [description, require path, class name, usage synopsis]. `podgen --help`
  # lists the commands in this order as "<name> <synopsis>  <description>".
  COMMANDS = {
    "generate"  => ["Run the full pipeline (news or language)",                          "cli/generate_command",  "GenerateCommand",  "<podcast>"],
    "translate" => ["Translate episodes to new languages",                               "cli/translate_command", "TranslateCommand", "<podcast>"],
    "render"    => ["Re-render script markdown from canonical JSON",                     "cli/render_command",    "RenderCommand",    "<podcast> [--date|--lang]"],
    "voice"     => ["Voice or re-voice an episode from script JSON (recover from TTS failure)", "cli/voice_command", "VoiceCommand", "<podcast> [--date|--lang|--force]"],
    "scrap"     => ["Remove episode files + history entry",                              "cli/scrap_command",     "ScrapCommand",     "<podcast> [episode|path]"],
    "move"      => ["Move episode to another date (suffix '+' = whole day)",             "cli/move_command",      "MoveCommand",      "<podcast> <from> <to>"],
    "rss"       => ["Generate RSS feed",                                                 "cli/rss_command",       "RssCommand",       "<podcast>"],
    "site"      => ["Generate static HTML website",                                      "cli/site_command",      "SiteCommand",      "<podcast>"],
    "publish"   => ["Publish to Cloudflare R2 (--lingq for LingQ)",                      "cli/publish_command",   "PublishCommand",   "<podcast>"],
    "stats"     => ["Show podcast statistics",                                           "cli/stats_command",     "StatsCommand",     "<podcast> | --all"],
    "validate"  => ["Validate podcast config and output",                                "cli/validate_command",  "ValidateCommand",  "<podcast> | --all"],
    "status"    => ["One-line OK/OLD/WARN verdict per podcast (exit 1 if any OLD/WARN)", "cli/status_command",    "StatusCommand",    "[podcast] [--json]"],
    "list"      => ["List available podcasts",                                           "cli/list_command",      "ListCommand",      ""],
    "test"      => ["Run a standalone test script",                                      "cli/test_command",      "TestCommand",      "<name> [args]"],
    "schedule"  => ["Install launchd scheduler (--time, --publish, --telegram)",         "cli/schedule_command",  "ScheduleCommand",  "<podcast>"],
    "uploads"   => ["Per-pod regen+R2+LingQ then YT batch across pods (--mode, --max)",  "cli/uploads_command",   "UploadsCommand",   "<pod1,pod2,...>"],
    "analytics" => ["Manage download analytics Worker",                                  "cli/analytics_command", "AnalyticsCommand", "<setup|deploy|tail|status>"],
    "add"       => ["Queue a priority link for next episode",                            "cli/add_command",       "AddCommand",       "<podcast> <url> [--note ...]"],
    "links"     => ["List or manage queued priority links",                              "cli/links_command",     "LinksCommand",     "<podcast> [--remove|--clear]"],
    "vocab"     => ["Manage known vocabulary words",                                     "cli/vocab_command",     "VocabCommand",     "<add|remove|list> <podcast>"],
    "revocab"   => ["Re-annotate vocabulary on transcripts",                             "cli/revocab_command",   "RevocabCommand",   "<podcast> [episode] [--missing-only]"],
    "reformat"  => ["Reformat transcripts (paragraph breaks, cleanup)",                  "cli/reformat_command",  "ReformatCommand",  "<podcast> [episode]"],
    "exclude"   => ["Exclude URLs from future episodes",                                 "cli/exclude_command",   "ExcludeCommand",   "<podcast> <url> [url...]"],
    "cover"     => ["Generate episode cover image",                                      "cli/cover_command",     "CoverCommand",     "<podcast> <title|episode-id>"],
    "regen"     => ["Regenerate post-pipeline artifacts",                                "cli/regen_command",     "RegenCommand",     "<podcast> [date] [--video|--subtitles|--reconcile|--all]"],
    "init"      => ["Initialize a new podcast (skeleton or from existing)",              "cli/init_command",      "InitCommand",      "<name> | <source> <name>"],
    "fork"      => ["Fork podcast with all content into a new namespace",                "cli/fork_command",      "ForkCommand",      "<old> <new>"],
    "unpublish" => ["Remove podcast from Cloudflare R2",                                 "cli/unpublish_command", "UnpublishCommand", "<podcast>"],
    "tweet"     => ["Tweet about an episode (--force, --dry-run)",                       "cli/tweet_command",     "TweetCommand",     "<podcast> <episode-id>"]
  }.freeze

  # Width of the "<name> <synopsis>" column on the help screen; a longer
  # label pushes its description right. At least two spaces separate them.
  HELP_LABEL_WIDTH = 29

  def self.command_help_lines
    COMMANDS.map do |name, (desc, _path, _klass, synopsis)|
      label = [name, synopsis].reject(&:empty?).join(" ")
      "  #{label.ljust(HELP_LABEL_WIDTH)}  #{desc}"
    end
  end

  # Owner-only commands (CLAUDE.md golden rule 3) and the generate flags that
  # upload to listener-facing services.
  OWNER_ACTIONS = %w[publish unpublish uploads tweet schedule analytics].freeze
  OWNER_FLAGS = %w[--youtube --lingq].freeze

  # Owner commands whose run honours --dry-run. uploads, schedule and
  # analytics ignore it, so no dry-run flag ever exempts them.
  DRY_RUN_HONOURED = %w[generate publish unpublish tweet].freeze

  DRY_RUN_HINT = "note: --dry-run was read as an option value or is not honoured by this command; " \
    "put it right after the podcast name (generate/publish/tweet) or before the command " \
    "(podgen --dry-run <command>, honoured by generate/publish/unpublish/tweet only)"

  def self.owner_action?(command_name, argv, options)
    return true if OWNER_ACTIONS.include?(command_name)
    return false unless command_name == "generate"
    return true if options[:lingq]

    parsed = generate_dry_parse(argv)
    return !!(parsed[:youtube] || parsed[:lingq]) if parsed

    argv.any? { owner_flag?(it) }
  end

  # What GenerateCommand's own parser would set for this argv (P3-7): the
  # guard answers from the real option list, so a value-taking option that
  # swallows `--` or a flag-looking token is read exactly as the command
  # reads it. Nil when the real parse would fail. Loaded lazily; the options
  # module is small and never pulls in the command class.
  def self.generate_dry_parse(argv)
    require_relative "cli/generate_options"
    GenerateOptions.dry_parse(argv)
  end

  # Conservative fallback, used only when generate's argv does not parse:
  # checks EVERY token, including those after `--`. OptionParser accepts any
  # unique, case-insensitive prefix of a long option (`--you`, `--LIN=x`), so
  # every prefix of an owner flag counts as that flag; a single dash
  # completes against the long options (`-y` youtube, `-l` lingq).
  def self.owner_flag?(token)
    return true if token.match?(/\A-[yl]/i)

    name = token[/\A--([^=]+)/, 1]&.downcase
    !name.nil? && OWNER_FLAGS.any? { it.start_with?("--#{name}") }
  end

  # Second layer behind the settings.json deny list (P1-1): inside a Claude
  # Code session (CLAUDECODE=1) owner actions are refused unless the call is a
  # dry run the command honours, or the owner opts in with PODGEN_OWNER=1
  # (e.g. `! PODGEN_OWNER=1 bin/podgen publish x` from the Claude Code prompt).
  def self.refuse_owner_action?(command_name, argv, options)
    return false unless ENV["CLAUDECODE"] == "1" && ENV["PODGEN_OWNER"] != "1"
    return false if dry_run_exempt?(command_name, argv, options)

    owner_action?(command_name, argv, options)
  end

  # The global flag, or the command's own --dry-run as ITS parser reads it
  # (generate P3-7, publish/tweet P8-10). unpublish has no local --dry-run:
  # global flag only. The token rule answers only when the dry parse fails
  # (the command would then refuse to run anyway).
  def self.dry_run_exempt?(command_name, argv, options)
    return false unless DRY_RUN_HONOURED.include?(command_name)
    return true if options[:dry_run]
    return !!generate_dry_parse(argv)&.dig(:dry_run) if command_name == "generate"
    return false if command_name == "unpublish" # no local --dry-run: global flag only

    parsed = owner_command_dry_parse(command_name, argv)
    return !!parsed[:dry_run] if parsed

    dry_run_token?(argv)
  end

  # What publish's / tweet's own parser would set for this argv, or nil when
  # that parse would fail. Loaded lazily, like generate_dry_parse.
  def self.owner_command_dry_parse(command_name, argv)
    case command_name
    when "publish"
      require_relative "cli/publish_options"
      PublishOptions.dry_parse(argv)
    when "tweet"
      require_relative "cli/tweet_options"
      TweetOptions.dry_parse(argv)
    end
  end

  # Fallback only (unparseable argv): a literal `--dry-run` exempts when it
  # cannot be the value of a preceding option (`publish p --date --dry-run`
  # is a real sync): it is the first token, or follows a non-option or an
  # `--opt=value` token (P3-7).
  def self.dry_run_token?(argv)
    # Under POSIXLY_CORRECT OptionParser stops at the first positional, so a
    # later --dry-run would be an argument, not a flag (CRPR Gate 3 round 3).
    return false if ENV.key?("POSIXLY_CORRECT")

    tokens = argv.take_while { it != "--" }
    tokens.each_with_index.any? do |token, i|
      next false unless token == "--dry-run"

      prev = i.zero? ? nil : tokens[i - 1]
      prev.nil? || !prev.start_with?("-") || prev.include?("=")
    end
  end

  def self.run(argv)
    options = { verbosity: :normal }

    global = OptionParser.new do |opts|
      opts.banner = "Usage: podgen [options] <command> [args]"
      opts.separator ""
      opts.separator "Fully autonomous podcast generation pipeline."
      opts.separator ""
      opts.separator "Commands:"
      command_help_lines.each { opts.separator(it) }
      opts.separator ""
      opts.separator "Pipelines (`- type:` under ## Podcast in guidelines.md):"
      opts.separator "  news      Research topics, write script, TTS, assemble MP3 (default)"
      opts.separator "  language  Download from RSS, --file, or --url (YouTube), transcribe, assemble MP3"
      opts.separator ""
      opts.separator "Transcription engines (`- engine:` under ## Audio in guidelines.md):"
      opts.separator "  open      OpenAI Whisper / gpt-4o-transcribe (default)"
      opts.separator "  elab      ElevenLabs Scribe v2"
      opts.separator "  groq      Groq hosted Whisper"
      opts.separator "  List multiple engines for side-by-side comparison mode."
      opts.separator ""
      opts.separator "Tests:"
      opts.separator "  research, rss, hn, claude_web, bluesky, x, script, tts,"
      opts.separator "  assembly, translation, transcription, sources"
      opts.separator "  Example: podgen test transcription lahko_noc elab"
      opts.separator "           podgen test transcription audio.mp3 all"
      opts.separator ""
      opts.separator "Options:"

      opts.on("-v", "--verbose", "Verbose output") { options[:verbosity] = :verbose }
      opts.on("-q", "--quiet",   "Suppress terminal output (errors still shown)") { options[:verbosity] = :quiet }
      opts.on("--dry-run", "Validate config, skip API calls and file output") { options[:dry_run] = true }
      opts.on("--lingq", "Enable LingQ upload (generate) or publish to LingQ (publish)") { options[:lingq] = true }
      opts.on("-V", "--version", "Print version and exit") do
        puts "podgen #{VERSION}"
        return 0
      end
      opts.on("-h", "--help", "Show this help") do
        puts opts
        return 0
      end
    end

    begin
      global.order!(argv)
    rescue OptionParser::InvalidOption => e
      $stderr.puts "#{e.message}\n\n#{global}"
      return 2
    end

    command_name = argv.shift

    unless command_name
      puts global
      return 2
    end

    entry = COMMANDS[command_name]
    unless entry
      $stderr.puts "Unknown command: #{command_name}\n\n#{global}"
      return 2
    end

    if refuse_owner_action?(command_name, argv, options)
      $stderr.puts "podgen: '#{command_name}' is an owner action; refusing inside a Claude Code session (PODGEN_OWNER=1 overrides)"
      $stderr.puts DRY_RUN_HINT if options[:dry_run] || argv.include?("--dry-run")
      return 2
    end

    _, require_path, class_name = entry
    require_relative require_path

    begin
      cmd = PodgenCLI.const_get(class_name).new(argv, options)
    rescue OptionParser::ParseError => e
      $stderr.puts "#{command_name}: #{e.message}"
      return 2
    end
    cmd.run
  end
end
