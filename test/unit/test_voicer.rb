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

  # Mocks that record what was sent through them.
  class MockTTSAgent
    attr_reader :init_args, :synth_args
    def initialize(**kwargs)
      @init_args = kwargs
      @synth_args = nil
    end
    def synthesize(segments)
      @synth_args = segments
      # Mimic real TTSAgent behavior: write each chunk to disk and return paths.
      segments.each_with_index.map do |_, i|
        path = File.join(Dir.tmpdir, "voicer_test_#{$$}_#{i}.mp3")
        File.write(path, "fake-tts")
        path
      end
    end
  end

  class MockAssembler
    attr_reader :assemble_args
    def initialize(**); end
    def assemble(audio_paths, output_path, **kw)
      @assemble_args = { audio_paths: audio_paths, output_path: output_path, kwargs: kw }
      File.write(output_path, "assembled")
    end
  end

  def test_voice_constructs_tts_with_overrides_and_pronunciation
    output_path = File.join(@tmpdir, "out.mp3")
    tts = MockTTSAgent.new
    asm = MockAssembler.new

    TTSAgent.stub :new, ->(**kw) { tts.instance_variable_set(:@init_args, kw); tts } do
      AudioAssembler.stub :new, asm do
        Voicer.new(logger: nil).voice(
          segments: [{ name: "Open", text: "Hi." }],
          output_path: output_path,
          voice_id: "voice-xyz",
          title: "T",
          author: "A",
          tts_model_id: "eleven_v3",
          pronunciation_pls_path: "/tmp/dict.pls"
        )
      end
    end

    assert_equal "voice-xyz", tts.init_args[:voice_id_override]
    assert_equal "eleven_v3", tts.init_args[:model_id_override]
    assert_equal "/tmp/dict.pls", tts.init_args[:pronunciation_pls_path]
  end

  def test_voice_passes_segments_to_tts_synthesize
    segments = [{ name: "Open", text: "Hello." }, { name: "Close", text: "Bye." }]
    tts = MockTTSAgent.new
    asm = MockAssembler.new

    TTSAgent.stub :new, tts do
      AudioAssembler.stub :new, asm do
        Voicer.new(logger: nil).voice(
          segments: segments, output_path: File.join(@tmpdir, "o.mp3"),
          voice_id: "v", title: "T", author: "A"
        )
      end
    end

    assert_equal segments, tts.synth_args
  end

  def test_voice_passes_metadata_intro_outro_segment_pause_to_assembler
    output_path = File.join(@tmpdir, "out.mp3")
    intro = "/intro.mp3"
    outro = "/outro.mp3"
    tts = MockTTSAgent.new
    asm = MockAssembler.new

    TTSAgent.stub :new, tts do
      AudioAssembler.stub :new, asm do
        Voicer.new(logger: nil).voice(
          segments: [{ name: "Open", text: "Hi." }],
          output_path: output_path,
          voice_id: "v",
          title: "Episode Title",
          author: "Author Name",
          intro_path: intro,
          outro_path: outro,
          segment_pause: 1.5
        )
      end
    end

    args = asm.assemble_args
    assert_equal output_path, args[:output_path]
    assert_equal intro, args[:kwargs][:intro_path]
    assert_equal outro, args[:kwargs][:outro_path]
    assert_equal({ title: "Episode Title", artist: "Author Name" }, args[:kwargs][:metadata])
    assert_in_delta 1.5, args[:kwargs][:segment_pause]
  end

  def test_voice_uses_default_segment_pause_when_not_given
    tts = MockTTSAgent.new
    asm = MockAssembler.new

    TTSAgent.stub :new, tts do
      AudioAssembler.stub :new, asm do
        Voicer.new(logger: nil).voice(
          segments: [{ name: "Open", text: "Hi." }],
          output_path: File.join(@tmpdir, "o.mp3"),
          voice_id: "v", title: "T", author: "A"
        )
      end
    end

    assert_in_delta Voicer::DEFAULT_SEGMENT_PAUSE, asm.assemble_args[:kwargs][:segment_pause]
  end

  def test_voice_deletes_intermediate_tts_files_after_assembly
    output_path = File.join(@tmpdir, "out.mp3")
    tts = MockTTSAgent.new
    asm = MockAssembler.new
    written_paths = nil

    TTSAgent.stub :new, tts do
      AudioAssembler.stub :new, asm do
        Voicer.new(logger: nil).voice(
          segments: [{ name: "A", text: "1." }, { name: "B", text: "2." }],
          output_path: output_path,
          voice_id: "v", title: "T", author: "A"
        )
        written_paths = asm.assemble_args[:audio_paths]
      end
    end

    refute_empty written_paths
    written_paths.each do |p|
      refute File.exist?(p), "intermediate TTS file #{p} should be deleted after assembly"
    end
  end

  def test_voice_returns_output_path
    output_path = File.join(@tmpdir, "out.mp3")
    TTSAgent.stub :new, MockTTSAgent.new do
      AudioAssembler.stub :new, MockAssembler.new do
        result = Voicer.new(logger: nil).voice(
          segments: [{ name: "Open", text: "Hi." }],
          output_path: output_path,
          voice_id: "v", title: "T", author: "A"
        )
        assert_equal output_path, result
      end
    end
  end

  def test_default_segment_pause_constant
    assert_equal 2.0, Voicer::DEFAULT_SEGMENT_PAUSE
  end
end
