# frozen_string_literal: true

require_relative "format_helper"
require_relative "validators/base_validator"
require_relative "validators/guidelines_validator"
require_relative "validators/episodes_validator"
require_relative "validators/transcripts_validator"
require_relative "validators/feed_validator"
require_relative "validators/cover_validator"
require_relative "validators/base_url_validator"
require_relative "validators/history_validator"
require_relative "validators/image_config_validator"
require_relative "validators/language_pipeline_validator"
require_relative "validators/news_pipeline_validator"
require_relative "validators/orphans_validator"

# Validates podcast configuration and output.
# Composes focused validator classes and returns structured results.
# Used by ValidateCommand (CLI) and available for testing/CI integration.
class PodcastValidator
  KNOWN_SOURCES = Validators::GuidelinesValidator::KNOWN_SOURCES

  VALIDATORS = [
    Validators::GuidelinesValidator,
    Validators::EpisodesValidator,
    Validators::TranscriptsValidator,
    Validators::FeedValidator,
    Validators::CoverValidator,
    Validators::BaseUrlValidator,
    Validators::HistoryValidator,
    Validators::ImageConfigValidator
  ].freeze

  PIPELINE_VALIDATORS = {
    "language" => Validators::LanguagePipelineValidator,
    "news" => Validators::NewsPipelineValidator
  }.freeze

  Result = Struct.new(:passes, :warnings, :errors, keyword_init: true) do
    def ok? = errors.empty?
    def clean? = errors.empty? && warnings.empty?
  end

  # Validate a podcast config. Returns a Result.
  def self.validate(config)
    new(config).run
  end

  def initialize(config)
    @config = config
    @passes = []
    @warnings = []
    @errors = []
  end

  def run
    validators = VALIDATORS.dup
    validators << (PIPELINE_VALIDATORS[@config.type] || Validators::NewsPipelineValidator)
    validators << Validators::OrphansValidator

    validators.compact.each { |klass| merge_result(klass.new(@config).validate) }

    Result.new(passes: @passes, warnings: @warnings, errors: @errors)
  end

  private

  def merge_result(result)
    @passes.concat(result[:passes])
    @warnings.concat(result[:warnings])
    @errors.concat(result[:errors])
  end

  # Delegation methods — allow tests and callers to invoke individual checks.
  def check_guidelines       = merge_result(Validators::GuidelinesValidator.new(@config).validate)
  def check_episodes         = merge_result(Validators::EpisodesValidator.new(@config).validate)
  def check_transcripts      = merge_result(Validators::TranscriptsValidator.new(@config).validate)
  def check_feed             = merge_result(Validators::FeedValidator.new(@config).validate)
  def check_cover            = merge_result(Validators::CoverValidator.new(@config).validate)
  def check_base_url         = merge_result(Validators::BaseUrlValidator.new(@config).validate)
  def check_history          = merge_result(Validators::HistoryValidator.new(@config).validate)
  def check_image_config     = merge_result(Validators::ImageConfigValidator.new(@config).validate)
  def check_language_pipeline = merge_result(Validators::LanguagePipelineValidator.new(@config).validate)
  def check_news_pipeline    = merge_result(Validators::NewsPipelineValidator.new(@config).validate)
  def check_orphans          = merge_result(Validators::OrphansValidator.new(@config).validate)

  def format_size(bytes)
    FormatHelper.format_size(bytes)
  end
end
