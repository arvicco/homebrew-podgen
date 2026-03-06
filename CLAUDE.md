# Podcast Agent — Claude Code Instructions

## Overview
Autonomous podcast pipeline. Ruby 3.2+, macOS, ffmpeg, yt-dlp, ImageMagick+librsvg.

**Two pipelines:**
1. **News** (`type: news`): Research topics → Claude script → TTS (ElevenLabs) → multi-language MP3s
2. **Language** (`type: language`): RSS/YouTube/local MP3 → multi-engine STT → Claude reconciliation → auto-trim outro → clean MP3 + transcript

**Standalone tool:**
- **tell**: Interactive TTS pronunciation with auto-translation and grammatical glossing

**APIs:** Claude (topics, scripting, translation, reconciliation, description cleanup, glossing), Exa.ai (research), ElevenLabs (TTS + Scribe), OpenAI/Groq (transcription), DeepL (translation), Google TTS, yt-dlp (YouTube)

## Project Structure
```
bin/podgen                       # CLI entry point
bin/tell                         # TTS pronunciation CLI (standalone)
podcasts/<name>/                 # Per-podcast: guidelines.md, queue.yml, pronunciation.pls, site.css, favicon.*, .env
lib/
  cli.rb                         # CLI dispatcher
  cli/
    generate_command.rb           # Pipeline dispatcher (news or language)
    language_pipeline.rb          # Language pipeline orchestrator
    translate_command.rb          # Backfill translations
    scrap_command.rb              # Remove last episode
    rss_command.rb                # RSS feed generation
    site_command.rb               # Static HTML website generation
    publish_command.rb            # Publish to R2 or LingQ
    list_command.rb | test_command.rb | schedule_command.rb
  time_value.rb                  # TimeValue: seconds or min:sec with absolute? flag
  snip_interval.rb               # SnipInterval: unified skip/cut/snip interval math
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
  site_generator.rb                # Static HTML website generator (ERB templates)
  templates/                       # ERB templates + CSS for site generator
  http_retryable.rb               # Mixin: RetriableError, RETRIABLE_CODES, parse_error, with_http_retries
  tell/
    config.rb                     # Config loader (~/.tell.yml)
    detector.rb                   # Language detection (Unicode scripts + stop words)
    translator.rb                 # Translation engines (DeepL, Claude, OpenAI) + failover chain
    tts.rb                        # TTS engines (ElevenLabs, Google)
    glosser.rb                    # Grammatical glossing via Claude
    hints.rb                      # Style hint parser (/p, /c, /m, /f suffixes)
    colors.rb                     # ANSI colorization for gloss/phonetic output
    error_formatter.rb            # Friendly error messages for API errors
    processor.rb                  # Main processing: detect → translate → synthesize → play
output/<name>/                   # episodes/, tails/, site/, research_cache/, history.yml, feed.xml
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
2. Download + unified trim: skip/cut/snip → SnipInterval → single `atrim+concat` pass (priority: CLI → per-feed → `## Audio`)
3. Transcribe via EngineManager (parallel engines). Groq provides word timestamps. Reconciler (Claude Opus) produces clean text
4. Clean title/description via DescriptionAgent (Claude Haiku) — non-fatal
5. Autotrim outro (opt-in): map reconciled text → Groq timestamps → trim at speech_end + 2s, save tail
6. Assemble: intro + trimmed audio + outro → loudnorm
7. Save transcript, resolve cover, optional LingQ upload (`--lingq`)
8. Record history (with duration + timestamp)

### Key behaviors
- **Multi-podcast:** `podcasts/<name>/` each with own config. `podgen generate <name>`
- **Input sources:** `--file PATH` (local MP3, dedup via `file://name:size`), `--url URL` (YouTube via yt-dlp, auto-thumbnail+captions), RSS (per-feed `skip: N cut: N autotrim: true base_image: PATH image: none`)
- **Flags:** `--title`, `--skip N` (seconds or min:sec), `--cut N` (seconds=relative from end, min:sec=absolute cut point), `--snip INTERVALS` (remove interior segments, CLI-only), `--autotrim`, `--force` (skip dedup), `--image PATH|thumb|last`, `--base-image PATH`, `--lingq`, `--dry-run`
- **TimeValue:** `skip`/`cut` accept plain seconds (`30`) or min:sec (`1:20`). Plain seconds are relative (skip/cut that many seconds); min:sec is absolute (skip to / cut at that timestamp). Implemented via `TimeValue` class (`DelegateClass(Float)` + `absolute?` flag)
- **SnipInterval:** Unified interval math for all trimming. Formats: `1:20-2:30` (range), `1:20+30` (offset), `1:20-end` (open-ended), comma-separated for multiple. Skip/cut/snip fold into removal intervals → merged → inverted to keep segments → single ffmpeg `atrim+concat` pass. `--snip` is CLI-only (per-episode manual operation)
- **Autotrim:** Opt-in via `--autotrim`, per-feed, or `## Audio`. Requires 2+ engines including groq
- **Episode dedup:** News pipeline uses 7-day lookback; language pipeline checks all history (permanent). `--force` to bypass
- **Same-day suffix:** `name-date.mp3`, then `name-date-a.mp3`, etc.
- **Multi-language:** Language list in `## Podcast`. English first, then translations. Per-language voice IDs
- **Cover generation:** Title overlay on base_image via ImageMagick/SVG/rsvg-convert. Priority: `--image` → per-feed → `--base-image` → per-feed base_image → `## Image` → YouTube thumb → nil
- **TTS:** ElevenLabs with chunking (10k char limit), pronunciation dictionaries (`.pls`), trailing hallucination trimming via `/with-timestamps`
- **Transcript post-processing:** Claude Opus. Multi-engine: reconcile + remove hallucinations. Single: clean up. YouTube captions as tiebreaker reference
- **Site:** `podgen site <name>` generates static HTML website in `output/<name>/site/`. Episode list + per-episode pages with transcripts. Multi-language support (subdirectories per language). `--clean` removes existing site first. `--base-url` overrides config. Auto-generated during `publish`
- **Publish:** `podgen publish <name>` → regenerate RSS + site → sync to R2 via rclone. `--lingq` for LingQ instead
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
| `## Site` | `accent`, `accent_dark`, `bg`, `bg_dark`, `radius`, `max_width`, `footer`, `show_duration`, `show_transcript`. Custom `site.css` → `custom.css`. Auto-detect `favicon.*` → copied to site. RSS feed icon after title when `base_url` set |
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

## Tell (TTS Pronunciation Tool)

Standalone CLI (`bin/tell`) for pronouncing text via TTS with auto-translation. Designed for language learning — type a word or phrase in your native language and hear it spoken in the target language.

### Architecture
1. Input: argument (`tell "hello"`), pipe (`echo "hello" | tell`), or interactive REPL
2. Detect language via `Detector` (Unicode script analysis + stop words + characteristic diacritics)
3. If input is in original language → translate to target language via `TranslatorChain`, then speak
4. If input is already in target language → speak directly, fire add-ons (reverse translate, gloss)
5. Synthesize via `ElevenlabsTts` or `GoogleTts`, play via `afplay` (macOS)

### Key behaviors
- **Language detection:** Unicode script ranges (CJK, Hangul, Cyrillic, Arabic, Hebrew, Thai, Devanagari) then Latin stop-word scoring across 20+ languages. Fallback: characteristic diacritics (e.g. č/š/ž → Slovenian)
- **Translation failover:** `TranslatorChain` tries engines in order with per-engine timeout (default 8s, `TELL_TRANSLATE_TIMEOUT`). Engines: DeepL, Claude, OpenAI
- **Explanation detection:** If translation is 3x+ longer than input, it's displayed but not spoken (original is spoken instead)
- **Interactive mode:** Reline-based REPL with persistent history (`~/.tell_history`, 1000 entries), dedup, non-blocking playback (new input interrupts current audio)
- **Add-ons (target-language input only):** reverse translation (`-r`), gloss (`-g`), gloss+translate (`--gr`), phonetic (`-p`) — run in background threads. Combinable: `--gp`, `--grp`, `--rp`
- **Gloss:** Claude produces `word(grammar)` interlinear analysis with agrammatical marking (`*wrong*correction(grammar)`). `--gr` adds translations: `word(grammar)translation`. Multi-model consensus: `gloss_model: [opus, sonnet]` runs models in parallel, reconciler (first model) keeps error markings only when models agree. Single model still works: `gloss_model: opus`
- **Phonetic:** `-p` shows reading (kana for Japanese, pinyin for Chinese, IPA/romanization for others). `--gp` inlines phonetic into gloss: `word[reading](grammar)`. Standalone `-p` always fires alongside combined modes
- **Style hints:** Append `/p`, `/c`, `/m`, `/f` (or combos like `/pm`, `/cf`) to input text. `/p` = polite, `/c` = casual, `/m` = male voice, `/f` = female voice. Stripped before synthesis, passed to translator. Voice switching requires `voice_male`/`voice_female` in config
- **Output:** `afplay` (terminal), file (`-o`), stdout (pipe)

### Configuration: `~/.tell.yml`
```yaml
original_language: en
target_language: sl
voice_id: "elevenlabs_voice_id"
voice_male: "elevenlabs_male_voice_id"    # Optional: voice for /m hint
voice_female: "elevenlabs_female_voice_id"  # Optional: voice for /f hint
tts_engine: elevenlabs              # elevenlabs | google
translation_engine: deepl           # deepl | claude | openai (or array for failover)
# translation_engine:              # failover chain example
#   - deepl
#   - claude
model_id: eleven_multilingual_v2    # ElevenLabs model
output_format: mp3_44100_128        # ElevenLabs output format
reverse_translate: false            # Show reverse translation by default
gloss: false                        # Show grammatical gloss by default
gloss_reverse: false                # Show gloss with translations by default
phonetic: false                      # Show phonetic reading by default
gloss_model: opus                    # opus | sonnet | haiku (or array for multi-model consensus)
# gloss_model:                      # multi-model consensus example
#   - opus
#   - sonnet
phonetic_model: opus                 # opus | sonnet | haiku (default: first gloss_model)
translation_timeout: 8.0            # Per-engine timeout in seconds
```

### Environment variables
`ELEVENLABS_API_KEY`, `GOOGLE_API_KEY`, `DEEPL_AUTH_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `TELL_TRANSLATE_TIMEOUT`, `CLAUDE_MODEL` (for Claude translator), `OPENAI_TRANSLATE_MODEL` (gpt-4o-mini), `TELL_GLOSS_MODEL` (overrides config gloss_model), `TELL_PHONETIC_MODEL` (overrides config phonetic_model)

Loads `.env` from code root + `~/.env`.

### CLI
```
tell [options] [text...]
  -f, --from LANG       Override origin language
  -t, --to LANG         Override target language
  -e, --engine NAME     Override TTS engine (elevenlabs|google)
  -v, --voice ID        Override voice ID
  -o, --output FILE     Save audio to file instead of playing
  -r, --reverse         Show reverse translation for target-language input
  -g, --gloss           Show word-by-word grammatical analysis
  --gr                  Gloss with word translations: word(grammar)translation
  -p, --phonetic        Show phonetic reading (kana/pinyin/romanization)
  --gp                  Gloss with inline phonetic: word[reading](grammar)
  --grp                 Gloss with translations + phonetic
  --rp                  Reverse translate + phonetic reading
  -n, --no-translate    Speak text as-is without translation
  -h, --help            Show help
Style hints: append /p (polite), /c (casual), /m (male voice), /f (female voice) to input
```

## CLI Reference
```
podgen [flags] <command> <args>
  generate <podcast>   # Full pipeline
    --file PATH | --url URL | --title TEXT | --skip N|M:SS | --cut N|M:SS
    --snip INTERVALS | --autotrim | --force | --image PATH|thumb|last | --base-image PATH | --lingq
  translate <podcast>  # Backfill translations (--last N, --lang xx)
  scrap <podcast>      # Remove last episode
  rss <podcast>        # Generate RSS (--base-url URL)
  site <podcast>       # Generate static HTML website (--clean, --base-url URL)
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
