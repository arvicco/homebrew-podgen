# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "loggable"
require_relative "snip_interval"

class AudioTrimmer
  include Loggable

  MIN_OUTRO_SAVINGS = 5 # minimum seconds saved to bother trimming outro
  MIN_PREFIX = 3 # minimum chars for fuzzy word prefix matching
  # Max seconds the matched anchor may be before groq's last known word.
  # Larger gap → engines disagree on the ending, anchor is unreliable.
  # Bajke-2026-04-30 wrongly cut 48s under the old single-word fallback;
  # this guardrail catches that pattern.
  MAX_TAIL_GAP_SECONDS = 10.0

  attr_reader :temp_files

  def initialize(assembler:, logger: nil)
    @assembler = assembler
    @logger = logger
    @temp_files = []
  end

  # Applies skip/cut/snip trimming to audio.
  # Returns the (possibly new) audio path.
  def apply_trim(audio_path, skip: nil, cut: nil, snip: nil)
    return audio_path unless (skip && skip > 0) || (cut && cut > 0) || snip

    total = @assembler.probe_duration(audio_path)
    removal = snip ? snip.dup : SnipInterval.empty

    if skip && skip > 0
      skip_to = skip.to_f
      removal.add(0, skip_to)
      log("Skip: removing 0-#{format_timestamp(skip_to)}")
    end

    if cut && cut > 0
      cut_point = cut.respond_to?(:absolute?) && cut.absolute? ? cut.to_f : total - cut.to_f
      if cut_point > 0 && cut_point < total
        removal.add(cut_point, total)
        log("Cut: removing #{format_timestamp(cut_point)}-#{format_timestamp(total)}")
      else
        log("Warning: cut value results in invalid cut point (#{cut_point.round(1)}s of #{total.round(1)}s) — skipping cut")
      end
    end

    log("Snip: removing #{snip}") if snip

    keeps = removal.keep_segments(total)
    if keeps.any? && keeps != [SnipInterval::Interval.new(0.0, total)]
      trimmed_path = File.join(Dir.tmpdir, "podgen_trimmed_#{Process.pid}.mp3")
      @temp_files << trimmed_path
      @assembler.snip_segments(audio_path, trimmed_path, keeps)
      kept_duration = keeps.sum { |s| s.to - s.from }
      log("Trimmed: #{total.round(1)}s → #{kept_duration.round(1)}s (removed #{(total - kept_duration).round(1)}s)")
      trimmed_path
    else
      log("No effective trimming needed after resolving skip/cut/snip")
      audio_path
    end
  end

  # Trims outro by mapping reconciled text to Groq word timestamps.
  # Returns the (possibly new) audio path.
  def trim_outro(audio_path, reconciled_text:, groq_words:, base_name:, tails_dir:)
    speech_end = find_speech_end_timestamp(reconciled_text, groq_words)

    unless speech_end
      log("Could not match reconciled text ending to Groq timestamps — skipping trim")
      return audio_path
    end

    total_duration = @assembler.probe_duration(audio_path)
    savings = total_duration - speech_end
    trim_point = speech_end + 2 # 2s padding after last word

    if savings < MIN_OUTRO_SAVINGS
      log("Outro trim would only save #{savings.round(1)}s (< #{MIN_OUTRO_SAVINGS}s) — skipping")
      return audio_path
    end

    log("Speech ends at #{speech_end.round(1)}s, trimming at #{trim_point.round(1)}s " \
      "(saving #{savings.round(1)}s of #{total_duration.round(1)}s)")

    # Save tail for review
    FileUtils.mkdir_p(tails_dir)
    tail_path = File.join(tails_dir, "#{base_name}_tail.mp3")
    @assembler.extract_segment(audio_path, tail_path, trim_point, total_duration)
    log("Saved tail for review: #{tail_path}")

    # Trim audio
    trimmed_path = File.join(Dir.tmpdir, "podgen_autotrimmed_#{Process.pid}.mp3")
    @temp_files << trimmed_path
    @assembler.trim_to_duration(audio_path, trimmed_path, trim_point)
    trimmed_path
  end

  # Maps the last words of reconciled text back to Groq's word-level timestamps.
  # Tries matching last 5 words, then 4, 3, 2 (n=1 dropped — too brittle).
  # If the matched anchor is more than MAX_TAIL_GAP_SECONDS before groq's last
  # word, refuses the match (engines disagree on ending, autotrim unreliable).
  # Returns the end timestamp of the matched word, or nil if no safe match.
  def find_speech_end_timestamp(reconciled_text, groq_words)
    reconciled_words = reconciled_text.split(/\s+/).reject(&:empty?)
    return nil if reconciled_words.empty?
    return nil if groq_words.nil? || groq_words.empty?

    groq_end = groq_words.last[:end]
    return nil if groq_end.nil?

    [5, 4, 3, 2].each do |n|
      next if reconciled_words.length < n

      target = reconciled_words.last(n).map { |w| normalize_word(w) }
      next if target.any?(&:empty?)

      (groq_words.length - n).downto(0) do |i|
        candidate = groq_words[i, n].map { |w| normalize_word(w[:word]) }
        next unless words_match?(target, candidate)

        matched_end = groq_words[i + n - 1][:end]
        gap = groq_end - matched_end
        if gap > MAX_TAIL_GAP_SECONDS
          log("Match for last #{n} words at #{matched_end.round(1)}s is #{gap.round(1)}s before " \
              "groq's last word (#{groq_end.round(1)}s) — anchor unreliable, skipping autotrim")
          return nil
        end

        log("Matched last #{n} words at Groq timestamp #{matched_end.round(1)}s: #{candidate.join(' ')} ~ #{target.join(' ')}")
        return matched_end
      end
    end

    log("No word sequence match found between reconciled text and Groq timestamps")
    nil
  end

  def format_timestamp(seconds)
    mins = (seconds / 60).to_i
    secs = (seconds % 60).round(1)
    format("%d:%04.1f", mins, secs)
  end

  private

  def normalize_word(word)
    word.downcase.gsub(/[^\p{L}\p{N}]/, "")
  end

  # Fuzzy sequence match: all word pairs must match.
  def words_match?(target, candidate)
    target.zip(candidate).all? { |a, b| word_match?(a, b) }
  end

  # Two normalized words match if they share a common prefix of 3+ chars.
  # Handles inflection differences (e.g. "sanjam"/"sanja", "noč"/"noči").
  def word_match?(a, b)
    return true if a == b

    shorter, longer = [a, b].sort_by(&:length)
    return false if shorter.length < MIN_PREFIX

    longer.start_with?(shorter)
  end
end
