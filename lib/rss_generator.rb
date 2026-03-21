# frozen_string_literal: true

require "rexml/document"
require "date"
require "time"
require "fileutils"
require "yaml"
require "open3"
require_relative "loggable"
require_relative "audio_assembler"
require_relative "episode_filtering"
require_relative "transcript_renderer"
require_relative "history_maps"

class RssGenerator
  include Loggable
  include TranscriptRenderer

  # Converts markdown transcripts/scripts to HTML for podcast apps.
  # Skips files where the HTML is already up-to-date.
  def self.convert_transcripts(episodes_dir)
    renderer = new_renderer
    Dir.glob(File.join(episodes_dir, "*_{transcript,script}.md")).each do |md_path|
      html_path = md_path.sub(/\.md$/, ".html")
      next if File.exist?(html_path) && File.mtime(html_path) >= File.mtime(md_path)

      text = File.read(md_path)
      body = if text.include?("## Transcript")
        text.split("## Transcript", 2).last
      else
        text.sub(/\A#[^\n]*\n+([^\n]*\n+)?/, "")
      end
      content = renderer.render_body_html(body, vocab: false)
      html = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head>\n<body>\n#{content}\n</body></html>\n"
      File.write(html_path, html)
    end
  end

  # Minimal instance for class-method access to TranscriptRenderer
  def self.new_renderer
    allocate
  end

  def initialize(episodes_dir:, feed_path:, title: "Podcast", description: nil, author: "Podcast Agent", language: "en", base_url: nil, image: nil, history_path: nil, logger: nil)
    @logger = logger
    @episodes_dir = episodes_dir
    @feed_path = feed_path
    @title = title
    @description = description
    @author = author
    @language = language
    @base_url = base_url&.chomp("/")
    @image = image
    @title_map, @timestamp_map, @duration_map = HistoryMaps.build(
      history_path: history_path,
      podcast_name: File.basename(File.dirname(@episodes_dir)),
      episodes_dir: @episodes_dir,
      languages: @language != "en" ? [@language] : []
    )
  end

  def generate
    episodes = scan_episodes
    log("Found #{episodes.length} episodes")

    doc = build_feed(episodes)

    FileUtils.mkdir_p(File.dirname(@feed_path))
    File.open(@feed_path, "w") do |f|
      formatter = REXML::Formatters::Pretty.new(2)
      formatter.compact = true
      f.puts '<?xml version="1.0" encoding="UTF-8"?>'
      formatter.write(doc.root, f)
      f.puts
    end

    log("Feed written to #{@feed_path}")
    @feed_path
  end

  private

  def scan_episodes
    EpisodeFiltering.episodes_for_language(@episodes_dir, @language)
      .sort
      .reverse
      .filter_map do |path|
        date = EpisodeFiltering.parse_date(path)
        next unless date

        {
          path: path,
          filename: File.basename(path),
          date: date,
          size: File.size(path)
        }
      end
  end

  def build_feed(episodes)
    doc = REXML::Document.new
    rss = doc.add_element("rss", {
      "version" => "2.0",
      "xmlns:itunes" => "http://www.itunes.com/dtds/podcast-1.0.dtd",
      "xmlns:content" => "http://purl.org/rss/1.0/modules/content/",
      "xmlns:podcast" => "https://podcastindex.org/namespace/1.0"
    })

    channel = rss.add_element("channel")
    add_text(channel, "title", @title)
    add_text(channel, "description", strip_markdown_links(@description || "Podcast by #{@author}"))
    add_text(channel, "link", @base_url) if @base_url
    add_text(channel, "language", @language)
    add_text(channel, "generator", "podgen")
    add_text(channel, "itunes:author", @author)
    if @image && @base_url
      image_url = "#{@base_url}/#{@image}"
      itunes_image = channel.add_element("itunes:image")
      itunes_image.add_attribute("href", image_url)
      rss_image = channel.add_element("image")
      add_text(rss_image, "url", image_url)
      add_text(rss_image, "title", @title)
      add_text(rss_image, "link", @base_url)
    end
    add_text(channel, "itunes:explicit", "false")
    add_text(channel, "lastBuildDate", Time.now.strftime("%a, %d %b %Y %H:%M:%S %z"))

    episodes.each do |ep|
      item = channel.add_element("item")
      ep_title = @title_map[ep[:filename]]
      title = ep_title || "#{@title} — #{ep[:date].strftime('%B %d, %Y')}"
      add_text(item, "title", title)
      pub_time = @timestamp_map[ep[:filename]]
      pub_date = if pub_time
        Time.parse(pub_time).strftime("%a, %d %b %Y %H:%M:%S %z")
      else
        ep[:date].to_time.strftime("%a, %d %b %Y 06:00:00 %z")
      end
      add_text(item, "pubDate", pub_date)
      add_text(item, "itunes:author", @author)
      add_text(item, "itunes:duration", format_duration(ep))

      ep_url = @base_url ? "#{@base_url}/episodes/#{ep[:filename]}" : ep[:filename]
      enclosure = item.add_element("enclosure", {
        "url" => ep_url,
        "length" => ep[:size].to_s,
        "type" => "audio/mpeg"
      })

      add_text(item, "guid", ep[:filename])

      # Add transcript link if HTML version exists (transcript or script)
      if @base_url
        ep_base = File.basename(ep[:filename], ".mp3")
        transcript_name = %w[_transcript.html _script.html]
          .map { |suffix| ep_base + suffix }
          .find { |name| File.exist?(File.join(@episodes_dir, name)) }
        if transcript_name
          item.add_element("podcast:transcript", {
            "url" => "#{@base_url}/episodes/#{transcript_name}",
            "type" => "text/html"
          })
        end
      end
    end

    doc
  end

  def strip_markdown_links(text)
    text.gsub(/\[([^\]]+)\]\([^)]+\)/, '\1')
  end

  def add_text(parent, name, text)
    el = parent.add_element(name)
    el.text = text
    el
  end

  # Duration from history, falling back to ffprobe, then 192kbps estimate
  def format_duration(ep)
    seconds = @duration_map[ep[:filename]] || AudioAssembler.probe_duration(ep[:path]) || ep[:size] / (192_000.0 / 8)
    minutes = (seconds / 60).to_i
    secs = (seconds % 60).to_i
    format("%d:%02d", minutes, secs)
  end
end
