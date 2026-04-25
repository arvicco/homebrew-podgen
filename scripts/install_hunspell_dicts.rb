#!/usr/bin/env ruby
# frozen_string_literal: true

# Downloads hunspell .dic/.aff dictionary files from wooorm/dictionaries
# and installs them at ~/Library/Spelling/<LANG_CODE>.{dic,aff} so that
# Tell::Hunspell.supports?(<lang>) returns true.
#
# Usage:
#   ruby scripts/install_hunspell_dicts.rb               # languages of configured podcasts
#   ruby scripts/install_hunspell_dicts.rb it sl pl en   # explicit list
#
# Detects target languages from each podcast's ## Podcast → transcription_language.

require "net/http"
require "uri"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

require "tell/hunspell"
require "podcast_config"

# ISO 639-1 lang code → wooorm/dictionaries directory (BCP47).
# Most match 1:1; some need region or sub-tag.
WOOORM_DIR = {
  "sl" => "sl",
  "hr" => "hr",
  "sr" => "sr",
  "it" => "it",
  "de" => "de-AT",
  "fr" => "fr",
  "es" => "es",
  "pt" => "pt-PT",
  "en" => "en",
  "nl" => "nl",
  "pl" => "pl",
  "cs" => "cs",
  "sk" => "sk",
  "ro" => "ro",
  "hu" => "hu-HU",
  "da" => "da",
  "sv" => "sv",
  "fi" => "fi",
  "et" => "et",
  "lt" => "lt",
  "lv" => "lv",
  "el" => "el-GR",
  "tr" => "tr",
  "ru" => "ru",
  "uk" => "uk",
  "bg" => "bg",
  "no" => "nb",
  "ar" => "ar",
  "fa" => "fa"
}.freeze

DEST_DIR = File.join(Dir.home, "Library", "Spelling")
RAW_BASE = "https://raw.githubusercontent.com/wooorm/dictionaries/main/dictionaries"

def detect_podcast_languages
  PodcastConfig.available.each_with_object([]) do |name, langs|
    cfg = PodcastConfig.new(name)
    lang = cfg.transcription_language rescue nil
    langs << lang if lang && !lang.empty?
  end.uniq
end

def download(url, dest)
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) do |http|
    res = http.request(Net::HTTP::Get.new(uri.request_uri))
    return false unless res.is_a?(Net::HTTPSuccess)
    File.binwrite(dest, res.body)
    true
  end
rescue => e
  warn "  download failed: #{e.class}: #{e.message}"
  false
end

def install_lang(lang)
  hunspell_dict_name = Tell::Hunspell::DICT_MAP[lang]
  unless hunspell_dict_name
    warn "  skip '#{lang}': no hunspell dict mapping in Tell::Hunspell::DICT_MAP"
    return false
  end

  wooorm_dir = WOOORM_DIR[lang]
  unless wooorm_dir
    warn "  skip '#{lang}': no wooorm/dictionaries mapping (add to scripts/install_hunspell_dicts.rb)"
    return false
  end

  dic_dest = File.join(DEST_DIR, "#{hunspell_dict_name}.dic")
  aff_dest = File.join(DEST_DIR, "#{hunspell_dict_name}.aff")

  puts "Installing #{lang} → #{hunspell_dict_name}.{dic,aff}"
  ok_dic = download("#{RAW_BASE}/#{wooorm_dir}/index.dic", dic_dest)
  ok_aff = download("#{RAW_BASE}/#{wooorm_dir}/index.aff", aff_dest)

  if ok_dic && ok_aff
    puts "  installed: #{File.size(dic_dest)} B (.dic) + #{File.size(aff_dest)} B (.aff)"
    true
  else
    File.delete(dic_dest) if File.exist?(dic_dest) && !ok_dic
    File.delete(aff_dest) if File.exist?(aff_dest) && !ok_aff
    false
  end
end

# --- main ---

FileUtils.mkdir_p(DEST_DIR)

requested = ARGV.dup
requested = detect_podcast_languages if requested.empty?

if requested.empty?
  abort "No languages specified and no podcasts found. Pass language codes as args (e.g. 'it sl pl en')."
end

puts "Hunspell dict dir: #{DEST_DIR}"
puts "Source: #{RAW_BASE}"
puts "Languages: #{requested.join(', ')}"
puts

installed = requested.count { |lang| install_lang(lang) }
puts
puts "Installed dicts for #{installed}/#{requested.length} language(s)"
exit(installed == requested.length ? 0 : 1)
