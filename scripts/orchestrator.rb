#!/usr/bin/env ruby
# frozen_string_literal: true

# Podcast Agent — Main Orchestrator
# Runs the full pipeline: research → script → TTS → audio assembly

require "bundler/setup"
require "dotenv/load"
require "yaml"
require "date"

root = File.expand_path("..", __dir__)

require_relative File.join(root, "lib", "logger")
require_relative File.join(root, "lib", "agents", "research_agent")
require_relative File.join(root, "lib", "agents", "script_agent")
require_relative File.join(root, "lib", "agents", "tts_agent")
require_relative File.join(root, "lib", "audio_assembler")

logger = PodcastAgent::Logger.new
today = Date.today.strftime("%Y-%m-%d")

begin
  logger.log("Podcast Agent started")
  pipeline_start = Time.now

  # --- Verify prerequisites ---
  %w[config topics lib/agents scripts output/episodes logs/runs].each do |dir|
    path = File.join(root, dir)
    unless Dir.exist?(path)
      logger.error("Missing directory: #{dir}")
      exit 1
    end
  end

  %w[config/guidelines.md topics/queue.yml].each do |file|
    path = File.join(root, file)
    unless File.exist?(path)
      logger.error("Missing config file: #{file}")
      exit 1
    end
  end

  # --- Load config ---
  guidelines = File.read(File.join(root, "config", "guidelines.md"))
  logger.log("Loaded guidelines (#{guidelines.length} chars)")

  topics_data = YAML.load_file(File.join(root, "topics", "queue.yml"))
  topics = topics_data["topics"]
  logger.log("Loaded #{topics.length} topics: #{topics.join(', ')}")

  # --- Phase 1: Research ---
  logger.phase_start("Research")
  research_agent = ResearchAgent.new(logger: logger)
  research_data = research_agent.research(topics)
  total_findings = research_data.sum { |r| r[:findings].length }
  logger.log("Research complete: #{total_findings} findings across #{topics.length} topics")
  logger.phase_end("Research")

  # --- Phase 2: Script generation ---
  logger.phase_start("Script")
  script_agent = ScriptAgent.new(logger: logger)
  script = script_agent.generate(research_data)
  logger.log("Script generated: \"#{script[:title]}\" (#{script[:segments].length} segments)")
  logger.phase_end("Script")

  # --- Phase 3: TTS ---
  logger.phase_start("TTS")
  tts_agent = TTSAgent.new(logger: logger)
  audio_paths = tts_agent.synthesize(script[:segments])
  logger.log("TTS complete: #{audio_paths.length} audio files")
  logger.phase_end("TTS")

  # --- Phase 4: Audio assembly ---
  logger.phase_start("Assembly")
  output_path = File.join(root, "output", "episodes", "#{today}.mp3")
  intro_path = File.join(root, "assets", "intro.mp3")
  outro_path = File.join(root, "assets", "outro.mp3")

  assembler = AudioAssembler.new(logger: logger)
  assembler.assemble(audio_paths, output_path, intro_path: intro_path, outro_path: outro_path)
  logger.phase_end("Assembly")

  # --- Cleanup TTS temp files ---
  audio_paths.each { |p| File.delete(p) if File.exist?(p) }

  # --- Done ---
  total_time = (Time.now - pipeline_start).round(2)
  logger.log("Total pipeline time: #{total_time}s")
  logger.log("✓ Episode ready: #{output_path}")

  puts "\n✓ Episode ready: #{output_path}"

rescue => e
  logger.error("#{e.class}: #{e.message}")
  logger.error(e.backtrace.first(5).join("\n"))
  puts "\n✗ Pipeline failed: #{e.message}"
  exit 1
end
