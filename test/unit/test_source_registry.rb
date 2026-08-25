# frozen_string_literal: true

require_relative "../test_helper"
require "source_registry"

class TestSourceRegistry < Minitest::Test
  def test_entries_have_required_fields
    SourceRegistry.entries.each do |entry|
      refute_nil entry.name, "entry missing name"
      assert_match(/\A[a-z0-9_]+\z/, entry.name, "name should be a snake_case slug: #{entry.name}")
      refute_nil entry.host, "#{entry.name}: missing host"
      refute_match(%r{\Ahttps?://}, entry.host, "#{entry.name}: host must be bare (no scheme)")
      assert_match(%r{\Ahttps://}, entry.probe_url, "#{entry.name}: probe_url must be https")
      assert_includes SourceRegistry::EXPECTATIONS, entry.expect,
        "#{entry.name}: expect must be one of #{SourceRegistry::EXPECTATIONS}"
    end
  end

  def test_entry_names_unique
    names = SourceRegistry.entries.map(&:name)
    assert_equal names.uniq, names, "duplicate entry names"
  end

  def test_hosts_unique
    hosts = SourceRegistry.entries.map(&:host)
    assert_equal hosts.uniq, hosts, "duplicate hosts"
  end

  def test_registered_matches_host_and_subdomain
    assert SourceRegistry.registered?("api.elevenlabs.io")
    refute SourceRegistry.registered?("evil-elevenlabs.io")
    refute SourceRegistry.registered?("unregistered.example.org")
  end

  def test_ignored_hosts_are_not_registered_entries
    SourceRegistry::IGNORED_HOSTS.each do |host|
      refute SourceRegistry.registered?(host),
        "#{host} is both ignored and registered — pick one"
    end
  end

  def test_known_service_hosts_present
    hosts = SourceRegistry.entries.map(&:host)
    %w[
      api.anthropic.com api.openai.com api.elevenlabs.io api.groq.com
      texttospeech.googleapis.com www.lingq.com hn.algolia.com
      bsky.social api.socialdata.tools api.telegram.org
      api.cloudflare.com duckduckgo.com api.exa.ai www.googleapis.com
    ].each do |host|
      assert_includes hosts, host, "expected #{host} registered"
    end
  end
end
