# frozen_string_literal: true

module PodgenCLI
  class TestCommand
    ROOT = File.expand_path("../..", __dir__)

    # Tests migrated to minitest (test/ directory)
    MINITEST = {
      "research"       => "test/api/test_research.rb",
      "rss"            => "test/api/test_rss_source.rb",
      "hn"             => "test/api/test_hn.rb",
      "claude_web"     => "test/api/test_claude_web.rb",
      "script"         => "test/api/test_script.rb",
      "tts"            => "test/api/test_tts.rb",
      "assembly"       => "test/integration/test_assembly.rb",
      "sources"        => "test/api/test_sources.rb",
      "translation"    => "test/api/test_translation.rb",
      "bluesky"        => "test/api/test_bluesky.rb",
      "x"              => "test/api/test_x.rb",
      "stats_validate" => "test/integration/test_stats_validate.rb"
    }.freeze

    # Tests that remain as standalone scripts (diagnostic/visual)
    SCRIPTS = {
      "transcription"  => "test_transcription.rb",
      "cover"          => "test_cover.rb",
      "lingq_upload"   => "test_lingq_upload.rb",
      "trim"           => "test_trim.rb"
    }.freeze

    TESTS = MINITEST.merge(SCRIPTS).freeze

    def initialize(args, options)
      @test_name = args.shift
      @test_args = args
      @options = options
    end

    def run
      unless @test_name
        puts "Usage: podgen test <name>"
        puts
        puts "Available tests:"
        TESTS.each_key { |name| puts "  #{name}" }
        puts "  all          (run full test suite via rake)"
        return 2
      end

      return run_all if @test_name == "all"

      unless TESTS.key?(@test_name)
        $stderr.puts "Unknown test: #{@test_name}"
        $stderr.puts "Available: #{TESTS.keys.join(', ')}, all"
        return 2
      end

      if MINITEST.key?(@test_name)
        test_path = File.join(ROOT, MINITEST[@test_name])
        success = system(RbConfig.ruby, test_path, *@test_args)
      else
        script_path = File.join(ROOT, "scripts", SCRIPTS[@test_name])
        success = system(RbConfig.ruby, script_path, *@test_args)
      end

      success ? 0 : 1
    end

    private

    def run_all
      success = system("bundle", "exec", "rake", "test", chdir: ROOT)
      success ? 0 : 1
    end
  end
end
