# monitorss-pterodactyl

All-in-one [MonitoRSS](https://github.com/synzen/MonitoRSS) egg for [Pterodactyl Panel](https://pterodactyl.io).

Runs the entire MonitoRSS stack – MongoDB, PostgreSQL, RabbitMQ, Redis and all Node.js services – inside a single Pterodactyl server.

The Docker image is built and pushed automatically to GHCR via GitHub Actions on every push to `main`.

---

## Quick start

### 1. Import the egg

1. Go to **Admin → Nests → Import Egg** in your Pterodactyl panel
2. Upload [`egg-monitorss.json`](egg-monitorss.json)

### 2. Create your Discord application

1. Open [discord.com/developers/applications](https://discord.com/developers/applications)
2. Create a new application and bot
3. Note down: **Bot Token**, **Client ID**, **Client Secret**
4. Under **OAuth2 → Redirects** add: `https://yourdomain.com/api/v1/discord/callback-v2`

> **A domain name is required.**  
> Discord no longer supports raw IP addresses in OAuth2 redirect URIs — you must use a domain name. Point a domain or subdomain at your server and use that in all redirect URI fields.  
> Free options if you don't have a domain: [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) or [DuckDNS](https://www.duckdns.org/).

### 3. Create the server in Pterodactyl

Use the imported egg and fill in the variables. The ones marked **Required** must be set for the bot to work.

| Variable | Required | Description |
|----------|----------|-------------|
| Discord Bot Token | ✅ Required | Developer Portal → Bot |
| Discord Client ID | ✅ Required | Developer Portal → General Information |
| Discord Client Secret | ✅ Required | Developer Portal → OAuth2 |
| Login Redirect URI | ✅ Required | Your domain, e.g. `https://yourdomain.com` |
| Discord OAuth2 Redirect URI | ✅ Required | `https://yourdomain.com/api/v1/discord/callback-v2` |
| Session Secret | ✅ Required | Run `openssl rand -hex 32` to generate |
| Session Salt | ✅ Required | Run `openssl rand -hex 8` to generate |
| Backend API Port | ✅ Required | Port the web UI listens on (default `8000`) |
| Contact Email | Optional | Added to HTTP User-Agent so feed hosts can reach you |
| Bot Status | Optional | `online`, `idle`, `dnd`, `invisible` (default `online`) |
| Bot Activity Type | Optional | `playing`, `listening`, `watching`, etc. |
| Bot Activity Name | Optional | Text shown in bot activity, e.g. `with RSS feeds` |
| Bot Stream URL | Optional | Twitch/YouTube URL (only for `streaming` activity) |
| SMTP Host | Optional | Email notifications — requires all four SMTP fields |
| SMTP Username | Optional | SMTP username / email address |
| SMTP Password | Optional | SMTP password |
| SMTP From Address | Optional | Sender address shown on notification emails |
| Reddit Client ID | Optional | Reddit feed auth — requires all three Reddit fields |
| Reddit Client Secret | Optional | Reddit app secret |
| Reddit Redirect URI | Optional | `https://yourdomain.com/api/v1/reddit/callback` |
| Encryption Key (hex) | Optional | 64-char hex key for encryption. Auto-generated and saved on first start if left empty. Set your own with `openssl rand -hex 32` if you prefer. |

### 4. Open the port

Make sure the port you set in `BACKEND_API_PORT` (default `8000`) is allocated in Pterodactyl and open in your firewall.

---

## What's inside the image

| Component | Version |
|-----------|---------|
| Node.js | 24 |
| MongoDB | 8.0 (replica set) |
| PostgreSQL | 17 |
| RabbitMQ | latest |
| Redis | 7 |
| MonitoRSS services | latest `main` branch |

Services managed by **supervisord**:
- `bot-presence`
- `discord-rest-listener`
- `feed-requests`
- `user-feeds-next`
- `schedule-emitter`
- `monolith` (web UI + REST API)

---

## Data persistence

All data is stored in `/home/container/data/` which Pterodactyl keeps between restarts:

```
/home/container/data/
├── mongodb/
├── postgresql/
├── rabbitmq/
└── redis/
```

---

## Logs

Service logs are written to `/var/log/monitorss/` inside the container.

---

## Updating

The GitHub Actions workflow rebuilds the image on every push to `main`.  
To update your Pterodactyl server pull the new image and restart the server.

---

## Contributing

Contributions are welcome! Feel free to open a pull request if you have improvements, new features, or fixes you'd like to add.

Found a bug? Please [open an issue](../../issues) — include the console output from Pterodactyl and a description of what went wrong. It helps a lot.

Built with assistance from AI tooling ([Claude](https://claude.ai)).

---

## Minimum requirements

| Resource | Recommended |
|----------|-------------|
| RAM | 2 GB |
| Disk | 5 GB |
| CPU | 2 cores |
