# frozen_string_literal: true

require_relative "base_validator"

module Validators
  class OrphansValidator < BaseValidator
    private

    def check
      episodes_dir = @config.episodes_dir
      return unless Dir.exist?(episodes_dir)

      mp3_bases = Dir.glob(File.join(episodes_dir, "*.mp3"))
        .reject { |f| File.basename(f).include?("_concat") }
        .map { |f| File.basename(f, ".mp3") }
        .to_set

      orphan_texts = Dir.glob(File.join(episodes_dir, "*_{transcript,script}.{md,html}"))
        .select { |f|
          base = File.basename(f).sub(/_(transcript|script)\.(md|html)$/, "")
          !mp3_bases.include?(base)
        }

      unless orphan_texts.empty?
        @warnings << "Orphans: #{orphan_texts.length} transcript/script file#{'s' unless orphan_texts.length == 1} without matching MP3"
      end

      concat_files = Dir.glob(File.join(episodes_dir, "*_concat*"))
      unless concat_files.empty?
        @warnings << "Orphans: #{concat_files.length} stale _concat file#{'s' unless concat_files.length == 1}"
      end
    end
  end
end
