# Cloudflare Setup Guide

Complete setup for hosting podcasts on Cloudflare R2 with a custom domain and download analytics.

## 1. Cloudflare Account

1. Sign up at [dash.cloudflare.com](https://dash.cloudflare.com)
2. Add your domain: **Websites > Add a site** > follow DNS transfer instructions
3. Wait for DNS propagation (nameservers must point to Cloudflare)

## 2. R2 Storage

R2 is Cloudflare's S3-compatible object storage. Free tier: 10 GB storage, 10 million reads/month. Podgen uses R2 as the file store — a Cloudflare Worker serves files publicly (set up in step 4).

### Create a bucket

1. **R2 Object Storage > Create bucket**
2. Name it (e.g. `podgen`)
3. Location: Automatic (or pick a region close to your audience)

No public access settings needed on the bucket — the Worker handles public serving.

### Create an API token

Used by rclone to upload files:

1. **R2 Object Storage > Manage R2 API Tokens > Create API Token**
2. Permissions: **Object Read & Write**
3. Scope: specific bucket or all buckets
4. Copy the **Access Key ID** and **Secret Access Key** (shown once)

### Configure podgen

Add to your root `.env`:

```
R2_ACCESS_KEY_ID=your_access_key_id
R2_SECRET_ACCESS_KEY=your_secret_access_key
R2_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com
R2_BUCKET=podgen
```

Find your account ID: **R2 Object Storage** page, right sidebar, or the URL `dash.cloudflare.com/<account_id>/r2`.

### Install rclone

```bash
brew install rclone
```

No `rclone config` needed — podgen passes credentials via environment variables.

## 3. Custom Domain

Set `base_url` in `podcasts/<name>/guidelines.md` under `## Podcast`:

```markdown
## Podcast
- name: My Podcast
- base_url: https://media.example.com/my_podcast
```

The `base_url` is used in RSS feed enclosure URLs, site links, and cover art references. It should match the custom domain + bucket path structure: `https://<custom_domain>/<podcast_name>`.

The DNS record for this domain is created in step 4 when setting up the Worker.

## 4. Analytics Worker

A Cloudflare Worker serves files from R2 on your custom domain and logs MP3 downloads to Analytics Engine. Adds ~1ms latency. Podgen automates the entire setup.

### Install wrangler

One-time — wrangler is Cloudflare's CLI:

```bash
brew install cloudflare-wrangler2
# or: npm install -g wrangler

wrangler login
# Opens browser for authorization
```

### Enable Analytics Engine

One-time — must be done in the dashboard (no CLI for it):

1. **Compute > Workers & Pages** (left sidebar), then click the **Analytics Engine** tab at the top, or go directly to `dash.cloudflare.com/<account_id>/workers/analytics-engine`
2. Click **Create Dataset > Create Blank Dataset > Select**

You don't need to name it — the Worker deployment creates the `podgen_downloads` dataset automatically. Just having Analytics Engine enabled is enough.

If you skip this step, deploy will fail with error code 10089.

### Deploy

```bash
podgen analytics setup
```

Prompts for:
- **Media domain** — e.g. `media.example.com`
- **Zone name** — e.g. `example.com` (your root domain in Cloudflare)
- **R2 bucket** — auto-read from `R2_BUCKET` in `.env`, or prompted

Creates the Worker project at `~/.podgen/analytics-worker/`, generates the config and JS, and deploys via `wrangler deploy`.

### Add DNS record

After deploy, point your custom domain to Cloudflare's edge:

1. **Cloudflare dashboard > DNS > Records > Add record**
2. Type: **AAAA**
3. Name: `media` (the subdomain part of your media domain)
4. Content: `100::`
5. Proxy status: **Proxied** (orange cloud ON)
6. Click **Save**

The `100::` is a placeholder — the Worker serves all requests from R2, so no real origin is needed. Cloudflare replaces it with its own edge IPs when proxied.

### Publish and verify

```bash
# Upload episodes, feed, and site to R2
podgen publish my_podcast

# Should return 200 with cf-ray header
curl -I https://media.example.com/my_podcast/feed.xml

# Live Worker logs (streams to terminal, Ctrl+C to stop)
podgen analytics tail
```

### Redeploy after changes

The Worker source is at `~/.podgen/analytics-worker/src/index.js`. After editing:

```bash
podgen analytics deploy
```

Changes are live in seconds globally.

## 5. Querying Analytics

### Cloudflare Dashboard

**Compute > Workers & Pages > podgen-analytics** shows Worker metrics (requests, errors, latency).

### podgen stats --downloads

```bash
# All podcasts — totals, avg/day, top countries, top apps
podgen stats --downloads

# Single podcast — episodes, countries, apps, daily breakdown
podgen stats --downloads fulgur_news

# Custom lookback period
podgen stats --downloads fulgur_news --days 7
```

Example output:

```
Downloads (last 30 days)

  Podcast                 Total  Avg/day
  fulgur_news                15     15.0
  lahko_noc                   2      2.0
                       ──────── ────────
  Total                      17     17.0

  Countries:
    CH         13
    US          4

  Apps:
    Pocket Casts                 12
    Browser (Chrome)              3
```

### SQL API

Under the hood, podgen queries the [Analytics Engine SQL API](https://developers.cloudflare.com/analytics/analytics-engine/sql-api/). You can also query directly:

```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/analytics_engine/sql" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -d "SELECT blob1 AS episode, SUM(double1) AS downloads
      FROM podgen_downloads
      WHERE index1 = 'my_podcast'
        AND timestamp >= NOW() - INTERVAL '30' DAY
      GROUP BY episode
      ORDER BY downloads DESC
      LIMIT 20"
```

### Create a CF API token for querying

1. **My Profile > API Tokens > Create Token**
2. Use template: **Custom token**
3. Permissions: **Account > Account Analytics > Read**
4. Save the token

Add to your root `.env`:

```
CLOUDFLARE_API_TOKEN=your_api_token
CLOUDFLARE_ACCOUNT_ID=your_account_id
```

Find your account ID: it's the hex string in your dashboard URL (`dash.cloudflare.com/<account_id>/...`), or on any domain overview page under "Account ID" in the right sidebar.

## 6. Analytics Data Schema

Each MP3 download logs one data point:

| Field | Analytics Engine slot | Content |
|-------|----------------------|---------|
| Podcast | `index1` | Podcast name (from URL path) |
| Episode | `blob1` | Episode filename (without `.mp3`) |
| User-Agent | `blob2` | Podcast app / browser (parsed into app names by podgen) |
| Country | `blob3` | Two-letter country code (from CF edge) |
| Referer | `blob4` | Referring URL (if any) |
| Count | `double1` | Always `1` (sum for totals, count for avg/day) |

Analytics Engine retains data for **90 days** on the free plan.

## Troubleshooting

### DNS not resolving after adding the AAAA record

If `curl` can't resolve the host but `dig media.example.com @1.1.1.1` returns IPs, your local or router DNS is caching a stale response. Try:

1. Flush macOS DNS cache: `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`
2. If that doesn't help, reboot your router (it has its own DNS cache)
3. Verify directly: `curl -I --resolve media.example.com:443:$(dig media.example.com @1.1.1.1 A +short | head -1) https://media.example.com/my_podcast/feed.xml`

### Migrating from R2 custom domain to Worker

If you previously used R2's built-in custom domain (R2 > bucket > Settings > Custom Domains) and are switching to the Worker:

1. **First** add the AAAA record (step 4 above)
2. **Then** remove the R2 custom domain (R2 > bucket > Settings > Custom Domains > Remove)

**Do NOT remove the R2 custom domain first.** It deletes the DNS record, and resolvers cache the negative (NXDOMAIN) response — your domain will appear down for minutes to hours even after adding the new record.

### `podgen analytics setup` fails with error 10089

Analytics Engine is not enabled. See "Enable Analytics Engine" in step 4.

## Reference

### File structure on R2

```
podgen/                          # R2 bucket
  my_podcast/                    # One directory per podcast
    feed.xml                     # Main RSS feed
    feed-ja.xml                  # Per-language feed variants
    cover.jpg                    # Podcast cover art
    episodes/
      my_podcast-2025-01-15.mp3
      my_podcast-2025-01-15.html # Transcript
    site/
      index.html                 # Episode list
      style.css
      custom.css
      favicon.ico
      episodes/
        my_podcast-2025-01-15.html
```

### Environment variables

| Variable | Purpose |
|----------|---------|
| `R2_ACCESS_KEY_ID` | R2 API token access key (for rclone uploads) |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret key |
| `R2_ENDPOINT` | `https://<account_id>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | Bucket name (e.g. `podgen`) |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token (for analytics queries) |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account ID |

### Commands

```bash
# Publish podcast to R2
podgen publish my_podcast

# Dry-run (preview what would sync)
podgen --dry-run publish my_podcast

# Set up analytics Worker (one-time, interactive)
podgen analytics setup

# Redeploy Worker after editing ~/.podgen/analytics-worker/src/index.js
podgen analytics deploy

# Live Worker logs
podgen analytics tail

# Show Worker config
podgen analytics status
```

### Costs

All within free tiers for typical podcast usage:

- **R2**: 10 GB storage, 10M reads/month, 1M writes/month
- **Workers**: 100k requests/day
- **Analytics Engine**: 100k data points/day, 90-day retention
