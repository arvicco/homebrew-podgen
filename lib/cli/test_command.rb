# frozen_string_literal: true

module PodgenCLI
  class TestCommand
    TESTS = {
      "research"   => "test_research.rb",
      "rss"        => "test_rss.rb",
      "hn"         => "test_hn.rb",
      "claude_web" => "test_claude_web.rb",
      "script"     => "test_script.rb",
      "tts"        => "test_tts.rb",
      "assembly"   => "test_assembly.rb",
      "sources"    => "test_sources_no_exa.rb",
      "translation" => "test_translation.rb",
      "bluesky"    => "test_bluesky.rb",
      "x"              => "test_x.rb",
      "transcription"  => "test_transcription.rb",
      "cover"          => "test_cover.rb",
      "lingq_upload"   => "test_lingq_upload.rb"
    }.freeze

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
        return 2
      end

      script = TESTS[@test_name]
      unless script
        $stderr.puts "Unknown test: #{@test_name}"
        $stderr.puts "Available: #{TESTS.keys.join(', ')}"
        return 2
      end

      script_path = File.join(File.expand_path("../..", __dir__), "scripts", script)
      success = system(RbConfig.ruby, script_path, *@test_args)
      success ? 0 : 1
    end
  end
end
