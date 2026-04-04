# frozen_string_literal: true

require "optparse"
require "net/http"
require "uri"
require "json"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "cli", "podcast_command")

module PodgenCLI
  class ScheduleCommand
    include PodcastCommand

    attr_reader :hour, :minute

    def initialize(args, options)
      @options = options
      @hour = 6
      @minute = 0
      @publish = false
      @telegram = false
      @test = false

      OptionParser.new do |opts|
        opts.on("--time HH:MM", "Time to run in 24h format (default: 06:00)") { |t| parse_time!(t) }
        opts.on("--publish", "Run publish after successful generate") { @publish = true }
        opts.on("--telegram", "Send Telegram alert on failure") { @telegram = true }
        opts.on("--test", "Send a test Telegram message and exit") { @test = true }
      end.parse!(args)

      @podcast_name = args.shift
    end

    def publish? = @publish
    def telegram? = @telegram
    def test? = @test

    def installer_args
      args = [@podcast_name, @hour.to_s, @minute.to_s]
      args << "--publish" if @publish
      args << "--telegram" if @telegram
      args
    end

    def run
      code = require_podcast!("schedule")
      return code if code

      return send_test_message if @test

      return 1 unless valid_time?

      script_path = File.join(File.expand_path("../..", __dir__), "scripts", "install_scheduler.sh")
      exec("bash", script_path, *installer_args)
    end

    private

    def parse_time!(str)
      match = str.match(/\A(\d{1,2}):(\d{2})\z/)
      unless match
        @time_error = "Invalid time format: #{str} (expected HH:MM)"
        return
      end
      @hour = match[1].to_i
      @minute = match[2].to_i
    end

    def valid_time?
      if @time_error
        $stderr.puts "Error: #{@time_error}"
        return false
      end
      unless (0..23).include?(@hour) && (0..59).include?(@minute)
        $stderr.puts "Error: Invalid time format: #{format('%02d:%02d', @hour, @minute)} (hour 0-23, minute 0-59)"
        return false
      end
      true
    end

    def send_test_message
      config = load_config!
      token = ENV["TELEGRAM_BOT_TOKEN"]
      chat_id = ENV["TELEGRAM_CHAT_ID"]

      unless token && !token.empty? && chat_id && !chat_id.empty?
        $stderr.puts "Error: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set in .env"
        return 1
      end

      message = "podgen: Telegram alerts configured for `#{@podcast_name}`"
      uri = URI("https://api.telegram.org/bot#{token}/sendMessage")
      res = Net::HTTP.post_form(uri, chat_id: chat_id, text: message, parse_mode: "Markdown")

      if res.is_a?(Net::HTTPSuccess)
        puts "Test message sent to Telegram."
        0
      else
        body = JSON.parse(res.body) rescue {}
        $stderr.puts "Telegram API error: #{res.code} — #{body['description'] || res.body}"
        1
      end
    end
  end
end
