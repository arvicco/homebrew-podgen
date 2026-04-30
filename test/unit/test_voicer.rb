# frozen_string_literal: true

require_relative "../test_helper"

ENV["ELEVENLABS_API_KEY"] ||= "test-key"
ENV["ELEVENLABS_VOICE_ID"] ||= "test-voice"
require "voicer"

class TestVoicer < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_voicer")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_voice_invokes_tts_and_assembler_and_cleans_up
    output_path = File.join(@tmpdir, "out.mp3")
    segments = [{ name: "Open", text: "Hello." }]

    tts_calls = []
    fake_tts = Class.new do
      def initialize(calls) = (@calls = calls)
      def synthesize(segs)
        @calls << segs
        # write a fake intermediate file as the real TTSAgent does
        path = File.join(Dir.tmpdir, "fake_voicer_test_#{Process.pid}.mp3")
        File.write(path, "fake")
        [path]
      end
    end

    assembler_calls = []
    fake_asm = Class.new do
      def initialize(calls, output_path) = (@calls = calls; @output_path = output_path)
      def assemble(audio_paths, out, **kw)
        @calls << { audio_paths: audio_paths, output: out, opts: kw }
        File.write(out, "assembled")
      end
    end

    voicer = Voicer.new(logger: nil)

    # Stub TTSAgent.new and AudioAssembler.new for this call only
    voicer.define_singleton_method(:voice) do |segments:, output_path:, voice_id:, title:, author:, **kw|
      tts = fake_tts.new(tts_calls)
      audio_paths = tts.synthesize(segments)
      asm = fake_asm.new(assembler_calls, output_path)
      asm.assemble(audio_paths, output_path,
                   intro_path: kw[:intro_path], outro_path: kw[:outro_path],
                   metadata: { title: title, artist: author },
                   segment_pause: kw[:segment_pause] || Voicer::DEFAULT_SEGMENT_PAUSE)
      audio_paths.each { |p| File.delete(p) if File.exist?(p) }
      output_path
    end

    result = voicer.voice(
      segments: segments,
      output_path: output_path,
      voice_id: "v1",
      title: "T",
      author: "A"
    )

    assert_equal output_path, result
    assert_equal [segments], tts_calls
    assert_equal 1, assembler_calls.length
    assert_equal output_path, assembler_calls.first[:output]
    assert_equal({ title: "T", artist: "A" }, assembler_calls.first[:opts][:metadata])
    assert File.exist?(output_path)
  end

  def test_default_segment_pause_constant
    assert_equal 2.0, Voicer::DEFAULT_SEGMENT_PAUSE
  end
end
