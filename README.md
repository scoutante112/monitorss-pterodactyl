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
4. Under OAuth2 → Redirects add: `http://YOUR_SERVER_IP:8000/api/v1/discord/callback-v2`

### 3. Create the server in Pterodactyl

Use the imported egg and fill in the variables:

| Variable | How to get it |
|----------|--------------|
| Discord Bot Token | Developer Portal → Bot |
| Discord Client ID | Developer Portal → General |
| Discord Client Secret | Developer Portal → OAuth2 |
| Login Redirect URI | `http://YOUR_SERVER_IP:8000` |
| Discord OAuth2 Redirect URI | `http://YOUR_SERVER_IP:8000/api/v1/discord/callback-v2` |
| Session Secret | `openssl rand -hex 32` |
| Session Salt | `openssl rand -hex 8` |

### 4. Open port 8000

Make sure port **8000** (or whatever you set `BACKEND_API_PORT` to) is allocated in Pterodactyl and open in your firewall.

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

## Minimum requirements

| Resource | Recommended |
|----------|-------------|
| RAM | 2 GB |
| Disk | 5 GB |
| CPU | 2 cores |
