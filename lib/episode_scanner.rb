# frozen_string_literal: true

# Enumerates publishable episodes in a podcast's episodes_dir.
#
# An episode is "publishable" when both its `.mp3` and a text file
# (`_transcript.md` preferred, `_script.md` fallback) exist. Returns a list
# of `{ base_name:, mp3_path:, transcript_path: }` hashes sorted by basename
# (chronological since basenames embed the date).
#
# When `episode_id:` is given, the result is filtered to entries whose
# basename ends with that id — same semantics PublishCommand has used for
# its `--date` flag, now applied to every publisher that consumes the scan.
module EpisodeScanner
  module_function

  def scan(episodes_dir, episode_id: nil)
    return [] unless episodes_dir && Dir.exist?(episodes_dir)

    episodes = Dir.glob(File.join(episodes_dir, "*.mp3"))
      .sort
      .filter_map do |mp3_path|
        base_name = File.basename(mp3_path, ".mp3")
        text_path = find_text_file(episodes_dir, base_name)
        next unless text_path
        { base_name: base_name, mp3_path: mp3_path, transcript_path: text_path }
      end

    return episodes unless episode_id
    episodes.select { |ep| ep[:base_name].end_with?(episode_id) }
  end

  # Prefer the transcribed version (language pipeline) over the authored
  # script (news pipeline). Some publishers may need either; the preference
  # order matches what publish_command + youtube_publisher + lingq_publisher
  # already converged on.
  def find_text_file(episodes_dir, base_name)
    %w[_transcript.md _script.md].each do |suffix|
      path = File.join(episodes_dir, "#{base_name}#{suffix}")
      return path if File.exist?(path)
    end
    nil
  end
end
