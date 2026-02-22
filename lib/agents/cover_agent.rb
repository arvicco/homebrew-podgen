# frozen_string_literal: true

require "open3"
require "fileutils"
require "tmpdir"

class CoverAgent
  DEFAULTS = {
    font: "Patrick Hand",
    font_color: "#2B3A67",
    font_size: 126,
    text_width: 980,
    text_height: 560,
    gravity: "Center",
    x_offset: 200,
    y_offset: 0
  }.freeze

  # Approximate characters per line at default 90px in Patrick Hand.
  # Used for word-wrapping into SVG <tspan> elements.
  CHARS_PER_LINE_AT_90 = 14

  def initialize(logger: nil)
    @logger = logger
    verify_deps!
  end

  # Generates a cover image by overlaying uppercased title text onto a base image.
  # Uses SVG + rsvg-convert for text rendering, then magick for compositing.
  # Returns output_path on success.
  def generate(title:, base_image:, output_path:, options: {})
    raise "Base image not found: #{base_image}" unless File.exist?(base_image)

    opts = DEFAULTS.merge(options)
    text = title.upcase

    FileUtils.mkdir_p(File.dirname(output_path))

    text_png = File.join(Dir.tmpdir, "podgen_text_#{Process.pid}.png")
    begin
      render_text_to_png(text, text_png, opts)
      composite(base_image, text_png, output_path, opts)
    ensure
      File.delete(text_png) if File.exist?(text_png)
    end

    log("Cover generated: #{(File.size(output_path) / 1024.0).round(1)} KB")
    output_path
  end

  private

  # Renders text to a transparent PNG via SVG + rsvg-convert.
  def render_text_to_png(text, output_path, opts)
    lines = wrap_text(text, opts[:text_width], opts[:font_size])
    svg = build_svg(lines, opts)

    svg_path = output_path.sub(/\.png$/, ".svg")
    File.write(svg_path, svg)

    _stdout, stderr, status = Open3.capture3("rsvg-convert", svg_path, "-o", output_path)
    File.delete(svg_path) if File.exist?(svg_path)

    unless status.success?
      raise "rsvg-convert failed: #{stderr.strip}"
    end
  end

  # Composites text PNG onto base image using magick.
  def composite(base_image, text_png, output_path, opts)
    args = [
      "magick", base_image, text_png,
      "-gravity", opts[:gravity].to_s,
      "-geometry", "+#{opts[:x_offset]}+#{opts[:y_offset]}",
      "-composite",
      "-quality", "92",
      output_path
    ]

    log("Generating cover: \"#{File.basename(output_path)}\" (font: #{opts[:font]})")
    _stdout, stderr, status = Open3.capture3(*args)

    unless status.success?
      raise "ImageMagick composite failed: #{stderr.strip}"
    end
  end

  # Word-wraps text into lines that fit within the given pixel width.
  # Estimates characters per line based on font size ratio.
  def wrap_text(text, width, font_size)
    chars_per_line = (CHARS_PER_LINE_AT_90 * (width / 700.0) * (90.0 / font_size)).round
    chars_per_line = [chars_per_line, 4].max

    words = text.split
    lines = []
    current = ""

    words.each do |word|
      candidate = current.empty? ? word : "#{current} #{word}"
      if candidate.length <= chars_per_line
        current = candidate
      else
        lines << current unless current.empty?
        current = word
      end
    end
    lines << current unless current.empty?

    lines
  end

  # Builds an SVG document with centered, multi-line text.
  def build_svg(lines, opts)
    width = opts[:text_width]
    height = opts[:text_height]
    font_size = opts[:font_size]
    font = opts[:font]
    color = opts[:font_color]
    line_spacing = (font_size * 1.15).round
    x_center = width / 2

    # Vertically center: first line baseline, then dy offsets
    total_text_height = font_size + (lines.length - 1) * line_spacing
    first_y = ((height - total_text_height) / 2.0 + font_size * 0.85).round

    tspans = lines.each_with_index.map do |line, i|
      escaped = line.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      if i == 0
        %(<tspan x="#{x_center}" y="#{first_y}">#{escaped}</tspan>)
      else
        %(<tspan x="#{x_center}" dy="#{line_spacing}">#{escaped}</tspan>)
      end
    end.join("\n    ")

    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}">
        <text text-anchor="middle"
              font-family="#{font}" font-size="#{font_size}" fill="#{color}">
          #{tspans}
        </text>
      </svg>
    SVG
  end

  def verify_deps!
    verify_cmd!("magick", "ImageMagick", "brew install imagemagick")
    verify_cmd!("rsvg-convert", "librsvg", "brew install librsvg")
  end

  def verify_cmd!(cmd, name, install_hint)
    _out, _err, status = Open3.capture3(cmd, "--version")
    return if status.success?

    raise "#{name} is not installed or not on $PATH. Install with: #{install_hint}"
  rescue Errno::ENOENT
    raise "#{name} is not installed or not on $PATH. Install with: #{install_hint}"
  end

  def log(message)
    if @logger
      @logger.log("[CoverAgent] #{message}")
    else
      puts "[CoverAgent] #{message}"
    end
  end
end
