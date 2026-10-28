# Podcast Agent (podgen)

Fully autonomous podcast generation pipeline with two modes, plus a standalone TTS pronunciation tool:

- **News pipeline**: Picks topics, researches them across configurable sources, writes and reviews a script, generates audio via TTS, assembles a final MP3, and translates and voices the episode in every configured language.
- **Language pipeline**: Downloads episodes from RSS feeds, local MP3 files (`--file`), or YouTube videos (`--url`), strips intro/outro music and unwanted segments, transcribes (OpenAI, ElevenLabs Scribe or Groq — several engines can be reconciled), annotates vocabulary, and produces a clean MP3 + transcript with timestamps, subtitles and a video for YouTube.
- **tell**: Interactive TTS pronunciation tool with auto-translation and grammatical glossing for language learning.

Runs on a daily schedule with zero human involvement: launchd jobs generate, publish (Cloudflare R2, LingQ, YouTube) and announce (X) episodes, and `podgen status` reports whether every scheduled show is still producing.

## Prerequisites

- **Ruby 3.4+** (tested with Ruby 4.0)
- **Homebrew** (macOS)
- **System tools** (macOS):
  - Required: `brew install ffmpeg yt-dlp imagemagick librsvg`
  - Optional: `brew install espeak-ng icu4c` (IPA pronunciation, cognate transliteration)
- **API accounts** (news pipeline):
  - [Anthropic](https://console.anthropic.com/) — Claude API for script generation (also powers Claude Web Search source)
  - [Exa.ai](https://exa.ai/) — research/news search (default source)
  - [ElevenLabs](https://elevenlabs.io/) — text-to-speech
- **API accounts** (language pipeline):
  - [OpenAI](https://platform.openai.com/) — Whisper transcription

## Installation

### Via Homebrew (macOS)

```bash
brew tap arvicco/podgen
brew install podgen
```

This installs the `podgen` command and creates a project skeleton at `~/.podgen`. Edit `~/.podgen/.env` to add your API keys.

### From source

```bash
git clone https://github.com/arvicco/homebrew-podgen.git podgen && cd podgen
bundle install
cp .env.example .env
```

Edit `.env` and fill in your API keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...       # See: https://elevenlabs.io/app/voice-library
EXA_API_KEY=...
BLUESKY_HANDLE=...            # Optional: your-handle.bsky.social
BLUESKY_APP_PASSWORD=...      # Optional: https://bsky.app/settings/app-passwords
SOCIALDATA_API_KEY=...        # Optional: https://socialdata.tools
OPENAI_API_KEY=...            # Required for language pipeline (Whisper transcription) and `translator: openai` languages
OPENAI_TRANSLATION_MODEL=gpt-5 # Optional: OpenAI translation model for `translator: openai` languages (default: gpt-5)
WHISPER_MODEL=gpt-4o-mini-transcribe  # Optional: default gpt-4o-mini-transcribe, alt whisper-1
GROQ_API_KEY=...              # Optional: Groq transcription engine (language pipeline)
GROQ_WHISPER_MODEL=whisper-large-v3   # Optional: Groq Whisper model (default: whisper-large-v3)
LINGQ_API_KEY=...             # Optional: LingQ upload (language pipeline)
YOUTUBE_BROWSER=chrome        # Optional: browser for yt-dlp cookie auth (default: chrome)
CLAUDE_OPUS_MODEL=...         # Optional: override the opus line (script, topics, translation, review, transcript reconciliation, Tell gloss)
CLAUDE_SONNET_MODEL=...       # Optional: override the sonnet line (descriptions, vocabulary, subtitle reconciliation, cover ranking, Tell translation)
CLAUDE_HAIKU_MODEL=...        # Optional: override the haiku line (web search source, language detection)
CLAUDE_MODEL=...              # Optional: alias of CLAUDE_OPUS_MODEL (no longer steers Tell translation)
CLAUDE_<ROLE>_MODEL=...       # Optional: per-role override beats the line, e.g. CLAUDE_VOCAB_MODEL, CLAUDE_SCRIPT_MODEL,
                              #   CLAUDE_RECONCILER_MODEL (subtitles), CLAUDE_WEB_MODEL — roles in lib/claude_models.rb
CLAUDE_EFFORT_<ROLE>=low      # Optional: effort level (low|medium|high) for a role, resolved by ClaudeModels.effort(role).
                              #   Default policy: DESCRIPTION and LANGUAGE_DETECT (short outputs) at low; every other role
                              #   omits the parameter (API default). An invalid value warns and omits. Every Claude call site
                              #   passes it through (structured-output calls keep their format beside it).
                              #   Effort assumes the resolved model accepts output_config.effort; with a pinned model that
                              #   rejects it, DescriptionAgent falls back to the original text (or no generated title/description) and WordStats picks the first
                              #   candidate language, with only a non-fatal warning in the log. Set the override to
                              #   `default` (or `none`/`off`) to turn effort off for that role without a warning.
ELEVENLABS_MODEL_ID=eleven_multilingual_v2  # Optional: ElevenLabs TTS model
ELEVENLABS_OUTPUT_FORMAT=mp3_44100_128      # Optional: ElevenLabs output format
ELEVENLABS_SCRIBE_MODEL=scribe_v2           # Optional: ElevenLabs transcription model
```

### Project root resolution

podgen looks for its project directory (`podcasts/`, `.env`, `output/`) in this order:

1. **Current directory** — if CWD contains a `podcasts/` folder
2. **`$PODGEN_HOME`** — if the environment variable is set
3. **`~/.podgen`** — default for Homebrew installs
4. **Code location** — fallback for git clone usage

## Usage

```bash
podgen <command> [options]
```

Or run directly with Ruby:

```bash
ruby bin/podgen <command> [options]
```

### Commands

| Command                               | Description                                              |
| ------------------------------------- | -------------------------------------------------------- |
| `podgen generate <podcast>`           | Run the pipeline (news or language)                      |
| `podgen translate <podcast>`          | Translate existing episodes to new languages             |
| `podgen voice <podcast> [date]`       | Re-voice an episode from saved script JSON (recover from TTS failure) |
| `podgen render <podcast> [date]`      | Re-render script markdown from saved JSON (after `## Links` change) |
| `podgen scrap <podcast> [date]`       | Remove episode + history entry (default: latest)         |
| `podgen move <podcast> <from> <to>`   | Rename episode artifacts to a different date (`<from>+` = whole day) |
| `podgen exclude <podcast> <url>...`   | Skip URLs in future research and RSS episode collection  |
| `podgen rss <podcast>`                | Generate RSS feed from existing episodes                 |
| `podgen site <podcast>`               | Generate static HTML website                             |
| `podgen publish <podcast>`            | Publish to Cloudflare R2, LingQ, or YouTube              |
| `podgen unpublish <podcast>`          | Remove podcast from R2 or delete YouTube videos          |
| `podgen tweet <podcast> <episode>`    | Tweet about a specific episode                           |
| `podgen stats <podcast>`              | Show podcast statistics and download analytics           |
| `podgen analytics <sub>`              | Manage Cloudflare analytics Worker                       |
| `podgen validate <podcast>`           | Validate config and output                               |
| `podgen status [podcast]`             | One-line OK/OLD/WARN verdict per podcast (exit 1 if any OLD/WARN) |
| `podgen list`                         | List available podcasts                                  |
| `podgen add <podcast> <url>`          | Queue a priority link for the next episode               |
| `podgen links <podcast>`              | List or manage queued priority links                     |
| `podgen vocab <sub> <podcast>`        | Known vocabulary (`add`/`remove`/`list`/`review`) and cached glosses (`edit`) |
| `podgen revocab <podcast> [episode]`  | Re-annotate vocabulary on transcripts                    |
| `podgen reformat <podcast> [episode]` | Reformat transcripts (paragraph breaks, cleanup)         |
| `podgen cover <podcast> [date]`       | Generate episode cover images (use --title, --image flags) |
| `podgen regen <podcast> [date]`       | Regenerate .mp4 / .srt / reconciled timestamps for an existing episode |
| `podgen fork <old> <new>`             | Fork podcast into a new namespace                        |
| `podgen test <name>`                  | Run a component test (research, hn, rss, tts, etc.)      |
| `podgen schedule <podcast>`           | Install, remove, or inspect a daily launchd scheduler    |
| `podgen uploads <pods>`               | Per-pod regen + R2 + LingQ, then a YouTube batch across pods (`--mode`, `--max`) |
| `podgen init <podcast>`               | Initialize a new podcast (skeleton or from existing) |

Per-command flags are documented in the dedicated sections below (e.g. [Generate command](#generate-command-options), [Publish command](#publishing-to-cloudflare-r2)).


### Selecting an episode

`voice`, `render`, `translate`, `scrap`, and `cover` accept an episode date either as `--date` or as a trailing positional argument — the two forms are interchangeable. Recognized date shapes (all with an optional lowercase suffix `[a-z]` for multi-episode days):

| Form         | Example       | Resolves to                          |
| ------------ | ------------- | ------------------------------------ |
| `YYYY-MM-DD` | `2026-03-31`  | as-is                                |
| `YYYYMMDD`   | `20260331`    | as-is                                |
| `MM-DD`      | `03-31`       | current year                         |
| `MMDD`       | `0331`        | current year                         |
| `DD` / `D`   | `31`, `5`     | current year + current month         |

```bash
podgen voice fulgur_news 2026-04-26          # positional, full ISO
podgen voice fulgur_news --date 2026-04-26   # equivalent
podgen render fulgur_news 0426               # short — current year
podgen scrap fulgur_news 26b                 # short — current year/month, suffix "b"
```

`voice`, `render`, `translate`, and `regen` also accept `--last N` (most recent N episodes), which is mutually exclusive with a date.


### Global flags

| Flag            | Description                                                              |
| --------------- | ------------------------------------------------------------------------ |
| `-v, --verbose` | Verbose output                                                           |
| `-q, --quiet`   | Suppress terminal output (errors still shown, full detail in log file)   |
| `--dry-run`     | Validate config and skip API calls + file output                         |
| `--lingq`       | Enable LingQ upload (generate) or publish to LingQ (publish)             |
| `-V, --version` | Print version                                                            |
| `-h, --help`    | Show help                                                                |


### Examples

```bash
# Generate an episode
podgen generate ruby_world

# Dry run — validate config, no API calls
podgen --dry-run generate ruby_world

# Generate silently (for cron/launchd)
podgen --quiet generate ruby_world

# Move an episode to a different date — renames all artifacts (mp3, mp4,
# srt, scripts, transcripts, timestamps, covers, language variants) and
# updates history.yml + uploads.yml. RSS is regenerated; YouTube/LingQ
# remote URLs keep their original titles (re-publish if needed).
podgen move bajke 2026-05-16 2026-05-18                  # bare → bare (auto-suffix on collision)
podgen move bajke 2026-05-16d 2026-05-18                 # specific suffix → bare on 18th
podgen move bajke 2026-05-16d 2026-05-18c                # explicit target suffix (errors if taken)

# Whole-day form: '+' moves every episode on that day, suffixes preserved.
# Strict — any artifact at the target date is a conflict (no auto-shift).
podgen move bajke '2026-05-16+' 2026-05-18

# Scrap last episode (delete files + remove from history)
podgen scrap ruby_world

# Scrap a specific episode by date (with optional suffix for multi-episode days)
podgen scrap ruby_world 2026-03-15b

# Scrap by file path — podcast and episode are detected automatically
podgen scrap output/lahko_noc/episodes/lahko_noc-2026-02-23_transcript.md

# Scrap and also add the source URL to the excluded list (language pipeline)
podgen scrap lahko_noc 2026-04-07 --exclude

# Preview what scrap would remove (no changes)
podgen --dry-run scrap ruby_world

# Exclude URLs from future episodes (news research + language RSS collection)
podgen exclude ruby_world https://example.com/already-covered
podgen exclude lahko_noc https://feed.example.com/ep1 https://feed.example.com/ep2

# Interactively pick RSS episodes to exclude (language pipeline)
podgen exclude lahko_noc --rss rtvslo --ask      # next 5 from feed matching "rtvslo"
podgen exclude lahko_noc --rss rtvslo --ask 10   # next 10 from that feed

# List all configured podcasts
podgen list

# Generate RSS feed
podgen rss ruby_world

# Generate static HTML website
podgen site ruby_world

# Regenerate site from scratch
podgen site ruby_world --clean

# Publish to Cloudflare R2 (auto-regenerates RSS + site)
podgen publish ruby_world

# Dry-run publish (see what would sync)
podgen --dry-run publish ruby_world

# Process a local MP3 through the language pipeline
podgen generate lahko_noc --file ~/Downloads/story.mp3

# Local MP3 with custom title and intro trimming (seconds or min:sec)
podgen generate lahko_noc --file story.mp3 --title "The Three Bears" --skip 1:20

# Local MP3 with custom cover image for LingQ (persisted with episode)
podgen generate lahko_noc --file story.mp3 --lingq --image cover.png

# Local MP3 with title-overlay cover generation
podgen generate lahko_noc --file story.mp3 --lingq --base-image cover.jpg

# Process a YouTube video through the language pipeline
podgen generate lahko_noc --url "https://youtube.com/watch?v=abc123"

# YouTube video with custom title and LingQ upload
podgen generate lahko_noc --url "https://youtube.com/watch?v=abc123" --title "The Fox" --lingq

# Publish episodes to LingQ (bulk upload with tracking)
podgen publish lahko_noc --lingq

# Preview what would be uploaded to LingQ
podgen publish lahko_noc --lingq --dry-run

# Publish to every configured target (R2 + LingQ + YouTube) in one shot.
# Unconfigured targets are skipped silently with a one-line note; failures
# in one target don't halt the others. Exit code is the worst per-target code.
podgen publish lahko_noc --all
podgen publish lahko_noc 2026-05-30 --all --force        # specific episode, force re-upload everywhere

# Run a component test
podgen test hn
```

### Generate command options

`podgen generate <podcast>` accepts the following flags. Some apply to both pipelines, others are pipeline-specific.

| Flag                | Description                                                                  |
| ------------------- | ---------------------------------------------------------------------------- |
| `--date YYYY-MM-DD` | Episode date (default: today). Useful for backfilling missed days            |
| `--dry-run`         | Validate config and skip API calls + file output                             |
| `--lingq`           | Upload to LingQ after generation (language pipeline)                         |
| `--youtube`         | Upload to YouTube after generation (language pipeline)                       |
| `--force`           | Process even if the episode is already in history                            |

News pipeline only:

| Flag             | Description                                                                              |
| ---------------- | ---------------------------------------------------------------------------------------- |
| `--from-script`  | DEPRECATED: prefer `podgen voice <pod> [--lang LANG]`. Skip topics/research/script/review; re-voice from saved JSON. |

**Recovering from a partial pipeline failure** (e.g. TTS fails for one language after the script is already generated): prefer the per-stage commands. Each stage reads the previous stage's persisted artifact and is idempotent, so failures don't lose work or tokens. The canonical artifact is the JSON sibling of `<basename>[_<lang>]_script.md`; for older episodes that pre-date the JSON, the markdown is parsed back (inline source links recovered from bullet lists; bottom-mode "More info" sections recovered as script-level sources).

```bash
# Just retry the failed Japanese voicing — script + translation already on disk
podgen voice fulgur_news --lang jp

# Re-voice everything for a specific date (e.g. after switching voice_id)
podgen voice fulgur_news 2026-04-26 --force

# Re-render markdown views after changing ## Links config (free, no API calls)
podgen render fulgur_news 0426
```

`--from-script` still works for backwards compatibility (it now reads the canonical JSON when present), but emits a deprecation notice pointing at `podgen voice`.

Language pipeline only:

| Flag                | Description                                                                  |
| ------------------- | ---------------------------------------------------------------------------- |
| `--file PATH`       | Local MP3 to process (skips RSS fetch)                                       |
| `--url URL`         | YouTube video URL (downloads via yt-dlp; mutually exclusive with `--file`)   |
| `--rss FILTER`      | Pick a specific RSS feed by URL substring (when multiple feeds configured)   |
| `--title TEXT`      | Override episode title (default: feed/file/YouTube title)                    |
| `--skip N`          | Seconds or `min:sec` to skip from start (`--skip-intro` is an alias)         |
| `--cut N`           | Seconds (relative) or `min:sec` (absolute) to cut from end                   |
| `--snip INTERVALS`  | Remove interior segments — see [Snip format](#snip-format)                   |
| `--ask-trim`        | Opens a QuickTime preview (frontmost, auto-playing — scrub to find boundaries) and prompts for skip/cut; `x` to exclude. Preview closes when the prompts finish |
| `--autotrim`        | Enable outro auto-detection from word timestamps                             |
| `--no-skip`         | Disable skip even when configured                                            |
| `--no-cut`          | Disable cut even when configured                                             |
| `--no-autotrim`     | Disable autotrim even when configured                                        |
| `--image PATH`      | Cover: file path, `thumb` (YouTube), `last` (latest ~/Desktop screenshot), or `auto` (web search ranked by Claude vision) |
| `--base-image PATH` | Base image for title-overlay cover generation                                |
| `--include WORDS`   | Force-include these vocabulary lemmas (comma-separated) in the annotation   |

`--skip-intro`, `--cut-outro` and `--ask-skip` are aliases of `--skip`, `--cut` and `--ask-trim`. `--skip`/`--cut`/`--autotrim` override per-feed and `## Audio` config. The `--no-*` variants force-disable a setting that would otherwise apply.

## First Run

```bash
podgen generate <podcast_name>
```

### News pipeline (default)

1. Topics — Claude turns the guidelines (and `queue.yml` fallbacks) into today's topics, each with a short keyword query for Hacker News
2. Research — every enabled source runs per topic (Exa, Hacker News, RSS, Claude web search, Bluesky, X); results are merged, deduplicated and cached for 24 h; a topic with no findings is dropped with a warning, and when no topic has any the run fails before a script is written; queued priority links are added
3. Script — Claude writes the episode from the research, following `## Format`, `## Tone` and `## Links`
4. Review — deterministic checks plus an AI review against the research (see [Script review](#script-review)); blockers send the script back for a rewrite, warnings are logged and kept
5. Voice — ElevenLabs TTS per segment, with the pronunciation dictionary applied
6. Assemble — intro/outro jingles, loudness normalization, 192 kbps MP3 with ID3 title/artist
7. Per extra language: translate the reviewed script (Claude or OpenAI), then voice and assemble again with that language's voice

Measured on a four-language episode (2026-10-12): the English MP3 is ready about 8 minutes after the start (two review rounds), each additional language takes 5–6 minutes more.

Output: `output/<podcast>/episodes/<name>-YYYY-MM-DD.mp3` (10–15 min, ~20 MB at 192 kbps) plus `<name>-YYYY-MM-DD_script.json` / `.md`, and `-<lang>` siblings per language

### Language pipeline

1. Fetch the latest episode from configured RSS feeds, a local MP3 (`--file`), or a YouTube video (`--url`); episodes already in history, excluded URLs and episodes outside `min_length`/`max_length` are skipped
2. Download and strip intro/outro/interior segments via unified trimming (outro auto-detection requires `--autotrim`; `--ask-trim` previews the audio and prompts)
3. Transcribe with the configured engines (`open` = OpenAI, `elab` = ElevenLabs Scribe, `groq` = Groq Whisper); with several engines Claude reconciles them into one transcript, with YouTube captions as a tiebreaker when available
4. Clean the episode title and description (or generate a description from the transcript for local files) via Claude (sonnet line)
5. Assemble with custom intro/outro jingles + loudness normalization
6. Annotate vocabulary (`## Vocabulary`), write word timestamps and `.srt` subtitles, render the `.mp4` for YouTube, and resolve the episode cover
7. Optionally upload to LingQ (`--lingq`) and YouTube (`--youtube`)

Output: `output/<podcast>/episodes/<name>-YYYY-MM-DD.mp3` + `<name>-YYYY-MM-DD_transcript.md`, `_timestamps.json`, `.srt`, `.mp4` and the cover

## Creating a Podcast

1. Create a directory under `podcasts/`:

```bash
mkdir -p podcasts/my_podcast
```

2. Add `podcasts/my_podcast/guidelines.md` with your format, tone, and topic preferences (see `podcasts/ruby_world/guidelines.md` for an example).
3. Add `podcasts/my_podcast/queue.yml` with fallback topics:

```yaml
topics:
  - AI developer tools and agent frameworks
  - Ruby on Rails ecosystem updates
```

4. Optionally add per-podcast voice/model overrides in `podcasts/my_podcast/.env`.

## Customizing

### Podcast Guidelines

Edit `podcasts/<name>/guidelines.md` to change format, tone, length, and content rules. The script agent follows these strictly. HTML comments (`<!-- ... -->`) are stripped before parsing, so you can use them to temporarily disable config entries (e.g. languages, sources).

All config sections follow the same list rules: items are `- key: value` lines (indentation and extra spaces after `-` are fine); a trailing ` # note` is stripped; a Markdown autolink `[url](url)` is unwrapped to the bare url; a repeated key keeps the last value (the `language` and engine lists keep every entry); a bare `- key` with no value, or a nested `  - item` under an entry that takes none, is ignored and reported by `podgen validate`.

### Topics

Edit `podcasts/<name>/queue.yml`:

```yaml
topics:
  - AI developer tools and agent frameworks
  - Ruby on Rails ecosystem updates
  - Interesting open source releases this week
```

### Voice & Model

Configure in `.env`:

```
ELEVENLABS_MODEL_ID=eleven_multilingual_v2    # Default TTS model (long-form stable)
ELEVENLABS_VOICE_ID=cjVigY5qzO86Huf0OWal     # Eric - Smooth, Trustworthy
CLAUDE_OPUS_MODEL=                             # Opus-line override (script generation etc.); defaults in lib/claude_models.rb
```

Per-podcast override of the TTS model goes in `## Audio`:

```markdown
## Audio
- tts_model: eleven_v3        # opt in to ElevenLabs v3 for this podcast
```

Precedence: per-podcast `tts_model` → `ELEVENLABS_MODEL_ID` env → `eleven_multilingual_v2` default. Per-model character limits (used for chunking) are tracked in `TTSAgent::MODEL_MAX_CHARS` (`eleven_v3` → 4500, others → 9500).

### Intro/Outro Music

Drop MP3 files into each podcast's directory:

- `podcasts/<name>/intro.mp3` — played before the first segment (3s fade-out)
- `podcasts/<name>/outro.mp3` — played after the last segment (2s fade-in)

Both are optional per podcast. The pipeline skips them if the files don't exist.

### Pronunciation Dictionary

If ElevenLabs mispronounces certain terms (acronyms, proper nouns, technical jargon), you can add a pronunciation dictionary to correct them.

Create `podcasts/<name>/pronunciation.pls` with alias rules:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<lexicon version="1.0"
    xmlns="http://www.w3.org/2005/01/pronunciation-lexicon"
    alphabet="ipa" xml:lang="en-US">

  <lexeme>
    <grapheme>UTXO</grapheme>
    <alias>you tee ex oh</alias>
  </lexeme>

  <lexeme>
    <grapheme>sats</grapheme>
    <alias>sahts</alias>
  </lexeme>

</lexicon>
```

- The dictionary is automatically uploaded to ElevenLabs on the first TTS run
- Changes are detected via SHA256 and re-uploaded automatically
- **Alias rules** (recommended): replace the written word with a phonetic respelling — works with all ElevenLabs models
- **IPA phoneme rules**: specify exact pronunciation via IPA symbols — only works with `eleven_flash_v2`/`eleven_turbo_v2`/`eleven_monolingual_v1`
- Case-sensitive: `Bitcoin` and `bitcoin` are separate entries
- See `docs/pronunciation.md` for the full PLS format guide, IPA reference, and tips

### Research Sources

Research is modular — each podcast can enable different sources via a `## Sources` section in its `guidelines.md`. If the section is omitted, only Exa.ai is used (backward compatible).

Available sources:

| Source      | Key          | API needed                  | Cost/run     | Description                  |
| ----------- | ------------ | --------------------------- | ------------ | ---------------------------- |
| Exa.ai      | `exa`        | EXA_API_KEY                 | ~$0.03       | AI search (default category) |
| Hacker News | `hackernews` | None                        | $0           | HN Algolia by topic keywords |
| RSS feeds   | `rss`        | None                        | $0           | Any RSS/Atom feed            |
| Claude Web  | `claude_web` | ANTHROPIC_API_KEY           | ~$0.02/topic | Claude `web_search` (Haiku)  |
| Bluesky     | `bluesky`    | BLUESKY_HANDLE + APP_PASSWD | $0           | AT Protocol post search      |
| X (Twitter) | `x`          | SOCIALDATA_API_KEY          | ~$0.01       | Twitter via SocialData.tools |

The Exa default category is `news`; override with `- exa: research` in the `## Sources` section.

Hacker News is searched with a 2–4 word keyword query that the topic step emits for each topic (Algolia requires every term to match, so the full topic sentence never would); a topic without a keyword query is skipped rather than searched. The run log shows each query.


Add the section to `podcasts/<name>/guidelines.md`:

```markdown
## Sources
- exa
- hackernews
- bluesky
- x: @dhaboruby, @rails, @maboroshi_llm
- rss:
  - https://www.coindesk.com/arc/outboundfeeds/rss/
  - https://cointelegraph.com/rss
- claude_web
```

- Plain items (`- exa`) use defaults; items with values (`- exa: research`) pass configuration (e.g. Exa search category — default `news`)
- Items with sub-lists (`- rss:` with feed URLs) or inline values (`- x: @user1, @user2`) carry parameters
- `- x` (no handles) does general search only; `- x: @handle, ...` searches those accounts first, then fills with general results
- Sources not listed are disabled
- Results from all sources are merged and deduplicated before script generation

### Multi-Language Episodes

Podgen can produce the same episode in multiple languages. The English script is generated first, then translated via Claude and synthesized with a per-language ElevenLabs voice.

Add a `language` list to the `## Podcast` section in `podcasts/<name>/guidelines.md`:

```markdown
## Podcast
- name: Ruby World
- language:
  - en
  - it: CITWdMEsnRduEUkNWXQv
  - ja: rrBxvYLJSqEU0KHpFpRp translator: openai translation_model: gpt-5
```

- Each sub-item is a 2-letter language code (ISO 639-1)
- Optionally append `: <voice_id>` to use a different ElevenLabs voice for that language
- After the voice_id, append space-separated inline options:
  - `translator: openai` — translate via the OpenAI API instead of Claude (recommended for Japanese; requires `OPENAI_API_KEY`). Default `claude`.
  - `translation_model: <model>` — override the translation model for that language (e.g. `gpt-5`, `claude-haiku-4-5-20251001`). Default: `OPENAI_TRANSLATION_MODEL` env var (default `gpt-5`) for `openai`; the translation role of the model registry for `claude` (`CLAUDE_TRANSLATION_MODEL`, else the opus line).
- If `language` is omitted, only English (`en`) is produced
- English is never re-translated — the original script is used directly
- Output files are suffixed by language: `ruby_world-2026-02-19.mp3` (English), `ruby_world-2026-02-19-it.mp3` (Italian), etc.
- A single-language podcast can write it inline: `- language: es` under `## Podcast` (the `language:` under `## Audio` is only the transcription language)
- The first `language` entry is the primary: its episodes carry no suffix and its feed is always `output/<podcast>/feed.xml`, with that code in the feed's `<language>`
- Each extra language gets its own feed and site: `output/<podcast>/feed-<code>.xml` and `output/<podcast>/site/<code>/`, published alongside the primary ones
- Translated episodes report their own duration in the language feeds and on the site (recorded in history.yml when voiced); the English duration is used only when none was recorded
- Removing a code from `language` does not remove its files: move or scrap the leftover `-<code>` episodes first (`translate`, `voice` and `render` still treat a leftover file as a variant while its English episode exists, but the feed and site would list it as an English episode)

Supported languages (matching ElevenLabs `eleven_multilingual_v2`): Arabic, Chinese, Czech, Danish, Dutch, Finnish, French, German, Greek, Hebrew, Hindi, Hungarian, Indonesian, Italian, Japanese, Korean, Malay, Norwegian, Polish, Portuguese, Romanian, Russian, Spanish, Swedish, Thai, Turkish, Ukrainian, Vietnamese.

#### Translation Glossary (per-language term overrides)

By default the translator follows natural conventions of the target language for brand names and loanwords (Latin-script languages keep most brand names verbatim; non-Latin scripts apply standard transliteration — e.g. ビットコイン in Japanese). Add a `## Translation Glossary` section to pin specific term translations per language:

```markdown
## Translation Glossary
- jp:
  - Bitcoin: ビットコイン
  - GitHub: GitHub
  - mining: マイニング
  - sovereign wealth fund: 政府系ファンド
- es:
  - mining: minería
  - covered call: covered call
```

Each top-level item is a 2-letter language code (matching `## Podcast → language:`). Nested items are `term: translation` pairs. Only the active target language's pairs are injected into the translation prompt. Terms not listed fall back to the natural-conventions rule.

### Language Learning Pipeline

For podcasts that repackage existing audio content (e.g. children's stories in a target language), use the language pipeline. It downloads episodes from RSS, strips music, transcribes, and produces a clean MP3 + transcript.

Set `type: language` in `## Podcast` and configure `## Audio` in `podcasts/<name>/guidelines.md`:

```markdown
## Podcast
- name: Lahko noč
- type: language

## Sources
- rss:
  - https://podcast.rtvslo.si/lahko_noc_otroci

## Audio
- engine:
  - open
- language: sl
- target_language: Slovenian
```

- `type: language` in `## Podcast` activates this pipeline
- `language` in `## Audio` is an ISO-639-1 code passed to the transcription engine
- `engine` in `## Audio` selects transcription engines (`open`, `elab`, `groq`); multiple = comparison mode
- RSS feeds support per-feed `skip:` and `cut:` options in seconds or min:sec format (see below)
- RSS sources must include feeds with audio enclosures

#### Per-feed audio trimming

RSS feeds can specify `skip:` and `cut:` inline, in seconds or min:sec format:

```markdown
## Sources
- rss:
  - https://podcast.example.com/feed skip: 38 cut: 10
  - https://other.example.com/feed skip: 1:20 cut: 11:20
```

Both `skip` and `cut` accept plain seconds (`38`) or min:sec (`1:20`). For `cut`, the format determines behavior:

- **Plain seconds** (e.g. `cut: 10`): removes that many seconds from the end (relative)
- **min:sec** (e.g. `cut: 11:20`): cuts at that timestamp, keeping audio up to 11m20s (absolute)

For `skip`, both formats mean "start playback from this point" — `skip: 80` and `skip: 1:20` are equivalent.

CLI flags `--skip N` / `--cut N` override per-feed values. `skip`/`cut` in `## Audio` is used as a fallback if neither CLI flag nor per-feed config is set.

#### Episode length filtering

Set `min_length` / `max_length` in `## Sources` to filter out episodes outside the desired duration range:

```markdown
## Sources
- min_length: 2:00
- max_length: 9:30
- rss:
  - https://podcast.example.com/feed
```

Accepts the same formats as RSS `itunes_duration`: plain seconds (`120`), `MM:SS`, or `HH:MM:SS`. Applied in two stages:

1. **Pre-download**: episodes whose `itunes_duration` falls outside `[min_length, max_length]` are dropped before download. A summary line logs how many were kept and why others were filtered (`Length filter [2:00–9:30]: 59/60 kept, 1 too long`).
2. **Post-download**: the actual audio duration is probed (covers feeds without reliable `itunes_duration`). If outside range:
   - With `--ask-trim`: prompt `[t]rim manually / e[x]clude / [a]bort?` — `x` writes the URL to `excluded_urls.yml` so future runs skip it.
   - Without `--ask-trim`: log warning and abort with exit 1.

Episodes with missing or unparseable `itunes_duration` pass the pre-download filter and are validated post-download.

#### Interactive trimming

`--ask-trim` downloads the audio, opens a QuickTime preview (frontmost, auto-playing — scrub to locate the boundaries, read the min:sec position), and prompts for skip and cut values while the preview plays. The preview closes automatically when the prompts finish. Mutually exclusive with `--skip`/`--no-skip`/`--cut`/`--no-cut`.

```bash
podgen generate lahko_noc --ask-trim
podgen generate lahko_noc --file story.mp3 --ask-trim
```

At either prompt, type `x` to exclude the episode — this adds its source URL to the excluded list and stops processing (same as `podgen exclude`). Useful when you hear during preview that an episode isn't worth processing.

#### Snip format

The `--snip` flag removes arbitrary interior segments from the audio. All timestamps reference the original audio file (before skip/cut). Multiple intervals are comma-separated.


| Format          | Example                    | Meaning                      |
| --------------- | -------------------------- | ---------------------------- |
| Range (seconds) | `--snip 20-30`             | Remove seconds 20 through 30 |
| Range (min:sec) | `--snip 1:20-2:30`         | Remove from 1m20s to 2m30s   |
| Offset          | `--snip 1:20+30`           | Remove 30s starting at 1m20s |
| Open-ended      | `--snip 1:20-end`          | Remove from 1m20s to the end |
| Multiple        | `--snip 1:20-2:30,3:40+33` | Remove two segments          |


Skip, cut, and snip are unified into a single trimming pass: all removal intervals are merged and the audio is processed in one ffmpeg operation.

`--snip` is CLI-only (not available in per-feed config or `## Audio`) since interior snipping is a per-episode manual operation.

```bash
# Remove an ad break from 1:20 to 2:30
podgen generate lahko_noc --file story.mp3 --snip 1:20-2:30

# Remove two segments
podgen generate lahko_noc --file story.mp3 --snip 1:20-2:30,5:00+45

# Combine with skip and cut
podgen generate lahko_noc --file story.mp3 --skip 30 --cut 10 --snip 3:00-3:30
```

#### Outro auto-detection (autotrim)

Outro music auto-detection trims trailing music/silence by mapping reconciled transcript text back to Groq word-level timestamps. This feature is opt-in — enable it in any of three ways (same priority chain as `skip`/`cut`):

1. **CLI flag**: `--autotrim`
2. **Per-feed config**: `autotrim: true` inline with the RSS URL
3. **`## Audio` section**: `- autotrim: true`

```markdown
## Sources
- rss:
  - https://podcast.example.com/feed skip: 38 autotrim: true

## Audio
- engine:
  - open
  - groq
- autotrim: true
```

Requires 2+ transcription engines with `groq` included. Without `autotrim`, no outro detection runs even when engines support it.

#### Local file import

Instead of fetching from RSS, you can process any local MP3 file:

```bash
podgen generate lahko_noc --file path/to/episode.mp3
podgen generate lahko_noc --file episode.mp3 --title "Custom Title"
```


See [Generate command options](#generate-command-options) for the full flag reference. With `--file`, the default title is the titleized filename (e.g. `my_story.mp3` → "My Story").

The rest of the pipeline (transcription, outro trimming, assembly, LingQ upload) works identically. The file's name and size are recorded in history for dedup (survives file moves). Re-running the same `--file` command exits with a warning if already processed; use `--force` to re-process.

#### YouTube video import

Process any YouTube video through the language pipeline:

```bash
podgen generate lahko_noc --url "https://youtube.com/watch?v=abc123"
podgen generate lahko_noc --url "https://youtube.com/watch?v=abc123" --title "Custom Title" --lingq
```


See [Generate command options](#generate-command-options) for the full flag reference. With `--url`, `--image thumb` is the additional value that uses the YouTube auto-thumbnail.

The video thumbnail is always downloaded as a fallback. When `base_image` is configured (via `## Image` section, per-feed, or `--base-image`), title-overlay generation runs instead of using the raw thumbnail. Use `--image thumb` to explicitly prefer the YouTube thumbnail over generation, or `--image PATH` for a custom static image. YouTube auto-captions in the target language are automatically fetched (when available) and passed to the transcription reconciler as an additional reference source. The captions are treated as lower quality and used only as a tiebreaker when STT engines disagree. Requires `yt-dlp` on `$PATH` (`brew install yt-dlp`). Authentication uses browser cookies via `--cookies-from-browser` (default: Chrome, override with `YOUTUBE_BROWSER` env var). The canonical YouTube URL is recorded in history for dedup. Re-running the same `--url` command exits with a warning if already processed; use `--force` to re-process.

- Place `intro.mp3` and `outro.mp3` in the podcast directory for custom jingles
- Music detection uses bandpass filtering (300-3000 Hz) for intros and silence detection for outros
- Default transcription model is `gpt-4o-mini-transcribe` (set `WHISPER_MODEL=whisper-1` for timestamps/segments)

### LingQ Upload

Upload language pipeline episodes to [LingQ](https://www.lingq.com/) as lessons. Add a `## LingQ` section to your guidelines.md and set `LINGQ_API_KEY` in your `.env`.

Two ways to upload:

1. **During generation**: `podgen generate lahko_noc --lingq` — uploads the newly generated episode
2. **Bulk publish**: `podgen publish lahko_noc --lingq` — uploads all un-uploaded episodes from the episodes directory

Both modes track uploads in `output/<podcast>/uploads.yml` (keyed by platform and collection/playlist ID), so running publish after generate skips already-uploaded episodes. Switching `collection` in your config uploads to the new collection without losing previous tracking.

Per-episode covers provided via `--image` are saved as `{base_name}_cover.{ext}` in the episodes directory. The publish command uses these per-episode covers when available, falling back to cover generation for episodes without one.

### YouTube Publishing

Publish episodes to YouTube as videos with synchronized subtitles.

**Setup:**
1. Create a Google Cloud project and enable the YouTube Data API v3
2. Create OAuth2 credentials (Desktop app type)
3. Set `YOUTUBE_CLIENT_ID` and `YOUTUBE_CLIENT_SECRET` in `.env`
4. Add a `## YouTube` section to `guidelines.md`:

```markdown
## YouTube
- playlist: PLxxxxxxxxx
- privacy: unlisted
- category: 27
- tags: podcast, slovenian, language learning
```

**Usage:**

```bash
# During generation — upload the newly generated episode
podgen generate lahko_noc --youtube

# Bulk publish — upload all un-uploaded episodes (oldest first)
podgen publish lahko_noc --youtube

# Newest first — prioritize recent episodes when quota is limited
podgen publish lahko_noc --youtube --newest

# Single episode
podgen publish lahko_noc 2026-03-28 --youtube

# Re-upload (bypass tracking)
podgen publish lahko_noc 2026-03-28 --youtube --force

# Combine with LingQ
podgen publish lahko_noc --youtube --lingq
```

Old episodes without timestamps are automatically retranscribed (single-engine, best available) to generate subtitles. The YouTube daily quota allows ~5 video uploads; the batch stops on quota exhaustion and resumes where it left off on the next run.

**Authorization.** The token lives in `~/.config/podgen/youtube_token.json` and is shared by every podcast. When it is missing or can no longer be refreshed, the next upload opens the Google consent page in your browser and listens on a local port for the redirect. That happens only from a terminal: a scheduled run (launchd, cron, a redirected log) has nobody to click, so it refuses with one log line naming the token file, its size and date, at the first API call. The batch upload command then ends its YouTube phase for the remaining podcasts and exits non-zero, `podgen publish --youtube` exits non-zero, and `generate --youtube` logs the refusal as a warning and finishes the episode without the upload. Authorize once with `podgen publish <podcast> --youtube` from a terminal; the scheduled runs pick the token up from there.

Each episode produces:
- `{basename}_timestamps.json` — segment-level timestamps from transcription
- `{basename}.srt` — SRT subtitles synchronized with the audio
- `{basename}.mp4` — video (cover image + audio, 1920x1080)

Subtitles are uploaded as captions in the episode's language. Upload tracking is shared with LingQ in `uploads.yml`.

To remove all tracked YouTube videos for a podcast:

```bash
podgen unpublish lahko_noc --youtube           # delete all tracked videos
podgen --dry-run unpublish lahko_noc --youtube # preview deletions
```

Without `--youtube`, `podgen unpublish` purges the podcast's R2 bucket prefix instead.

### Cover Image Configuration

Cover and title-overlay generation settings are configured in a dedicated `## Image` section in `guidelines.md`:

```markdown
## Image
- cover: cover.jpg
- base_image: base_cover.jpg
- font: Noto Sans
- font_color: white
- font_size: 72
- text_width: 900
- text_gravity: south
- text_x_offset: 0
- text_y_offset: 50
- auto_cover_min_bytes: 20000        # filter tiny placeholders
- auto_cover_min_score: 14           # 2-20, threshold for declaring a winner
- auto_cover_candidates: 5           # how many to fetch and rank per episode
- auto_cover_model: claude-sonnet-4-6
```


| Key                     | Description                                                              |
| ----------------------- | ------------------------------------------------------------------------ |
| `cover`                 | Podcast cover artwork filename in `podcasts/<name>/` (see note below)    |
| `base_image`            | Base image for per-episode title-overlay generation                      |
| `font`                  | Font family for title text                                               |
| `font_color`            | Font color                                                               |
| `font_size`             | Font size in points                                                      |
| `text_width`            | Max text width in pixels                                                 |
| `text_gravity`          | ImageMagick gravity (e.g. `south`, `center`)                             |
| `text_x_offset`         | Horizontal offset in pixels                                              |
| `text_y_offset`         | Vertical offset in pixels                                                |
| `auto_cover_min_bytes`  | `--image auto`: minimum download size to keep (filters placeholders)     |
| `auto_cover_min_score`  | `--image auto`: combined score threshold (2–20) to declare a winner      |
| `auto_cover_candidates` | `--image auto`: how many candidates to fetch from search                 |
| `auto_cover_model`      | `--image auto`: Claude vision model used for ranking                     |

`cover` is copied to output by `podgen rss` and replaces the legacy `image` key in `## Podcast`.


**Per-episode cover priority chain:**

1. `--image PATH` — explicit static file override (also `last` for latest ~/Desktop screenshot)
2. `--image thumb` — explicitly use YouTube auto-thumbnail (YouTube only; error for non-YouTube)
3. Per-feed `image: none` — disables cover generation for this feed
4. `--base-image PATH` — CLI override for title-overlay generation base
5. Per-feed `base_image: path` in `## Sources`
6. `## Image` section `base_image: path` → title-overlay generation
7. YouTube thumbnail (auto-downloaded fallback, only for YouTube sources)
8. `nil` — no cover

Per-feed image overrides go inline with RSS URLs:

```markdown
## Sources
- rss:
  - https://podcast.example.com/feed base_image: special_cover.jpg
  - https://other.example.com/feed image: none
  - https://classics.example.com/feed image: auto      # search the web, rank with Claude vision
```

`image: auto` triggers `AutoCoverResolver` for each *new* episode pulled from that feed (existing committed episodes are never re-covered). On a successful winner the search result becomes the cover; otherwise the priority chain falls through to `base_image` overlay / RSS-episode-image / YouTube thumbnail as if `image:` weren't set. Tunable per podcast via the `auto_cover_*` keys in `## Image`.

Cover generation requires `imagemagick` + `librsvg` (`brew install imagemagick librsvg`) and fonts via `fontconfig`. Falls back to static cover or YouTube thumbnail on failure. Non-fatal.

**Backward compatibility:** Image keys in `## LingQ` (`image`, `base_image`, `font`, `font_color`, `font_size`, `text_width`, `text_gravity`, `text_x_offset`, `text_y_offset`) continue to work as fallbacks. The `## Image` section takes priority when present. A `## LingQ` `image:` may be an `https://` URL: `podgen publish --lingq` (and the `uploads` batch) downloads it once into `output/<podcast>/cache/` before uploading (a failed download warns and the lesson uploads without an image); `generate --lingq` takes its image from the episode cover chain instead.

#### Cover command

`podgen cover` generates or regenerates per-episode covers without re-running the full pipeline.

```bash
podgen cover lahko_noc                                        # all episodes
podgen cover lahko_noc 2026-04-07                             # specific episode (also: --date)
podgen cover lahko_noc 2026-04-07 --title "New Title"         # override the rendered title
podgen cover lahko_noc --missing-only                         # only episodes without a cover
podgen cover lahko_noc --dry-run                              # preview without writing files
podgen cover lahko_noc --title "Custom Title"                 # manual preview into <podcast_dir>/cover_preview.jpg
podgen cover lahko_noc 2026-04-07 --image auto                # search web, rank with Claude vision, fall back to overlay
podgen cover lahko_noc --image auto                           # batch — auto-search every episode (~$0.02 each)
podgen cover lahko_noc --clean                                # delete _cover1/2/3.* leftovers from --image auto
podgen cover --clean                                          # same, across all podcasts
```

| Flag                | Description                                          |
| ------------------- | ---------------------------------------------------- |
| `--missing-only`    | Skip episodes that already have a cover              |
| `--dry-run`         | Preview without writing files                        |
| `--base-image PATH` | Override `base_image` from `## Image`                |
| `--output PATH`     | Output path (manual mode)                            |
| `--font NAME`       | Override font family                                 |
| `--font-color C`    | Override font color                                  |
| `--font-size N`     | Override font size                                   |
| `--gravity POS`     | Override ImageMagick gravity (`Center`, `South`, …)  |
| `--x-offset N`      | Override horizontal text offset                      |
| `--y-offset N`      | Override vertical text offset                        |

#### Regen command

`podgen regen` rebuilds the post-pipeline binary artifacts for an existing episode without re-running the full pipeline: the YouTube `.mp4` video, the `.srt` subtitle file, and the reconciled timestamps. Each artifact is normally produced once during `generate` (and skipped on subsequent invocations); `regen` is the explicit escape hatch when one of them needs to be redone — e.g. after a transient reconciliation failure or a cover swap that requires re-rendering the video.

```bash
podgen regen bajke 2026-05-16d --reconcile   # retry Claude reconciliation + regen .srt
podgen regen bajke 0516d --video             # rebuild .mp4 (uses current cover)
podgen regen bajke --subtitles               # latest episode — regen .srt from existing timestamps
podgen regen bajke 2026-05-16d --all         # reconcile + .srt + .mp4
podgen regen bajke --last 3 --subtitles      # batch
```

| Flag           | Description                                                                              |
| -------------- | ---------------------------------------------------------------------------------------- |
| `--reconcile`  | Re-run Claude reconciliation against `_timestamps.json` (ignores the `"reconciled": true` gate). Implies `--subtitles` since the old `.srt` is stale. |
| `--subtitles`  | Regenerate `.srt` from the existing `_timestamps.json` (free, deterministic).            |
| `--video`      | Delete `.mp4` and re-render from `.mp3` + current cover via `ffmpeg`.                    |
| `--all`        | Shorthand for all three, in order: reconcile → subtitles → video.                        |
| `--force`      | Currently a no-op (each step already forces regeneration); reserved for future use.      |

Episode selection follows the [shared rules](#selecting-an-episode): positional date, `--date`, short forms, and `--last N`. No date → latest episode.

### Site Customization

The static HTML site can be themed per-podcast via a `## Site` section in `guidelines.md`:

```markdown
## Site
- accent: #e11d48
- accent_dark: #fb7185
- bg: #fefce8
- bg_dark: #1c1917
- radius: 10px
- max_width: 800px
- footer: Built with love by Jane
- show_duration: false
- show_transcript: false
```


| Key               | Default               | Description                                    |
| ----------------- | --------------------- | ---------------------------------------------- |
| `accent`          | `#2563eb`             | Link/button color (maps to `--accent` CSS var) |
| `accent_dark`     | (from stylesheet)     | Accent color in dark mode                      |
| `bg`              | `#fff`                | Background color                               |
| `bg_dark`         | `#1a1a1a`             | Background color in dark mode                  |
| `radius`          | `6px`                 | Border radius                                  |
| `max_width`       | `720px`               | Container max width                            |
| `footer`          | `Generated by podgen` | Footer text                                    |
| `show_duration`   | `true`                | Show episode duration                          |
| `show_transcript` | `true`                | Show transcript on episode pages               |


For full CSS control, drop a `site.css` file in your podcast directory (`podcasts/<name>/site.css`). It will be copied to `site/custom.css` and linked after the default stylesheet.

**Favicon:** Drop `favicon.ico`, `favicon.png`, or `favicon.svg` in `podcasts/<name>/` — auto-detected and linked (priority: ico > png > svg).

**RSS icon:** When `base_url` is configured, a small feed icon appears next to the podcast title linking to the RSS feed.

### Source Links

News pipeline episodes can include source links in the transcript. Add a `## Links` section to your `guidelines.md`:

```markdown
## Links
- show: true
- position: bottom
- title: More info
- max: 5
```


| Key        | Values            | Default     | Description                                          |
| ---------- | ----------------- | ----------- | ---------------------------------------------------- |
| `show`     | `true`/`false`    | —           | Enable source links in transcripts                   |
| `position` | `bottom`/`inline` | `bottom`    | One section at the end, or per-segment (see below)   |
| `title`    | any string        | `More info` | Heading for the bottom section (ignored when inline) |
| `max`      | integer           | unlimited   | Cap total links (bottom) or links per segment (inline) |

- `position: bottom` puts all links in one section at the end of the transcript.
- `position: inline` places links after each segment where they were referenced.
- `max` forces the script agent to pick the most relevant sources and drop near-duplicates.


When enabled, the script agent asks Claude to list every source it referenced while writing the episode. Tracking parameters are stripped from URLs. The links render as clickable items on the episode's site page. RSS transcript HTML includes the links but note that most podcast apps (Pocket Casts, Apple Podcasts) do not render HTML links in transcripts.

### Script review

Every news script is reviewed before it is voiced. Deterministic checks run first. Three of them apply a mechanical fix and log it as auto-fixed: a weekday that does not match its date is corrected, stage directions (`[pause]`, `(laughs)`) are removed, and leftover Markdown is stripped. The others only report: forbidden filler phrases, spelled-out magnitudes ("two million"), a missing title, a title over the target length, and queued priority links that went unused. Then Claude reviews the script against the research under six headings — FACTUAL ACCURACY, HALLUCINATION DETECTION, COVERAGE, TONE, NUMBER FORMAT, NATURAL FLOW — and reports each finding as a BLOCKER, a WARNING or a NIT.

- An unfixed BLOCKER sends the script back to the writer with the findings; up to two rewrites, after which the run continues with a warning in the log.
- A WARNING or NIT is logged (the indented `WARNING: [...]` / `NIT: [...]` lines in the run log) and the script is kept as written.
- Beyond the three mechanical fixes above, the reviewer never rewrites content. Titles in particular are never truncated: the writer is asked for about 40 characters, and a longer title is warned about and kept whole.

The raw script responses are kept under `output/<podcast>/debug/` for inspection.

### Priority Links

Queue specific URLs for inclusion in the next episode's research. Priority links are fed to the script agent alongside regular source results and consumed once the episode is recorded. A link whose fetch fails transiently (timeout, DNS, 5xx, 429) logs a warning and stays queued for the next run; one that fails permanently (other 4xx, a malformed or non-HTTP URL, a redirect loop) logs one warning and is dropped from the queue once the episode is recorded, without ever reaching the script.

Priority links supplement the topic research; they do not replace it. If every topic comes back with no findings, the run fails before priority links are fetched, even when links are queued.

```bash
# Add a link (URL tracking params stripped automatically)
podgen add ruby_world https://example.com/important-article --note "Cover this"

# List queued links
podgen links ruby_world

# Remove a specific link
podgen links ruby_world --remove https://example.com/important-article

# Clear all queued links
podgen links ruby_world --clear
```

Links are stored in `output/<podcast>/priority_links.yml`. Each entry records the URL, timestamp, and optional note. Duplicates are rejected.

### Vocabulary Annotation

Language pipeline transcripts can be automatically annotated with vocabulary entries for words above a given CEFR level. Add a `## Vocabulary` section to your `guidelines.md`:

```markdown
## Vocabulary
- level: B1
- max: 30
- frequency: uncommon
- similar: Russian, English
- filter: Skip words related to food
```

- `level`: CEFR cutoff — words **at or above** this level are annotated. Valid values: A1, A2, B1, B2, C1, C2.
- `max`: Upper bound on vocabulary entries per episode — not a quota. Episodes with fewer eligible words (after the ledger drops recently explained lemmas) carry fewer entries. Which words fill the slots is decided by `priority` (see *Selection policy* below).
- `priority`: Selection preset — `balanced` (default), `hardest`, or `frequent`.
- `frequency`: Frequency preset — `common`, `uncommon`, `rare`, `literary`, or `archaic`. Controls whether everyday vs. rare words are included.
- `similar`: Comma-separated list of languages the learner already knows. Words that are cognates in any of these languages are **filtered out deterministically** using transliteration + Levenshtein distance (e.g. Slovenian "profesor" ≈ English "professor" ≈ Russian "профессор" → excluded). Works across writing systems (Latin/Cyrillic).
- `filter`: Free-form custom instruction passed to the LLM (e.g. "Skip words related to food").

When enabled, after the transcript is saved the pipeline sends the transcript text to Claude, which classifies words by CEFR level, identifies dictionary forms (lemmas), and generates translations and definitions. The result is:

1. **Marked words** in the transcript — all occurrences of each vocabulary word are wrapped in `**bold**`
2. **Vocabulary section** appended to the transcript file — entries with lemma, IPA pronunciation, CEFR level, part of speech, translation, and definition, **in the order the words first occur in the story**, so the list can be followed while listening. When the episode has key words (below), the section carries two sub-headings: `### Key words` first, then `### Also new`; without key words it is a single flat list. The entry line format is the same either way.

On the generated **site**, bold vocabulary words become hoverable links with tooltip bubbles showing the vocabulary entry (IPA, part of speech, definition). The vocabulary section renders as a definition list with anchored entries (one `<h3>` and list per group when the sub-headings are present). Episode pages show a 📖 Vocabulary link in the header when vocabulary is present.

#### Key words

Before classification, the annotator picks up to 8 story-critical words: words of 4+ letters that occur at least 3 times in the episode, are not proper nouns (a word capitalised in more than half of its mid-sentence occurrences, or never seen mid-sentence at all, is treated as a name), and appear in at most 15% of the show's earlier episodes, ranked by in-episode frequency × inverse document frequency across the show. The classifier is asked to include them whatever their level; matching entries are kept regardless of the CEFR cutoff, the `frequency` preset, the ledger and the `max` cap, and are listed first under `### Key words`. Only known words (below) remove them. Key words need at least one earlier episode to compare against: a show's first episode and `revocab --no-ledger` skip them (logged as `Key terms skipped: no earlier episodes`).

#### Selection policy

When more words qualify than `max` allows, entries are chosen by level band — distance above the cutoff: at the cutoff, one level above, two or more above. Each band gets a share of `max`:

| `priority` | at cutoff | +1 | +2 and above | order within a band |
|---|---|---|---|---|
| `balanced` (default) | 50% | 35% | 15% | in-episode frequency × inverse show frequency |
| `hardest` | 25% | 40% | 35% | in-episode frequency × inverse show frequency |
| `frequent` | 50% | 35% | 15% | raw in-episode frequency |

A band that has fewer words than its share passes the unused slots to the next band down, then up. Key words and `--include` words are always kept and count toward `max`.

#### Cross-episode memory: ledger and cache

- **Ledger** — derived on every run from the show's own transcripts (nothing stored): a lemma already explained in an earlier episode is not explained again until enough episodes have passed — the 2nd explanation at least 8 episodes after the 1st, the 3rd at least 20 after the 2nd, the 4th at least 50 after the 3rd; after 4 explanations it is not explained again (a candidate for known vocabulary). Re-exposed lemmas are named in the run log. `--include` words and key words bypass the ledger; known words always win. `revocab` sees only the episodes before the one it re-annotates.
- **Cache** — `output/<podcast>/vocab_cache.yml` stores each lemma's translations and definitions per target language (plus IPA and similar-language translations) after it is first enriched, so a repeated lemma costs no API call and keeps the same gloss in every episode. A lemma missing one target language is enriched for that language only. The file is derived and can be deleted to start fresh.

In **RSS transcript HTML** (for podcast apps), the vocabulary section is stripped and bold markers are removed, producing clean readable text. This is because podcast apps (Pocket Casts, Apple Podcasts, etc.) do not render HTML formatting or links in transcripts.

If the section is absent or has no `level` key, the pipeline is unchanged.

#### Re-annotating Existing Episodes

To re-annotate vocabulary on previously published episodes:

```bash
podgen revocab <podcast> [episode-id]     # specific episode or all
podgen revocab <podcast> --missing-only   # only episodes without vocabulary
podgen revocab <podcast> --dry-run        # preview without changes
podgen revocab <podcast> --from 2026-09-01 --to 2026-09-30 --limit 10  # date range (inclusive), earliest N
podgen revocab <podcast> --no-ledger      # ignore earlier episodes (no re-exposure rule, no key words)
podgen revocab <podcast> --no-cache       # enrich every lemma afresh; vocab_cache.yml neither read nor written
# ends with "re-annotated N, skipped N, failed N (<basenames>)"; exit 1 when any file failed
```

#### Known Vocabulary

Words you already know can be excluded from annotations. Manage the list via CLI:

```bash
podgen vocab add lahko_noc beseda          # add a word (language from config)
podgen vocab add lahko_noc sprechen --lang de  # explicit language
podgen vocab remove lahko_noc beseda       # remove a word
podgen vocab list lahko_noc                # show all known words
podgen vocab review fiabe [--min 3]        # lemmas explained 3+ times (count, last episode), known ones excluded
podgen vocab review fiabe --promote        # add every listed lemma to known vocabulary
podgen vocab edit fiabe accorgersi --lang English --translation "to notice" [--definition "..."]  # fix a cached gloss for future episodes
```

Known words are stored as lemmas (dictionary forms) in `podcasts/<name>/known_vocabulary.yml`. All derivatives (conjugations, cases) of a known lemma are automatically excluded — matching is on the lemma returned by Claude, not the surface form in the text.

### LingQ Upload Configuration

```markdown
## LingQ
- collection: 2629430
- level: 3
- tags: otroci, pravljice
- status: private
```

- `collection` (required): LingQ collection/course ID
- `level` / `tags` / `status`: lesson metadata
- Upload is non-fatal — the pipeline continues if it fails

### Twitter/X Announcements

Automatically tweet about new episodes after publishing to R2. Add a `## Twitter` section to your guidelines.md and set OAuth 1.0a credentials in `.env`:

```
TWITTER_CONSUMER_KEY=...
TWITTER_CONSUMER_SECRET=...
TWITTER_ACCESS_TOKEN=...
TWITTER_ACCESS_SECRET=...
```

```markdown
## Twitter
- template: New episode: {title}\n{site_url}
- since: 7
- languages: en, it
```

- `template`: Tweet text with `{title}`, `{description}`, `{site_url}`, `{mp3_url}` variables (default: `🎙 {title}\n\n{site_url}`). Use `\n` for line breaks
- `since`: Only tweet episodes from the last N days (default: 7). Prevents tweeting the entire backlog when first enabling
- `languages`: Comma-separated list of language codes whose episodes get announced. Default when omitted: only the primary language. Use `languages: all` to announce every configured language. Older builds tweeted every language MP3 indiscriminately — set `languages: all` if you want that back.

Tweets fire automatically after a successful `podgen publish` to R2. Each episode is tweeted once — tracked in `uploads.yml` under the `twitter` platform. The site URL in the tweet correctly points at the language-specific page (e.g. `/site/it/episodes/...` for Italian). Tweeting is non-fatal: if it fails, publish still succeeds. Failed posts are retried twice, except HTTP 402 (X pay-per-use credits at zero), which fails after one call with "X API credits depleted — top up in the developer console"; `podgen status` flags repeated publish warnings and stalled announcements.

To manually tweet about a specific (e.g. older) episode:

```bash
podgen tweet fulgur_news 2026-03-15           # tweet a specific episode
podgen tweet fulgur_news 2026-03-15 --dry-run # preview without posting
podgen tweet fulgur_news 2026-03-15 --force   # re-tweet even if already posted
```

| Flag              | Description                                                              |
| ----------------- | ------------------------------------------------------------------------ |
| `--force`         | Tweet even if the episode is already tracked as tweeted                  |
| `--dry-run`       | Print the tweet without posting                                          |
| `--template TEXT` | Override the configured `template` from `## Twitter` for this run        |

## Scheduling (launchd)

Install a daily launchd scheduler:

```bash
# Default: generate at 06:00
podgen schedule ruby_world

# Custom time (24h format)
podgen schedule ruby_world --time 18:00

# Generate + publish, with Telegram alerts on failure
podgen schedule fulgur_news --time 18:00 --publish --telegram
```

| Flag           | Description                                            |
| -------------- | ------------------------------------------------------ |
| `--time HH:MM` | Time to run in 24h format (default: `06:00`)           |
| `--publish`    | Run `podgen publish` after a successful generate       |
| `--telegram`   | Send Telegram alert on generate or publish failure     |
| `--test`       | Send a test Telegram message and exit                  |
| `--remove`     | Unload and delete the scheduler for this podcast       |
| `--status`     | Report scheduled time, loaded/running state, last run  |
| `--status-check` | Schedule the daily `podgen status` check (no podcast arg) |

`--remove`, `--status`, and `--test` are mutually exclusive. `--telegram` requires `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in `.env` (root or per-podcast). Use `--test` after setup to verify alerts are working.

Check status of an installed scheduler:

```bash
podgen schedule ruby_world --status
# ruby_world:
#   scheduled:       06:00 daily
#   loaded:          yes
#   running:         yes (PID 12345)
#   last run:        2026-04-23 06:00:14 (1d 5h ago)
#   last exit code:  0
```

Remove a scheduler:

```bash
podgen schedule ruby_world --remove
```

`--remove` and `--status` do not require the podcast directory to still exist, so you can clean up schedulers for deleted podcasts.

**Note:** macOS must be awake at the scheduled time. Keep the machine plugged in and disable sleep, or use `caffeinate`.

### podgen status (content-progress check)

`podgen status` prints one line per podcast (podcasts with an installed launchd
scheduler first). It is read-only; its one network call reads back each
podcast's served `base_url/feed.xml` (skipped with `--offline` or without a
`base_url`).

```
ruby_world  OK    newest 2026-10-10 (1d old)
fulgur_news WARN  announcements stalled since 2026-08-19 (newest episode 2026-10-11)
old_show    OLD   newest episode 2026-09-04 is 37 days old (cadence ~1d, threshold 2d)
```

- **OLD** - newest episode older than the cadence threshold (same rule as the
  `podgen validate` freshness check; `- freshness: off` in `## Podcast` reports OK).
  The cadence is the median gap between recent episode dates, or
  `- cadence_days: N` in `## Podcast` when set (a positive integer; anything
  else is ignored); the threshold is twice the cadence, at least 2 days:
  `newest episode 2026-10-01 is 10 days old (cadence 2d configured, threshold 4d)`.
  With no cadence (episodes on a single date and no `cadence_days`) there is no
  threshold: the show stays OK, and once its newest episode is more than 30
  days old the line says so - `newest 2026-02-19 (235d old; dormant — no cadence)`.
  Set `cadence_days` to make such a show go OLD, or `freshness: off` if it has
  concluded.
- **WARN** - the latest run log in `logs/<podcast>/` ends with a
  `RUN-OUTCOME status=warn|error warnings=N errors=M first=…` line (every
  generate writes one; it counts the end-of-run warnings, library warnings
  such as a failed source or skipped AI review, and `ERROR` entries) - shown
  as `<log>: <first warning>` or `<log>: run failed: <first error>`; or
  (older logs, or an `ok` outcome) it ends with an `ERROR` line or
  contains a `Warning:` / `WARNING` line, or the same warning appears in each of
  the last 3 run logs (`--runs N` to change), or there is no history yet.
  Indented reviewer findings (`  WARNING: [COVERAGE] …`, the script review's
  own output) are not pipeline warnings and are ignored. A newest episode
  dated up to `freshness_lead_days` ahead (`## Podcast` key, default 3) is OK
  and shown as `(scheduled +Nd)`; further ahead is WARN.
- **WARN (publish)** - the same `Warning:` line in each of the last 3 or more
  scheduled publishes, read from `logs/launchd_stderr.log` (the shared stderr
  of the per-podcast launchd jobs). `scripts/run.sh` brackets each publish
  with dated markers (`2026/10/12 16:52:00 podgen publish <pod> begin` …
  `podgen publish <pod> end exit=N`): every `Warning:` line between them
  belongs to that podcast's publish, and the streak counts only that
  podcast's publishes. Lines written before the markers existed are read by
  the legacy rule: a dated rclone line (`2026/09/20 16:52:04 NOTICE: ...`)
  starts a publish; undated `Warning:` lines after it belong to that publish;
  generate output (`[2026-10-08 19:19:21] ERROR ...`, `Generate failed ...`)
  is skipped since the run logs above already cover it. Legacy publishes name
  no podcast, so their Twitter warnings are attributed to every podcast with
  a `## Twitter` section and other warnings to every podcast with an
  installed launchd scheduler; the streak runs across legacy and marked
  publishes. Legacy limitation: an undated generate-time warning that follows
  a publish is counted with that publish, and when several podcasts publish
  only the last one's warnings are visible. A legacy publish counts as latest
  only while no marked publish follows it. A publish whose end marker never
  came closes at the next generate output or dated line of a later day.
  Marker limitation: overlapping launchd jobs (two publishes interleaved in
  the shared stderr) can misattribute warnings between begin/end markers. A marked publish that runs past midnight is split at the
  first next-day rclone line; the later warnings land in an unnamed entry.
  Shown as
  `publish warning in last 44 publishes (since 2026-08-20): Warning: Twitter posting failed: ...`.
  Without markers, if rclone ever stops printing a dated line, publishes can
  no longer be told apart and this check goes quiet - the announcement check
  below does not depend on the stderr.
- **WARN (announcements)** - for podcasts with a `## Twitter` section only:
  the newest episode (on disk, in the Twitter `languages`) is more than
  `since` days (default 7) newer than the newest tweeted episode in
  `output/<podcast>/uploads.yml` (`twitter: posts:`):
  `announcements stalled since 2026-08-19 (newest episode 2026-10-11)`.
  With no tweet recorded at all, it warns
  (`announcements never posted (...)`) only once some announced episode is
  older than `since` days, so a brand-new show is not flagged.
- **WARN (uploads)** - the same rule per upload platform the podcast
  configures (`## YouTube` → `youtube: <playlist or default>`, `## LingQ`
  with a `collection` → `lingq: <collection>` in `uploads.yml`), over every
  episode on disk, with a fixed 7-day window:
  `youtube uploads stalled since 2026-06-02 (newest episode 2026-10-11)` or
  `lingq uploads never made (...)`. For podcasts with `## YouTube`, the
  latest batch in `logs/uploads_stderr.log` (the scheduled upload batch's
  stderr; the lines after the last `… podgen uploads <pods> begin` marker
  that `scripts/run_uploads.sh` writes, only when the file was written in
  the last 7 days; a log with no marker yet reports nothing) adds one line
  per condition found, naming it only: `uploads_stderr.log: YouTube not authorized` /
  `uploads_stderr.log: YouTube upload quota exceeded`.
- **WARN (served feed)** - the newest `<item>` pubDate in the served
  `base_url/feed.xml` is more than 1 day older than the newest local
  primary-language episode dated today or earlier:
  `served feed behind local by 5d (served 2026-10-05, local 2026-10-10)`. A
  failed fetch (5s connect / 10s read timeout, one retry) names only the
  error class or HTTP code: `served feed fetch failed: SocketError`.
- **OK** - otherwise.

Exit code is `0` when every podcast is OK, `1` otherwise (`2` for an unknown
podcast), so a scheduled run can alert on non-zero. `--json` prints a stable
array; keys are only ever added, never renamed or removed:

```json
[{"podcast": "ruby_world", "verdict": "OK", "newest": "2026-10-10", "age_days": 1, "reasons": ["newest 2026-10-10 (1d old)"],
  "announcements": {"last_tweeted": "2026-10-10", "newest_episode": "2026-10-10", "stalled": false},
  "uploads": {"youtube": {"last_uploaded": "2026-10-10", "newest_episode": "2026-10-10", "stalled": false}}}]
```

`verdict` is `OK`, `OLD` or `WARN`; `newest` (ISO date) and `age_days` are `null`
when unknown (`age_days` is negative for a scheduled, future-dated episode);
`reasons` is an array of short strings. `announcements` is `null` without a
`## Twitter` section; otherwise `last_tweeted` and `newest_episode` are ISO
dates (`null` when none) and `stalled` is the announcement check's verdict.
`uploads` is `null` when no upload platform is configured; otherwise one
entry per platform (`youtube`, `lingq`) of the same shape, with
`last_uploaded`.

The daily check is installed by the owner only (`podgen status --install-hint`
prints the command): `bin/podgen schedule --status-check --time 07:00` writes
and loads `com.podcastagent.status`, which runs `scripts/run_status.sh`. That
wrapper sends the summary to Telegram (`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`
in `.env`) only when the exit code is non-zero.

### Scheduled batch uploads across multiple pods

For households running several podcasts, install a single daily upload job that walks every pod through `regen → R2 → LingQ → YouTube` in one tick:

```bash
podgen schedule --uploads bajke,fiabe,basnie --time 10:30
```

Per pod, sequentially: regenerate RSS+site (memoized), sync to Cloudflare R2, upload pending LingQ episodes (if configured). YouTube uploads then run across all pods that survived the front-end phase, capped by `--max` if set.

| Flag                 | Description                                                                  |
| -------------------- | ---------------------------------------------------------------------------- |
| `--uploads <pods>`   | Comma-separated pod list                                                     |
| `--time HH:MM`       | Time to run daily (default `06:00`)                                           |
| `--mode priority`    | (default) Drain pods in list order; later pods only run when earlier are done |
| `--mode round-robin` | One YT episode per pod per round, looping until drained / `--max` / rate-limited |
| `--max N`            | Cap TOTAL YouTube uploads across the tick (LingQ always drains)              |
| `--remove`           | Remove the installed `uploads` schedule                                      |
| `--status`           | Show installed pods, mode, max, last run                                     |

Failure rules:

- **R2 sync fail** for a pod is fatal — that pod is skipped from LingQ + YouTube for the tick.
- **LingQ fail** is logged but the pod still proceeds to YouTube; LingQ retries naturally next tick.
- **YouTube rate limit** halts the YT phase but is an expected daily occurrence and does NOT cause a non-zero exit.
- **Same YouTube error two rounds running** (round-robin; "same" means the same error class, or the same error type such as `upload`/`video` when no class is recorded) stops retrying that pod for the rest of the tick, logging one line: `uploads: <pod> permanently skipped — <error class or type>: <message> (same error 2 rounds running)`. Items stay pending for the next tick; the exit code is unaffected.

Run ad-hoc (no schedule) with the same semantics:

```bash
podgen uploads bajke,fiabe,basnie --mode round-robin --max 6
```

## RSS Feed

Generate a podcast RSS feed from your episodes:

```bash
podgen rss ruby_world
```

Serve locally:

```bash
cd output/ruby_world && ruby -run -e httpd . -p 8080
```

Then add `http://localhost:8080/feed.xml` to your podcast app. For remote access, host the `output/` directory on any static file server (nginx, S3, Cloudflare Pages, etc.) and update the enclosure URLs in the feed accordingly.

### Serving via Tailscale Funnel

For remote access without port forwarding or a public server:

```bash
ruby scripts/serve.rb 8080
tailscale funnel 8080
```

This exposes your feed at `https://<hostname>.ts.net/<podcast>/feed.xml`. Requires Tailscale HTTPS + Funnel enabled in the admin console. Set `base_url` in `guidelines.md` accordingly.

## Publishing to Cloudflare R2

Publish your podcast to [Cloudflare R2](https://developers.cloudflare.com/r2/) for always-available hosting at $0/month (free tier covers typical podcast usage). A Cloudflare Worker serves files and tracks per-episode download analytics.

See [docs/cloudflare.md](docs/cloudflare.md) for complete Cloudflare setup (R2 bucket, custom domain, analytics Worker).

### Quick setup

1. **Install rclone**: `brew install rclone`
2. Create R2 bucket + API token, add to `.env`:

```
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com
R2_BUCKET=podgen
```

3. Set `base_url` in `podcasts/<name>/guidelines.md`
4. Set up the analytics Worker: `podgen analytics setup`

### Publishing

```bash
# Publish (regenerates RSS + site, syncs to R2)
podgen publish ruby_world

# Preview what would be synced
podgen --dry-run publish ruby_world

# Single episode by date
podgen publish ruby_world 2026-03-28

# Publish to LingQ or YouTube instead of R2
podgen publish lahko_noc --lingq
podgen publish lahko_noc --youtube
```

| Flag        | Description                                                   |
| ----------- | ------------------------------------------------------------- |
| `--lingq`   | Publish to LingQ instead of R2 (language pipeline)            |
| `--youtube` | Publish to YouTube instead of R2 (language pipeline)          |
| `--newest`  | Process newest episodes first (useful with quota limits)      |
| `--force`   | Re-upload even if already tracked in `uploads.yml`            |
| `--dry-run` | Show what would be published without uploading                |

Syncs only public-facing files: MP3 episodes, HTML transcripts, feed XML, site pages, and cover image. Internal files (history, research cache, markdown sources) are excluded.

### Download analytics

The analytics Worker logs every MP3 download to Cloudflare Analytics Engine. Query via:

```bash
# All podcasts — totals, avg/day, top countries, top apps
podgen stats --downloads

# Single podcast — per-episode counts, countries, apps, daily breakdown
podgen stats --downloads ruby_world

# Time shortcuts
podgen stats --today ruby_world     # last 24h
podgen stats --week ruby_world      # last 7 days
podgen stats --month ruby_world     # last 30 days

# Custom lookback period
podgen stats --downloads ruby_world --days 90
```

Requires `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` in `.env`. See [docs/cloudflare.md](docs/cloudflare.md) for token setup.

### Vocabulary frequency

For language podcasts, find which vocabulary words come up most often:

```bash
podgen stats fiabe --words                       # top 50 by body occurrences (default)
podgen stats fiabe --words --top 100             # top 100
podgen stats fiabe --words --top 0               # all
podgen stats fiabe --words --sort vocab          # sort by per-episode vocab frequency instead
podgen stats fiabe --vocab-health [--last 10]    # census: repeat share, levels vs cutoff, key-term misses, drift (--all: every show)
```

Two columns: `BODY` is the number of times the lemma (or any inflected form) appears across all transcript bodies; `VOCAB` is the number of episodes that listed the lemma in their `## Vocabulary` section.

Inflected forms come from three sources:
1. The lemma itself.
2. Historical `*original*` surface forms collected from past vocab entries.
3. `Tell::Hunspell.expand` — used automatically when a hunspell dictionary for the podcast's `transcription_language` is installed at `~/Library/Spelling/<LANG>.{dic,aff}` (or any of the system dirs `/Library/Spelling`, `/usr/share/hunspell`, `/usr/local/share/hunspell`). Hunspell expansion only runs for single-word lemmas — multi-word entries (e.g. `andare d'accordo`) skip it to avoid false matches from individual tokens.

To install hunspell dicts for the languages of all configured podcasts:

```bash
ruby scripts/install_hunspell_dicts.rb            # auto-detect from podcasts
ruby scripts/install_hunspell_dicts.rb it sl pl   # explicit list
```

Pulls `.dic`/`.aff` files from [github.com/wooorm/dictionaries](https://github.com/wooorm/dictionaries) and installs them into `~/Library/Spelling`. Idempotent.

When hunspell isn't available for a language, body counts use lemma + historical surface forms only (a warning prints to stderr). Generated forms are cached at `output/<podcast>/word_forms.yml` and regenerate only when the lemma set or hunspell-availability changes.

## Project Structure

```
podgen/
├── bin/
│   ├── podgen                # CLI executable (loads .env, dispatches commands)
│   └── tell                  # TTS pronunciation tool (standalone)
├── podcasts/<name>/
│   ├── guidelines.md         # Podcast format, style, sources, languages, publishing config
│   ├── queue.yml             # Fallback topic queue
│   ├── pronunciation.pls     # TTS pronunciation overrides (optional)
│   ├── known_vocabulary.yml  # Words excluded from vocabulary annotation (optional)
│   ├── intro.mp3 / outro.mp3 # Jingles (optional)
│   ├── site.css              # Custom CSS for the static site (optional)
│   ├── favicon.ico           # Site favicon (optional, auto-detected; .png/.svg also work)
│   └── .env                  # Per-podcast overrides (optional, gitignored)
├── lib/
│   ├── cli.rb                # CLI dispatcher: command registry, help, owner-action guard
│   ├── cli/
│   │   ├── generate_command.rb    # Pipeline dispatcher; the news pipeline
│   │   ├── generate_options.rb    # generate's option list (shared with the guard's dry parse)
│   │   ├── language_pipeline.rb   # Language pipeline (phased orchestrator)
│   │   ├── episode_selector.rb    # Shared episode selection (--date, positional, --last)
│   │   ├── podcast_command.rb     # Shared mixin: podcast name validation + config loading
│   │   ├── translate_command.rb   # Translate existing episodes to new languages
│   │   ├── voice_command.rb       # Voice or re-voice from script JSON
│   │   ├── render_command.rb      # Re-render script markdown from JSON
│   │   ├── scrap_command.rb       # Remove an episode + history entry
│   │   ├── move_command.rb        # Move episode artifacts to another date
│   │   ├── regen_command.rb       # Rebuild .mp4 / .srt / reconciled timestamps
│   │   ├── rss_command.rb         # RSS feed generation
│   │   ├── site_command.rb        # Static HTML website generation
│   │   ├── publish_command.rb     # Publish to Cloudflare R2, LingQ, YouTube
│   │   ├── unpublish_command.rb   # Remove from R2 or delete YouTube videos
│   │   ├── uploads_command.rb     # Multi-podcast regen + R2 + LingQ + YouTube batch
│   │   ├── tweet_command.rb       # Announce an episode on X
│   │   ├── schedule_command.rb    # Install launchd jobs (generate, uploads, status check)
│   │   ├── status_command.rb      # OK/OLD/WARN per podcast (content progress, warnings, announcements)
│   │   ├── stats_command.rb       # Podcast statistics, download analytics, vocabulary frequency
│   │   ├── analytics_command.rb   # Manage the Cloudflare analytics Worker
│   │   ├── validate_command.rb    # Validate config and output
│   │   ├── list_command.rb        # List available podcasts
│   │   ├── init_command.rb        # Create a podcast (skeleton or from an existing one)
│   │   ├── fork_command.rb        # Fork a podcast with all content into a new namespace
│   │   ├── add_command.rb         # Queue a priority link
│   │   ├── links_command.rb       # List/manage queued priority links
│   │   ├── exclude_command.rb     # Exclude URLs from future episodes
│   │   ├── vocab_command.rb       # Manage known vocabulary words
│   │   ├── revocab_command.rb     # Re-annotate vocabulary on transcripts
│   │   ├── reformat_command.rb    # Reformat transcripts
│   │   ├── cover_command.rb       # Generate episode cover images
│   │   ├── test_command.rb        # Run component test scripts
│   │   └── version.rb             # PodgenCLI::VERSION
│   ├── claude_models.rb      # Model registry: lines, roles, per-role effort, ENV overrides
│   ├── anthropic_client.rb   # Shared Anthropic client setup, text extraction, structured-output checks
│   ├── openai_client.rb      # Shared OpenAI client setup (transcription, translation)
│   ├── usage_logger.rb       # Token/cache usage log lines for every Claude call
│   ├── agents/
│   │   ├── topic_agent.rb         # Claude topic generation (+ Hacker News keyword queries)
│   │   ├── research_agent.rb      # Exa.ai search
│   │   ├── script_agent.rb        # Claude script generation (structured output)
│   │   ├── script_reviewer.rb     # Deterministic checks (three mechanical auto-fixes) + AI review; never rewrites content
│   │   ├── translation_agent.rb   # Script translation (Claude or OpenAI backend, glossary)
│   │   ├── tts_agent.rb           # ElevenLabs TTS (pronunciation dictionaries, chunking)
│   │   ├── description_agent.rb   # Title/description cleanup and generation
│   │   ├── transcription_agent.rb # Backward-compat shim → OpenAI engine
│   │   ├── lingq_agent.rb         # LingQ lesson upload
│   │   ├── twitter_agent.rb       # X announcements (OAuth 1.0a; 402 = credits depleted)
│   │   └── cover_agent.rb         # ImageMagick cover image generation
│   ├── sources/
│   │   ├── base_source.rb         # Template base class for topic-based sources
│   │   ├── rss_source.rb          # RSS/Atom feed fetcher + episode fetcher
│   │   ├── hn_source.rb           # Hacker News Algolia API (keyword queries)
│   │   ├── claude_web_source.rb   # Claude + web_search tool
│   │   ├── bluesky_source.rb      # Bluesky AT Protocol post search
│   │   └── x_source.rb            # X (Twitter) via SocialData.tools API
│   ├── source_manager.rb     # Multi-source research coordinator
│   ├── source_registry.rb    # Registry of every external endpoint (rake health; gate scan)
│   ├── research_cache.rb     # File-based research cache (24h TTL)
│   ├── priority_links.rb     # YAML-backed priority link queue
│   ├── url_cleaner.rb        # Strip tracking params (utm_*, fbclid, etc.)
│   ├── transcription/
│   │   ├── base_engine.rb         # Shared base class (retries, logging)
│   │   ├── openai_engine.rb       # OpenAI Whisper / gpt-4o-transcribe (engine: "open")
│   │   ├── elevenlabs_engine.rb   # ElevenLabs Scribe (engine: "elab")
│   │   ├── groq_engine.rb         # Groq hosted Whisper + word timestamps (engine: "groq")
│   │   ├── engine_manager.rb      # Single or parallel comparison mode
│   │   └── transcript_merger.rb   # Claude merge of multi-engine transcripts
│   ├── episode_source.rb     # Episode acquisition: local/YouTube/RSS, dedup, length filter
│   ├── youtube_downloader.rb # yt-dlp wrapper (metadata, audio download, captions)
│   ├── audio_trimmer.rb      # Trimming: skip/cut/snip, autotrim outro
│   ├── audio_assembler.rb    # ffmpeg wrapper (assembly, loudnorm, ID3)
│   ├── voicer.rb             # Voice a script: TTS per segment + assembly
│   ├── text_splitter.rb      # TTS chunking at natural boundaries
│   ├── episode_naming.rb     # The episode basename scheme (date, day slot, language tail)
│   ├── episode_history.rb    # Episode history (atomic YAML writes)
│   ├── history_maps.rb       # History lookups for feeds/site (per-language durations)
│   ├── episode_artifacts.rb  # Every on-disk file of one episode (scrap, move)
│   ├── episode_filtering.rb  # Shared MP3 glob/filter helpers
│   ├── episode_scanner.rb    # Publishable episodes (mp3 + transcript) for the publishers
│   ├── script_artifact.rb    # Canonical script JSON read/write
│   ├── script_renderer.rb    # Script JSON → markdown view (## Links)
│   ├── legacy_script_parser.rb # Markdown script → JSON for pre-JSON episodes
│   ├── timestamp_persister.rb # Word/segment timestamps → _timestamps.json
│   ├── subtitle_generator.rb # _timestamps.json → .srt
│   ├── subtitle_parser.rb    # SRT/VTT/JSON → plain text
│   ├── subtitle_reconciler.rb # Claude reconciliation of timestamps against the transcript
│   ├── subtitle_reconciliation_runner.rb # Runs reconciliation once per episode (regen --reconcile)
│   ├── video_builder.rb      # Cover + audio → .mp4 (reused while newer than the mp3)
│   ├── video_generator.rb    # ffmpeg video rendering
│   ├── rss_generator.rb      # RSS 2.0 + iTunes + Podcasting 2.0 feed, per language
│   ├── site_generator.rb     # Static HTML website (ERB templates), per language
│   ├── transcript_renderer.rb # Shared transcript HTML rendering (RSS + site)
│   ├── transcript_parser.rb  # Transcript markdown structure (segments, vocabulary)
│   ├── transcript_discovery.rb # Existing transcripts (feed tags, episode pages, YouTube captions) before STT
│   ├── vocabulary_annotator.rb # CEFR vocabulary annotation (Claude + cognate filtering)
│   ├── vocab_ledger.rb       # Explained-lemma ledger + show token df (derived from transcripts)
│   ├── vocab_cache.rb        # Enrichment cache (output/<pod>/vocab_cache.yml)
│   ├── key_terms.rb          # Story-critical key-word candidates (tf × idf)
│   ├── known_vocabulary.rb   # Per-language known word lists
│   ├── word_stats.rb         # Vocabulary frequency (hunspell forms, language detection)
│   ├── vocab_health.rb       # Vocabulary census for stats --vocab-health
│   ├── language_names.rb     # ISO 639-1 → language name
│   ├── cover_resolver.rb     # Shared cover lookup/generation (publish, pipeline, site, cover command)
│   ├── episode_cover_resolver.rb # Cover priority chain for a language-pipeline episode
│   ├── auto_cover_resolver.rb # image: auto — web search + Claude vision ranking
│   ├── image_searcher.rb     # DuckDuckGo image search for auto covers
│   ├── image_ranker.rb       # Claude vision ranking of cover candidates
│   ├── r2_publisher.rb       # rclone sync to Cloudflare R2 + announcements
│   ├── lingq_publisher.rb    # LingQ bulk publish with tracking
│   ├── youtube_publisher.rb  # YouTube publish: video, captions, playlist, tracking
│   ├── youtube_uploader.rb   # YouTube Data API client (OAuth)
│   ├── post_pipeline_uploads.rb # LingQ/YouTube uploads after generate
│   ├── publisher_shared.rb   # Shared publish helpers
│   ├── upload_tracker.rb     # uploads.yml (LingQ, YouTube, X), atomic
│   ├── regen_cache.rb        # In-process memoization of RSS + site regeneration
│   ├── analytics_client.rb   # Cloudflare Analytics Engine GraphQL client
│   ├── validators/           # podgen validate: guidelines, feed, episodes, history, freshness, covers, orphans …
│   ├── podcast_config.rb     # Config resolver (delegates parsing to GuidelinesParser)
│   ├── guidelines_parser.rb  # Parses guidelines.md sections into structured config
│   ├── podcast_validator.rb  # Runs the validators
│   ├── production_run.rb     # Detects a running production generate (dev-loop yield)
│   ├── connectivity.rb       # Network preflight before a scheduled run
│   ├── fixture_recorder.rb   # Records real API responses as test fixtures (rake fixtures:record)
│   ├── http_downloader.rb    # HTTP file download with retries
│   ├── remote_image_cache.rb # Caches a remote image URL under output/<podcast>/cache/ (LingQ image: URL)
│   ├── http_retryable.rb     # Mixin: HTTP-specific retries (includes Retryable)
│   ├── retryable.rb          # Mixin: exponential backoff retries
│   ├── atomic_writer.rb      # Temp file + rename writes
│   ├── yaml_loader.rb        # Safe YAML loading
│   ├── time_value.rb         # Seconds or min:sec with absolute? flag
│   ├── snip_interval.rb      # Unified skip/cut/snip interval math
│   ├── format_helper.rb      # Human-readable sizes and durations
│   ├── loggable.rb           # Mixin: logger accessor with $stderr fallback
│   ├── logger.rb             # Structured logging with phase timings
│   ├── templates/            # ERB templates + CSS for the site generator
│   └── tell/                 # TTS pronunciation tool modules
│       ├── config.rb         # Config loader (~/.tell.yml)
│       ├── detector.rb       # Language detection (Unicode + stop words)
│       ├── translator.rb     # Translation engines (DeepL, Claude, OpenAI)
│       ├── translation_service.rb # Failover chain across translation engines
│       ├── tts.rb            # TTS engines (ElevenLabs, Google)
│       ├── engine.rb / engine_pool.rb # Tell processing engine; thread-safe glosser/translator cache for the web UI
│       ├── glosser.rb        # Grammatical glossing via Claude
│       ├── espeak.rb         # eSpeak-ng wrapper: IPA phonetic transcription
│       ├── icu_phonetic.rb   # ICU transliteration: Cyrillic/Greek/Korean romanization
│       ├── kana.rb           # Japanese kana conversion utilities
│       ├── japanese_brackets.rb # Japanese reading brackets
│       ├── phonetic_systems.rb # Phonetic system definitions per language
│       ├── hunspell.rb       # Hunspell dictionary expansion
│       ├── hints.rb          # Style hint parser (/p, /c, /m, /f suffixes)
│       ├── history.rb        # REPL history
│       ├── colors.rb         # ANSI colorization for gloss/phonetic output
│       ├── error_formatter.rb # Friendly error messages for API errors
│       ├── processor.rb      # Main processing pipeline
│       ├── web.rb            # Sinatra web UI: SSE streaming, /speak, /systems
│       └── web/views/index.erb # Single-page web UI (HTML + CSS + JS)
├── docs/
│   ├── quickstart.md         # Your first news podcast in five steps
│   ├── cloudflare.md         # Cloudflare R2 + Worker + analytics + Tell Web setup
│   ├── pronunciation.md      # PLS format guide & IPA reference
│   └── DEV-LOOP.md           # How the project is developed (phases, gates, tiers)
├── scripts/
│   ├── run.sh                # launchd wrapper: generate, optional publish + Telegram alert
│   ├── run_uploads.sh        # launchd wrapper: podgen uploads
│   ├── run_status.sh         # launchd wrapper: podgen status → Telegram on non-zero
│   ├── prod_guard.sh         # Dev-loop hook: yield while a production generate runs
│   ├── serve.rb              # WEBrick static file server
│   ├── tell_web.rb           # Tell Web UI launcher
│   ├── install_hunspell_dicts.rb # Hunspell dictionaries for vocabulary frequency
│   └── test_*.rb             # Manual component tests (most dispatched by `podgen test`)
├── test/
│   ├── unit/                 # Fast tier, no I/O (in the gate)
│   ├── integration/          # Offline subset in the gate
│   ├── api/                  # Keyed live checks (skip without keys; never in the gate)
│   ├── browser/              # Tell Web browser checks
│   └── fixtures/             # Recorded real responses, trimmed
├── output/<name>/
│   ├── episodes/             # MP3s, scripts/transcripts, timestamps, subtitles, videos, covers
│   ├── site/                 # Static HTML website (index + episode pages; <lang>/ per extra language)
│   ├── feed.xml              # RSS feed (feed-<lang>.xml per extra language)
│   ├── history.yml           # Episode history (dedup, per-language durations)
│   ├── uploads.yml           # Upload tracking (LingQ, YouTube, X)
│   ├── priority_links.yml    # Queued priority links
│   ├── excluded_urls.yml     # URLs excluded from future episodes
│   ├── research_cache/       # Cached source results (24h)
│   ├── debug/                # Raw script responses
│   └── run.lock              # Held while a generate runs
└── logs/
    ├── <name>/               # Run logs per podcast (token usage, warnings, phase timings)
    └── launchd_stderr.log    # Shared stderr of the scheduled jobs (publish markers, warnings)
```

## Development

```bash
bundle exec rake gate      # pre-commit gate: syntax + lint (standardrb; new files only — see .standard_todo.yml) + unit + offline integration
bundle exec rake test      # full suite (API-keyed tiers run only with keys present)
bundle exec rake test:unit # fast tier only
bundle exec rake health    # probe every registered external endpoint (network; see lib/source_registry.rb)
bundle exec rake fixtures:record  # re-record the network sources' test fixtures (network + keys; owner-run, never in the gate)
bundle exec ruby bin/podgen status  # OK/OLD/WARN per podcast; the daily check sends this output to Telegram, so log lines must stay secret-free
```

Owner-only commands (`publish`, `unpublish`, `uploads`, `tweet`, `schedule`,
`analytics`, and `generate --youtube/--lingq`) refuse to run inside a Claude
Code session (`CLAUDECODE=1`) with exit 2. Only `generate`, `publish`,
`unpublish` and `tweet` honour dry-run, so only their dry runs pass: the
global `podgen --dry-run <command>`, or `--dry-run` right after the podcast
name (`unpublish` takes the global flag only). `uploads`, `schedule` and
`analytics` ignore dry-run and are refused even with it. With `POSIXLY_CORRECT`
set the option parser stops at the first positional, so only the global flag
counts for `publish`/`tweet` under that variable. A `--dry-run` that
follows a bare option (`publish <pod> --date --dry-run`) may be swallowed as
that option's value, so it is refused. For `generate` the guard parses the
arguments with generate's own option list, so it refuses exactly what would
enable an upload: `--youtube`/`--lingq`, any prefix OptionParser expands
(`--you`, `--lin`), the single-dash completions `-y`/`-l`, and flags behind a
`--` that a value-taking option swallowed (`--title -- --you`). Arguments
generate's parser would reject are refused if any token looks like an upload
flag. To run
one deliberately from the Claude Code prompt: `! PODGEN_OWNER=1 bin/podgen publish <pod>`.

The gate is also what CI runs. Adding a hard-coded URL to a new
external host fails the gate until the host is registered in
`lib/source_registry.rb` (constant-built or interpolated URLs escape
the scanner — register those hosts manually). `podgen validate` includes a freshness
check: a podcast whose newest episode is older than ~2× its usual
cadence is flagged OLD (a stalled scheduled pipeline shows up here
rather than silently).

## Testing Individual Components

```bash
podgen test research       # Exa.ai search
podgen test rss            # RSS feed fetching
podgen test hn             # Hacker News search
podgen test claude_web     # Claude web search
podgen test bluesky        # Bluesky post search
podgen test x              # X (Twitter) search via SocialData
podgen test script         # Claude script generation
podgen test tts            # ElevenLabs TTS
podgen test assembly       # ffmpeg assembly
podgen test translation    # Claude script translation
podgen test transcription  # Transcription engines (podgen test transcription <podcast|file> [open|elab|groq|all])
podgen test sources        # Every configured source for a podcast
```

## Cost Estimate

Claude usage per news episode, as measured in the run log of a four-language episode on 2026-10-12 (all roles on the opus line unless noted; see `lib/claude_models.rb`):

| Stage | Calls | Input tokens | Output tokens |
| --- | --- | --- | --- |
| Topics | 1 | 0.7k | 0.3k |
| Script | 2 (one rewrite after a blocker) | 18k each | 8–9k each |
| Review | 2 | 23k each | 3–4k each |
| Translation | 1 per language | 2.9k | 9–14k |

The two short-output roles (description, language detection) run at low effort. The heavier roles were measured at low on real inputs (2026-10-12, one sample each) and stay at the API default: the reviewer returned a different set of findings, the Spanish translation read less fluently, and the script came out about 40% shorter than the configured length. `CLAUDE_EFFORT_<ROLE>=low` still lets you take that trade per role.

Multiply by the current price list of the resolved models. Other costs per episode:

- Exa.ai: ~$0.03 (4 searches + summaries)
- Claude web search source (haiku line): ~4 `web_search` calls per episode when enabled
- Hacker News: free (Algolia API)
- Bluesky: free (AT Protocol, requires account)
- X (Twitter) source: ~$0.01 (SocialData.tools, $0.0002/tweet); X announcements use the X API's pay-per-use credits
- RSS feeds: free
- ElevenLabs: varies by plan; each language is voiced separately

Every Claude call logs its token counts (`Input: … | Output: …`) in `logs/<podcast>/`, so the real numbers for your show are one grep away.

**Language pipeline** per episode:

- OpenAI transcription (gpt-4o-mini-transcribe): ~$0.01-0.03 depending on duration
- Claude (sonnet line, description cleanup/generation at low effort): a few thousand tokens per episode
- No TTS or research costs

## Tell — TTS Pronunciation Tool

`tell` is a standalone command-line tool for pronouncing text via TTS with automatic translation. Designed for language learning: type a word or phrase in your native language and hear it spoken in the target language.

### Prerequisites

- **Ruby 3.4+**
- At least one TTS API: [ElevenLabs](https://elevenlabs.io/) or [Google Cloud TTS](https://cloud.google.com/text-to-speech)
- At least one translation API: [DeepL](https://www.deepl.com/pro-api), [Anthropic](https://console.anthropic.com/) (Claude), or [OpenAI](https://platform.openai.com/)
- **Optional phonetic engines** (fall back to Claude AI if not installed):
  - **espeak-ng**: `brew install espeak-ng` — accurate IPA transcription for 36+ languages
  - **libicu**: ships with macOS (also `brew install icu4c`) — Cyrillic/Greek/Korean romanization via `ffi-icu` gem

### Setup

Create `~/.tell.yml`:

```yaml
original_language: en
target_language: sl
voice_id: "your_elevenlabs_voice_id"
tts_engine: elevenlabs              # elevenlabs | google
translation_engine: deepl           # deepl | claude | openai
```

Set API keys in your environment (or `.env` / `~/.env`):

```
ELEVENLABS_API_KEY=...    # Required for ElevenLabs TTS
DEEPL_AUTH_KEY=...        # Required for DeepL translation
```

Or use alternative engines:

```yaml
# Google TTS
tts_engine: google
voice_id: "sl-SI-Wavenet-A"
# Requires GOOGLE_API_KEY

# Claude translation
translation_engine: claude
# Requires ANTHROPIC_API_KEY

# OpenAI translation
translation_engine: openai
# Requires OPENAI_API_KEY
```

#### Per-language overrides

Use the `languages:` block to override settings for specific target languages (e.g. use ElevenLabs for Japanese where Google TTS struggles with kanji):

```yaml
tts_engine: google                  # Default: Google TTS
voice_id: "sl-SI-Chirp3-HD-Kore"

languages:
  ja:
    tts_engine: elevenlabs          # Japanese: use ElevenLabs instead
    voice_id: "japanese_voice_id"
  ko:
    voice_id: "korean_voice_id"     # Korean: different voice, same engine
```

Overrides are merged when the target language matches (via `-t` or `target_language`). CLI flags (`-e`, `-v`) take highest priority. When `-e` overrides the TTS engine to a different engine than the language block configures, voice settings from the language block are skipped (they'd be for the wrong engine).

#### Translation failover

Configure multiple engines as a failover chain — if the primary times out or fails, the next engine is tried automatically:

```yaml
translation_engine:
  - deepl
  - claude
```

The per-engine timeout defaults to 8 seconds (override with `TELL_TRANSLATE_TIMEOUT` env var or `translation_timeout` in config).

### Usage

Three input modes:

```bash
# Argument mode — translate and speak
tell "good morning"

# Pipe mode — read from stdin
echo "good morning" | tell

# Interactive mode — REPL with history (up/down arrows)
tell
```

In interactive mode, just start typing. History is saved to `~/.tell_history` (1000 entries) and supports up/down arrow navigation. New input interrupts any currently playing audio.

### How it works

1. **Auto-detects** the language of your input (Unicode script analysis + stop words)
2. If input is in your **native language** → translates to target language, prints translation, speaks it
3. If input is already in the **target language** → speaks it directly

```
$ tell "good morning"
SL: dobro jutro
[audio plays]

$ tell "dobro jutro"
[audio plays directly — already in target language]
```

**Explanation detection:** If a translation engine returns text much longer than the input (e.g. an LLM explanation instead of a translation), it's detected and shown with an error prefix — no speech, no add-ons. Thresholds are script-aware: 3x for Latin scripts, 8x for dense scripts (CJK, Hangul, Thai, Arabic, Hebrew, Devanagari) since they naturally expand 4-6x into European languages.

### Flags


| Flag                  | Description                                                 |
| --------------------- | ----------------------------------------------------------- |
| `-f, --from LANG`     | Override origin language (e.g. `en`)                        |
| `-t, --to LANG`       | Override target language (e.g. `ja`)                        |
| `-e, --engine NAME`   | Override TTS engine (`elevenlabs` or `google`)              |
| `-v, --voice ID`      | Override voice ID                                           |
| `-o, --output FILE`   | Save audio to file instead of playing                       |
| `-r, --reverse`       | Show reverse translation for target-language input          |
| `-g, --gloss [OPTS]`  | Grammatical gloss (`p`=phonetic, `r`=reverse, e.g. `-g pr`) |
| `-p, --phonetic`      | Show phonetic reading (kana/pinyin/romanization)            |
| `-s, --system SYSTEM` | Set phonetic system (e.g. `hepburn`, `pinyin`, `ipa`)       |
| `-n, --no-translate`  | Speak text as-is without translation                        |
| `-h, --help`          | Show help                                                   |


### Reverse translation

When you type text in the target language, use `-r` (or set `reverse_translate: true` in config) to see a translation back to your native language:

```
$ tell -r "dobro jutro"
EN: good morning
[audio plays]
```

### Grammatical glossing

Use `-g` to see word-by-word grammatical analysis (powered by Claude):

```
$ tell -g "dobro jutro"
GL: dobro(adj.n.sg.A) jutro(n.n.sg.A)
[audio plays]
```

Use `-g r` for glossing with translations:

```
$ tell -g r "dobro jutro"
GR: dobro(adj.n.sg.A)good jutro(n.n.sg.A)morning
[audio plays]
```

Glossing requires `ANTHROPIC_API_KEY`. The model defaults to the opus line of the model registry (`lib/claude_models.rb`; configure with `gloss_model` in `~/.tell.yml` or `TELL_GLOSS_MODEL` env).

Agrammatical forms are detected and marked: `*restavraciju*restavracijo(n.f.A.sg)restaurant` — the asterisks show the error and correction.

For more reliable error detection, use **multi-model consensus** — multiple models gloss in parallel, and a reconciler only keeps error markings where models agree:

```yaml
gloss_model:
  - opus
  - sonnet
```

This prevents over-correction (Opus) and missed errors (Sonnet) by requiring agreement from both models.

### Phonetic reading

Use `-p` to show phonetic readings alongside TTS playback:

```
$ tell -p "今日はいい天気です"
PH: きょう・わ・いい・てんき・です
[audio plays]

$ tell -p "dober dan"
PH: /ˈdɔːbəɾ ˈdaːn/
[audio plays]
```

Combine with gloss (`-g p`) for inline phonetic in grammatical analysis:

```
$ tell -g p "dober dan"
GL: dober[ˈdɔːbəɾ](adj.m.N.sg) dan[ˈdaːn](n.m.N.sg)
[audio plays]
```

Like `gloss_model`, `phonetic_model` accepts an array for multi-model consensus. Defaults to the first `gloss_model` (override with `phonetic_model` in config or `TELL_PHONETIC_MODEL` env).

#### Phonetic systems

Each language has multiple phonetic systems available. Use `--ps` to select one:

```
$ tell --ps hepburn -p "今日はいい天気です"
PH: kyō wa ii tenki desu
[audio plays]

$ tell --ps ipa -p "今日はいい天気です"
PH: /kjoɯ wa ii teɴki desɯ/
[audio plays]
```

Available systems per language (first is the default):


| Language                          | Systems                                | Engine               |
| --------------------------------- | -------------------------------------- | -------------------- |
| Japanese                          | `hiragana`, `hepburn`, `kunrei`, `ipa` | AI, Kana, Kana, Kana |
| Chinese                           | `pinyin`, `zhuyin`, `ipa`              | AI, AI, AI           |
| Korean                            | `rr`, `mr`, `ipa`                      | ICU, AI, eSpeak      |
| Arabic                            | `romanization`, `ipa`                  | AI, AI               |
| Thai                              | `rtgs`, `ipa`                          | AI, AI               |
| Georgian                          | `national`, `ipa`                      | AI, eSpeak           |
| Greek                             | `elot`, `ipa`                          | ICU, eSpeak          |
| Cyrillic (ru, uk, bg, sr, mk, be) | `scholarly`, `simple`, `ipa`           | ICU, ICU, eSpeak     |
| Indic (hi, sa, ne, mr)            | `iast`, `ipa`                          | AI, AI               |
| Hebrew (he, yi)                   | `standard`, `ipa`                      | AI, AI               |
| Other languages                   | `ipa`                                  | eSpeak or AI         |

Korean: `rr` = Revised Romanization, `mr` = McCune-Reischauer. "Other languages" covers eSpeak's 36 languages (falls back to AI when eSpeak isn't installed).


**Phonetic engine cascade:** Kana (Japanese hepburn/kunrei/IPA from AI hiragana) → eSpeak-ng (IPA, 36 langs) → ICU transliteration (Cyrillic/Greek/Korean) → Claude AI (everything else). Rule-based engines are faster, free, and more accurate than AI. eSpeak-ng and libicu are optional — if not installed, Claude handles everything.

Set a default in `~/.tell.yml`:

```yaml
phonetic_system: ipa          # global default
# or per-language:
phonetic_system:
  ja: hepburn
  zh: pinyin
```

Override via environment: `TELL_PHONETIC_SYSTEM=ipa`.

### Style hints

Append style suffixes to input text for formality and voice control:


| Suffix | Effect                                      |
| ------ | ------------------------------------------- |
| `/p`   | Polite/formal register                      |
| `/c`   | Casual/informal register                    |
| `/m`   | Use male voice (`voice_male` in config)     |
| `/f`   | Use female voice (`voice_female` in config) |


Combine freely: `/pm` = polite + male, `/cf` = casual + female.

```
$ tell "good morning /pm"
SL: dobro jutro
[audio plays with male voice, polite translation]
```

Voice switching requires `voice_male` and/or `voice_female` in `~/.tell.yml`.

### Advanced configuration

Full `~/.tell.yml` options:

```yaml
original_language: en               # Your native language (ISO 639-1)
target_language: sl                  # Language you're learning
voice_id: "elevenlabs_voice_id"     # TTS voice
voice_male: "elevenlabs_male_id"    # Optional: voice for /m hint
voice_female: "elevenlabs_female_id" # Optional: voice for /f hint
tts_engine: elevenlabs              # elevenlabs | google
translation_engine: deepl           # deepl | claude | openai (or array)
tts_model_id: eleven_multilingual_v2    # ElevenLabs model
output_format: mp3_44100_128        # ElevenLabs output format
reverse_translate: false            # Always show reverse translation
gloss: false                        # Always show grammatical gloss
phonetic: false                     # Always show phonetic reading
gloss_model: opus                    # opus | sonnet | haiku (or array for multi-model consensus)
# gloss_model:                      # multi-model consensus example
#   - opus
#   - sonnet
phonetic_model: opus                 # opus | sonnet | haiku (or array for multi-model consensus; default: first gloss_model)
phonetic_system: ipa                 # Default phonetic system (or hash of lang→system)
translation_timeout: 8.0            # Per-engine timeout (seconds)

# Per-language overrides (merged when target language matches):
# languages:
#   ja:
#     tts_engine: elevenlabs        # Use ElevenLabs for Japanese
#     voice_id: "japanese_voice_id"
#   ko:
#     voice_id: "korean_voice_id"

# API keys (can also be set via environment variables)
# deepl_auth_key: "..."            # or DEEPL_AUTH_KEY env
# anthropic_api_key: "..."         # or ANTHROPIC_API_KEY env
# openai_api_key: "..."            # or OPENAI_API_KEY env
# elevenlabs_api_key: "..."        # or ELEVENLABS_API_KEY env
# google_api_key: "..."            # or GOOGLE_API_KEY env
```

The `languages:` block lets you override any top-level setting per target language. When you use `-t ja`, settings from `languages.ja` are merged on top of the defaults. CLI flags (`-e`, `-v`) still take highest priority. When `-e` selects a different TTS engine than the language block specifies, voice settings (`voice_id`, `voice_male`, `voice_female`) from the language block are skipped — they'd be for the wrong engine.

Overridable keys per language: `tts_engine`, `voice_id`, `voice_male`, `voice_female`, `tts_model_id`, `output_format`, `translation_engine`, `phonetic_system`.

### Environment variables

Tell loads `.env` from the code root and `~/.env`. Available variables:


| Variable                 | Description                                             |
| ------------------------ | ------------------------------------------------------- |
| `ELEVENLABS_API_KEY`     | ElevenLabs TTS                                          |
| `GOOGLE_API_KEY`         | Google Cloud TTS                                        |
| `DEEPL_AUTH_KEY`         | DeepL translation                                       |
| `ANTHROPIC_API_KEY`      | Claude translation + glossing                           |
| `OPENAI_API_KEY`         | OpenAI translation                                      |
| `CLAUDE_TELL_TRANSLATE_MODEL` | Claude model for translation (default: the sonnet line in lib/claude_models.rb; `CLAUDE_SONNET_MODEL` overrides the line) |
| `OPENAI_TRANSLATE_MODEL` | OpenAI model for translation (default: gpt-4o-mini)     |
| `TELL_TRANSLATE_TIMEOUT` | Per-engine timeout in seconds (default: 8)              |
| `TELL_GLOSS_MODEL`       | Override gloss_model config                             |
| `TELL_PHONETIC_MODEL`    | Override phonetic_model config                          |
| `TELL_PHONETIC_SYSTEM`   | Override phonetic_system config                         |


### Supported languages

`tell` auto-detects 30+ languages including: Arabic, Chinese, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Hebrew, Hindi, Hungarian, Indonesian, Italian, Japanese, Korean, Latvian, Lithuanian, Norwegian, Polish, Portuguese, Romanian, Russian, Serbian, Slovak, Slovenian, Spanish, Swedish, Thai, Turkish, Ukrainian, Vietnamese.

### Examples

```bash
# Quick translation + pronunciation
tell "How are you?"

# Override target language on the fly
tell -t ja "good morning"

# Save pronunciation to file
tell -o morning.mp3 "good morning"

# Pipe text through tell
echo "I love programming" | tell

# Speak without translating (already in target language)
tell -n "dobro jutro"

# Interactive mode with reverse translation and glossing
tell -r -g r
```

### Web UI

Tell also ships a browser-based interface with the same features as the CLI:

```bash
ruby scripts/tell_web.rb        # http://localhost:9090
ruby scripts/tell_web.rb 8080   # custom port
```

Features:

- **Real-time streaming** — translation, audio, reverse, phonetic, and gloss results stream in via SSE as they become available
- **Addon pills** — toggle reverse, phonetic, gloss, +words (inline phonetic), +trans independently. State persists across page reloads
- **Phonetic system selector** — dropdown per target language (e.g. Hiragana/Hepburn/IPA for Japanese). Results cached per system to avoid re-calling AI on switch
- **Style hint pills** — polite/casual, male/female voice
- **Language selector** — swap languages, auto-detect source language
- **History** — last 50 phrases, click to replay

**Endpoints:**

- `GET /` — HTML page with textarea, addon/style pills, language selectors, audio playback
- `GET /speak?text=...` — SSE stream with events: `translation`, `audio` (base64), `speak_text`, `reverse`, `phonetic`, `gloss`/`gloss_translate`, `error`, `done`
- `GET /systems?lang=xx` — JSON array of `{key, label, separator}` for phonetic system dropdown

**SSE params:** `text`, `from`, `to`, `hint`, `reverse`, `phonetic`, `gloss`, `gloss_phonetic`, `gloss_translate`, `phonetic_system`, `no_tts`, `no_translate`, `token`

Optional security: set `TELL_WEB_TOKEN` to require authentication (pass as `?token=...` URL param or `Authorization: Bearer ...` header). Rate limited to 30 requests/minute per IP by default (`TELL_WEB_RATE_LIMIT`).

Environment variables: `TELL_WEB_PORT` (default 9090), `TELL_WEB_BIND` (default localhost), `TELL_WEB_TOKEN`, `TELL_WEB_RATE_LIMIT`.

### Cost

- **DeepL translation**: Free tier available (500k chars/month)
- **Claude translation**: ~$0.001 per phrase (Sonnet)
- **OpenAI translation**: ~$0.0001 per phrase (gpt-4o-mini)
- **ElevenLabs TTS**: varies by plan
- **Google TTS**: $4 per 1M characters (Standard), $16 per 1M characters (WaveNet)
- **Glossing**: ~$0.01 per phrase (Claude Opus, default; ~$0.001 with Sonnet, ~$0.0005 with Haiku)

