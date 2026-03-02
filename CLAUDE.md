# Podcast Agent — Claude Code Instructions

## Overview
Autonomous podcast pipeline. Ruby 3.2+, macOS, ffmpeg, yt-dlp, ImageMagick+librsvg.

**Two pipelines:**
1. **News** (`type: news`): Research topics → Claude script → TTS (ElevenLabs) → multi-language MP3s
2. **Language** (`type: language`): RSS/YouTube/local MP3 → multi-engine STT → Claude reconciliation → auto-trim outro → clean MP3 + transcript

**APIs:** Claude (topics, scripting, translation, reconciliation, description cleanup), Exa.ai (research), ElevenLabs (TTS + Scribe), OpenAI/Groq (transcription), yt-dlp (YouTube)

## Project Structure
```
bin/podgen                       # CLI entry point
podcasts/<name>/                 # Per-podcast: guidelines.md, queue.yml, pronunciation.pls, .env
lib/
  cli.rb                         # CLI dispatcher
  cli/
    generate_command.rb           # Pipeline dispatcher (news or language)
    language_pipeline.rb          # Language pipeline orchestrator
    translate_command.rb          # Backfill translations
    scrap_command.rb              # Remove last episode
    rss_command.rb                # RSS feed generation
    publish_command.rb            # Publish to R2 or LingQ
    list_command.rb | test_command.rb | schedule_command.rb
  podcast_config.rb              # Config resolver (paths, sources, languages from guidelines)
  source_manager.rb              # Parallel multi-source research
  research_cache.rb              # File cache (SHA256, 24h TTL, atomic writes)
  transcription/
    base_engine.rb | openai_engine.rb | elevenlabs_engine.rb | groq_engine.rb
    engine_manager.rb             # Single or parallel comparison mode
    reconciler.rb                 # Claude Opus reconciliation of multi-engine transcripts
  agents/
    topic_agent.rb | research_agent.rb | description_agent.rb | script_agent.rb
    tts_agent.rb | translation_agent.rb | transcription_agent.rb
    lingq_agent.rb | cover_agent.rb
  sources/
    rss_source.rb | hn_source.rb | claude_web_source.rb | bluesky_source.rb | x_source.rb
  youtube_downloader.rb | episode_history.rb | audio_assembler.rb | rss_generator.rb | logger.rb
output/<name>/                   # episodes/, tails/, research_cache/, history.yml, feed.xml
test/                            # unit/, integration/, api/ (minitest)
scripts/serve.rb                 # WEBrick server for RSS
```

## Pipeline Details

### News: `generate_command.rb`
1. TopicAgent (Claude) → fallback queue.yml
2. SourceManager → parallel sources → cache → merge
3. ScriptAgent (Claude structured output) → `_script.md`
4. Per language: translate → TTS (chunked) → assemble (ffmpeg: concat + crossfade + loudnorm)
5. Record history (with duration + timestamp)

### Language: `language_pipeline.rb`
1. Get episode: `--file` (local MP3) | `--url` (YouTube) | RSS (next unprocessed)
2. Download + apply skip/cut trimming (priority: CLI → per-feed → `## Audio`)
3. Transcribe via EngineManager (parallel engines). Groq provides word timestamps. Reconciler (Claude Opus) produces clean text
4. Clean title/description via DescriptionAgent (Claude Haiku) — non-fatal
5. Autotrim outro (opt-in): map reconciled text → Groq timestamps → trim at speech_end + 2s, save tail
6. Assemble: intro + trimmed audio + outro → loudnorm
7. Save transcript, resolve cover, optional LingQ upload (`--lingq`)
8. Record history (with duration + timestamp)

### Key behaviors
- **Multi-podcast:** `podcasts/<name>/` each with own config. `podgen generate <name>`
- **Input sources:** `--file PATH` (local MP3, dedup via `file://name:size`), `--url URL` (YouTube via yt-dlp, auto-thumbnail+captions), RSS (per-feed `skip: N cut: N autotrim: true base_image: PATH image: none`)
- **Flags:** `--title`, `--skip N`, `--cut N`, `--autotrim`, `--force` (skip dedup), `--image PATH|thumb|last`, `--base-image PATH`, `--lingq`, `--dry-run`
- **Autotrim:** Opt-in via `--autotrim`, per-feed, or `## Audio`. Requires 2+ engines including groq
- **Episode dedup:** News pipeline uses 7-day lookback; language pipeline checks all history (permanent). `--force` to bypass
- **Same-day suffix:** `name-date.mp3`, then `name-date-a.mp3`, etc.
- **Multi-language:** Language list in `## Podcast`. English first, then translations. Per-language voice IDs
- **Cover generation:** Title overlay on base_image via ImageMagick/SVG/rsvg-convert. Priority: `--image` → per-feed → `--base-image` → per-feed base_image → `## Image` → YouTube thumb → nil
- **TTS:** ElevenLabs with chunking (10k char limit), pronunciation dictionaries (`.pls`), trailing hallucination trimming via `/with-timestamps`
- **Transcript post-processing:** Claude Opus. Multi-engine: reconcile + remove hallucinations. Single: clean up. YouTube captions as tiebreaker reference
- **Publish:** `podgen publish <name>` → regenerate RSS → sync to R2 via rclone. `--lingq` for LingQ instead
- **Scrap:** `podgen scrap <name>` removes last episode files + history + LingQ tracking
- **Translate:** `podgen translate <name>` backfills translations (`--last N`, `--lang xx`)
- **RSS:** iTunes + Podcasting 2.0 namespaces, transcript tags, `base_url` for absolute URLs. pubDate from history timestamp (fallback: date + 06:00). Duration from history (fallback: ffprobe → size estimate)
- **Lockfile:** `flock` prevents concurrent runs per podcast

## Configuration

### guidelines.md sections
| Section | Description |
|---------|-------------|
| `## Podcast` | `name`, `type` (news/language), `author`, `description`, `language` (list with voice IDs), `base_url` |
| `## Format` | Length, structure, pacing (required for news) |
| `## Tone` | Voice and style (required for news) |
| `## Topics` | Default topic rotation (required for news) |
| `## Sources` | `exa` (or `exa: category`), `hackernews`, `rss:` (with URLs + per-feed options), `claude_web`, `bluesky`, `x:` |
| `## Audio` | `engine` list (`open`/`elab`/`groq`), `language`, `target_language`, `skip`, `cut`, `autotrim` |
| `## Image` | `cover`, `base_image`, `font`, `font_color`, `font_size`, `text_width`, `text_gravity`, `text_x_offset`, `text_y_offset` |
| `## LingQ` | `collection`, `level`, `tags`, `accent`, `status`. Image keys are legacy → prefer `## Image` |
| `## Do not include` | Content restrictions |

HTML comments (`<!-- -->`) are stripped before parsing.

### Environment variables
**Root `.env`:** `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL_ID` (eleven_multilingual_v2), `ELEVENLABS_OUTPUT_FORMAT` (mp3_44100_128), `ELEVENLABS_SCRIBE_MODEL` (scribe_v2), `EXA_API_KEY`, `CLAUDE_MODEL` (claude-opus-4-6), `CLAUDE_WEB_MODEL` (claude-haiku-4-5-20251001), `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD`, `SOCIALDATA_API_KEY`, `OPENAI_API_KEY`, `WHISPER_MODEL` (gpt-4o-mini-transcribe), `GROQ_API_KEY`, `GROQ_WHISPER_MODEL` (whisper-large-v3), `YOUTUBE_BROWSER` (chrome), `LINGQ_API_KEY`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_BUCKET`

Per-podcast `.env` overrides root via `Dotenv.overload`.

## Coding Standards
- Single responsibility per class/method
- API calls: retry with exponential backoff, keys from ENV only
- Paths: `File.join` + `__dir__`-relative, `require_relative` throughout
- Atomic writes (temp + rename) for history/cache
- Shell commands: `Open3.capture3` (capture stdout, stderr, status)
- Gems pinned `~> x.y`
- Research data: `[{ topic:, findings: [{ title:, url:, summary: }] }]`
- TTS splitting: paragraph → sentence → comma → whitespace → UTF-8-safe char boundary

## CLI Reference
```
podgen [flags] <command> <args>
  generate <podcast>   # Full pipeline
    --file PATH | --url URL | --title TEXT | --skip N | --cut N
    --autotrim | --force | --image PATH|thumb|last | --base-image PATH | --lingq
  translate <podcast>  # Backfill translations (--last N, --lang xx)
  scrap <podcast>      # Remove last episode
  rss <podcast>        # Generate RSS (--base-url URL)
  publish <podcast>    # Publish to R2 (--lingq for LingQ)
  stats <podcast>      # Stats (--all for summary)
  validate <podcast>   # Validate (--all)
  list                 # List podcasts
  test <name>          # Run diagnostic test
  schedule <podcast>   # Install launchd plist
Flags: -v  -q  --dry-run  --lingq  -V  -h
```

## Serving RSS (Tailscale Funnel)
`ruby scripts/serve.rb 8080` + `tailscale funnel 8080` → `https://<hostname>.ts.net/<podcast>/feed.xml`. Requires Tailscale HTTPS + Funnel enabled in admin console. Set `base_url` in guidelines.md accordingly.

## Known Constraints
- ElevenLabs: 10k char/request (auto-split), pronunciation IPA only with flash/turbo/monolingual models
- ffmpeg + yt-dlp must be on `$PATH`; ImageMagick + librsvg for covers (`brew install imagemagick librsvg`)
- All audio forced to mono 44100 Hz
- macOS must be awake for launchd scheduling

## Workflow Notes
- When user mentions screenshots or pics, check ~/Desktop for recent .png files sorted by date
