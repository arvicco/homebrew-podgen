#!/usr/bin/env ruby
# frozen_string_literal: true

# Cover image generation test: generates cover images for all combinations of
# fonts x title lengths for visual comparison.
# Usage: podgen test cover [output_dir]

require "bundler/setup"
require "fileutils"
require "open3"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "agents", "cover_agent")

puts "=== Cover Image Generation Test ==="
puts

output_dir = ARGV[0] || File.join(root, "output", "cover_test")
FileUtils.mkdir_p(output_dir)

# Find a base image to use — check podcasts for one with base_image, else generate a placeholder
base_image = nil

# Look for lahko_no_text.jpg in any podcast dir
Dir.glob(File.join(root, "podcasts", "*", "lahko_no_text.jpg")).each do |path|
  base_image = path
  break
end

# Fallback: generate a simple placeholder base image
unless base_image
  base_image = File.join(output_dir, "_base_placeholder.jpg")
  puts "No base image found in podcasts, generating placeholder..."
  Open3.capture3(
    "magick", "-size", "1890x1063", "xc:#E8D5B7",
    "-quality", "92", base_image
  )
  puts "  Generated placeholder: #{base_image}"
end

puts "Base image: #{base_image}"
puts "Output dir: #{output_dir}"
puts

# Font names — fontconfig family names (as shown by fc-list).
# To add more: brew install --cask font-<name>, then add the family name here.
# Discover installed fonts with: fc-list | grep -i <name>
fonts = {
  "patrick_hand" => "Patrick Hand",
  "caveat_brush" => "Caveat Brush"
}

# Auto-discover additional installed fonts via fc-list
["Caveat"].each do |family|
  stdout, _err, status = Open3.capture3("fc-list", "--format=%{family}\n")
  if status.success? && stdout.include?(family)
    fonts[family.downcase.tr(" ", "_")] = family
  end
end

FONTS = fonts.freeze

TITLES = {
  "short" => "Tri miške",
  "medium" => "Palček in trije medvedi",
  "long" => "Kako je muca Muri ujela mišjo kraljico",
  "diacritics" => "Čebelica Žužu in škorpijon"
}.freeze

agent = CoverAgent.new

generated = 0
errors = 0

FONTS.each do |font_label, font_name|
  TITLES.each do |title_label, title|
    filename = "cover_#{font_label}_#{title_label}.jpg"
    output_path = File.join(output_dir, filename)

    begin
      agent.generate(
        title: title,
        base_image: base_image,
        output_path: output_path,
        options: { font: font_name }
      )
      size_kb = (File.size(output_path) / 1024.0).round(1)
      puts "  #{filename}: #{size_kb} KB"
      generated += 1
    rescue => e
      puts "  #{filename}: FAILED — #{e.message}"
      errors += 1
    end
  end
  puts
end

puts "=== Summary ==="
puts "  Generated: #{generated}/#{FONTS.length * TITLES.length}"
puts "  Errors: #{errors}" if errors > 0
puts "  Output: #{output_dir}"
puts
puts "=== Test complete ==="
