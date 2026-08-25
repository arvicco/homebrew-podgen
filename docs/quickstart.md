# Quickstart: your first news podcast

Setting up a podgen news podcast from scratch, assuming zero podgen knowledge.

## 1. Install podgen (macOS)

```bash
brew tap arvicco/podgen
brew install podgen
```

This creates a project skeleton at `~/.podgen`. System tools `ffmpeg` and
`imagemagick` come in as dependencies; install via brew if missing.

## 2. Get three API keys

The news pipeline needs all three:

| Service    | Used for           | Where                 |
| ---------- | ------------------ | --------------------- |
| Anthropic  | writing the script | console.anthropic.com |
| Exa.ai     | researching news   | exa.ai                |
| ElevenLabs | text-to-speech     | elevenlabs.io         |

Put them in `~/.podgen/.env`:

```
ANTHROPIC_API_KEY=sk-ant-...
EXA_API_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...   # pick a voice at elevenlabs.io/app/voice-library
```

## 3. Describe your podcast

Create `~/.podgen/podcasts/mypod/guidelines.md` — this one markdown file
*is* the podcast. Minimal working example:

```markdown
## Podcast
- name: My Tech News
- author: Your Name
- language:
  - en

## Format
- Target length: 8–10 minutes
- Open with a short news brief, then three segments of ~3 minutes

## Tone
Conversational and direct, like a smart friend explaining the news.
No filler, no "stay tuned", no forced enthusiasm.

## Topics (default rotation — override with queue.yml)
- Latest AI developments
- Open source projects worth knowing
- Anything big in consumer tech

## Sources
- exa
- hackernews
```

The `## Format`, `## Tone`, and `## Topics` sections are free-form
instructions to the script writer — write what you want, in plain English.
`## Sources` controls where research comes from (`exa`, `hackernews`,
`rss:` feed URLs, `bluesky`, `x: @handles`).

## 4. Check and run

```bash
podgen validate mypod    # catches config typos before spending API money
podgen generate mypod    # research → script → voice → final MP3
```

The episode lands in `~/.podgen/output/mypod/episodes/` as
`mypod-<date>.mp3` with the script alongside. Listen, tweak guidelines.md,
regenerate with `podgen generate mypod --force` until you like it.

## 5. When you're happy (all optional)

- `podgen rss mypod` / `podgen site mypod` — RSS feed + static website
- `podgen publish mypod` — upload to Cloudflare R2 (needs R2 keys in `.env`)
- `podgen schedule mypod` — install a launchd job that generates an episode
  daily, hands-off

That's the whole loop: one markdown file describes the show, one command
produces an episode.
