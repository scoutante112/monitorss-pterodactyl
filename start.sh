#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# MonitoRSS – Pterodactyl all-in-one startup script
# Runs as the unprivileged 'container' user (no root/chown/gosu needed).
# ---------------------------------------------------------------------------

# Set HOME early so Erlang/RabbitMQ writes .erlang.cookie to a writable path
# instead of trying to write to / (read-only in Pterodactyl).
export HOME=/home/container

# ---------------------------------------------------------------------------
# Fix missing /etc/passwd entry – Pterodactyl runs with arbitrary UIDs that
# don't exist in the image. Tools like initdb require a valid passwd entry.
# libnss-wrapper injects a fake one for the current UID at runtime.
# ---------------------------------------------------------------------------
if ! getent passwd "$(id -u)" > /dev/null 2>&1; then
    NSS_LIB=$(find /usr/lib -name "libnss_wrapper.so" 2>/dev/null | head -1)
    if [ -n "$NSS_LIB" ]; then
        # Report username as "rabbitmq" so rabbitmq-server's user check passes
        # (it allows root or rabbitmq; this makes id -un return "rabbitmq").
        echo "rabbitmq:x:$(id -u):$(id -g):rabbitmq:/home/container:/bin/sh" > /tmp/nss_passwd
        cp /etc/group /tmp/nss_group 2>/dev/null || echo "rabbitmq:x:$(id -g):" > /tmp/nss_group
        export LD_PRELOAD="$NSS_LIB"
        export NSS_WRAPPER_PASSWD=/tmp/nss_passwd
        export NSS_WRAPPER_GROUP=/tmp/nss_group
        echo "[init] NSS wrapper active for uid=$(id -u) (reported as rabbitmq)"
    fi
fi

DATA_DIR="${DATA_DIR:-/home/container/data}"
LOG_DIR="/home/container/logs"

MONGO_DATA="$DATA_DIR/mongodb"
PG_DATA="$DATA_DIR/postgresql"
RABBITMQ_DATA="$DATA_DIR/rabbitmq"
REDIS_DATA="$DATA_DIR/redis"

mkdir -p "$MONGO_DATA" "$PG_DATA" "$RABBITMQ_DATA" "$REDIS_DATA" "$LOG_DIR"

# ---------------------------------------------------------------------------
# PostgreSQL – initialise cluster as current user (no gosu/chown needed)
# ---------------------------------------------------------------------------
if [ ! -f "$PG_DATA/PG_VERSION" ]; then
    echo "[init] Initialising PostgreSQL data directory..."
    /usr/lib/postgresql/17/bin/initdb \
        -D "$PG_DATA" \
        --encoding=UTF8 \
        --locale=C \
        --username=postgres

    # Replace pg_hba.conf with trust auth so we can connect over TCP
    # without a password from any OS user.
    cat > "$PG_DATA/pg_hba.conf" << 'EOF'
local   all   all              trust
host    all   all   127.0.0.1/32   trust
host    all   all   ::1/128        trust
EOF

    # Use /tmp for the unix socket – /var/run/postgresql is owned by postgres (uid 105)
    # and not writable by Pterodactyl's container user.
    echo "unix_socket_directories = '/tmp'" >> "$PG_DATA/postgresql.conf"
fi

# Force socket directory to /tmp (overrides any value in postgresql.conf).
# /var/run/postgresql is read-only in Pterodactyl containers.
sed -i "s|#\?unix_socket_directories\s*=.*|unix_socket_directories = '/tmp'|" "$PG_DATA/postgresql.conf"

# ---------------------------------------------------------------------------
# Start infrastructure services in the background
# ---------------------------------------------------------------------------
# Clear stale MongoDB lock file from previous container run
rm -f "$MONGO_DATA/mongod.lock" "$MONGO_DATA/WiredTiger.lock"

echo "[start] Starting MongoDB..."
mongod \
    --dbpath "$MONGO_DATA" \
    --replSet dbrs \
    --bind_ip_all \
    --logpath "$LOG_DIR/mongo.log" \
    --pidfilepath /tmp/mongod.pid \
    --fork

# Always remove the PostgreSQL PID file – it is always stale in a fresh container.
# The persistent volume keeps it from previous runs but those processes are gone.
rm -f "$PG_DATA/postmaster.pid"
echo "[init] Cleared stale PostgreSQL PID file (if any)"

echo "[start] Starting PostgreSQL..."
/usr/lib/postgresql/17/bin/pg_ctl start \
    -D "$PG_DATA" \
    -l "$LOG_DIR/postgresql.log" \
    -o "-k /tmp" \
    -w || {
    echo "[error] PostgreSQL failed to start! Log:"
    cat "$LOG_DIR/postgresql.log" 2>/dev/null || echo "(log file not found)"
    exit 1
}

echo "[start] Starting Redis..."
redis-server \
    --daemonize yes \
    --dir "$REDIS_DATA" \
    --logfile "$LOG_DIR/redis.log" \
    --save 60 1

echo "[start] Starting RabbitMQ (generic Unix binary)..."
# Static node name so Mnesia DB is always compatible across container restarts
export RABBITMQ_NODENAME="rabbit@localhost"
export RABBITMQ_USE_LONGNAME="false"
export RABBITMQ_MNESIA_BASE="$RABBITMQ_DATA"
export RABBITMQ_LOG_BASE="$LOG_DIR"
export RABBITMQ_PID_FILE="/tmp/rabbitmq.pid"
export RABBITMQ_HOME="/usr/local/rabbitmq"
# Fixed Erlang cookie so epmd can always reconnect
ERLANG_COOKIE="monitorss-pterodactyl-cookie"
rm -f "$HOME/.erlang.cookie"
echo "$ERLANG_COOKIE" > "$HOME/.erlang.cookie"
chmod 600 "$HOME/.erlang.cookie"
export RABBITMQ_ERLANG_COOKIE="$ERLANG_COOKIE"

# Write rabbitmq.conf to the writable data dir so RabbitMQ can find it.
# We bind both IPv4 (0.0.0.0) and IPv6 ([::]) so Node.js can connect
# via 127.0.0.1 regardless of net.ipv6.bindv6only kernel setting.
cat > "$RABBITMQ_DATA/rabbitmq.conf" << 'EOF'
listeners.tcp.1 = 0.0.0.0:5672
EOF
export RABBITMQ_CONFIG_FILE="$RABBITMQ_DATA/rabbitmq.conf"
echo "[init] RabbitMQ config written to $RABBITMQ_DATA/rabbitmq.conf"

# Run without -detached so stdout/stderr are captured (backgrounded with nohup &).
# -detached forks a child Erlang VM whose output escapes our redirect.
nohup rabbitmq-server > "$RABBITMQ_DATA/rabbitmq-boot.log" 2>&1 &
RABBITMQ_BG_PID=$!
echo "[init] RabbitMQ background PID: $RABBITMQ_BG_PID"
sleep 10
if kill -0 $RABBITMQ_BG_PID 2>/dev/null; then
    echo "[init] RabbitMQ process still alive"
else
    echo "[error] RabbitMQ process already exited! Boot log:"
    cat "$RABBITMQ_DATA/rabbitmq-boot.log" 2>/dev/null || echo "(empty)"
    echo "[debug] Erlang crash dump (if any):"
    find /home/container /tmp /usr/local/rabbitmq -name "erl_crash.dump" 2>/dev/null \
        | head -3 | xargs -I{} head -30 {} 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Wait for services to become ready
# ---------------------------------------------------------------------------
echo "[wait] Waiting for MongoDB..."
until mongosh --quiet --eval "db.adminCommand('ping')" &>/dev/null 2>&1; do
    sleep 1
done

echo "[wait] Waiting for PostgreSQL..."
until /usr/lib/postgresql/17/bin/pg_isready -h 127.0.0.1 -U postgres &>/dev/null 2>&1; do
    sleep 1
done

echo "[wait] Waiting for RabbitMQ AMQP port (5672)..."
AMQP_WAIT=0
until bash -c 'echo > /dev/tcp/127.0.0.1/5672' 2>/dev/null; do
    sleep 2
    AMQP_WAIT=$((AMQP_WAIT + 2))
    if [ "$AMQP_WAIT" -ge 120 ]; then
        echo "[warn] RabbitMQ AMQP port not ready after 120s."
        echo "[debug] rabbitmq-server boot output:"
        cat /tmp/rabbitmq-boot.log 2>/dev/null || echo "(no boot log)"
        echo "[debug] RabbitMQ main log (last 30 lines):"
        cat "$LOG_DIR/rabbit@localhost.log" 2>/dev/null | tail -30 || echo "(no log)"
        echo "[debug] RabbitMQ config used:"
        cat "$RABBITMQ_DATA/rabbitmq.conf" 2>/dev/null || echo "(no conf)"
        echo "[debug] Processes with 'rabbit':"
        ps aux 2>/dev/null | grep rabbit | grep -v grep || echo "(none)"
        echo "[warn] Proceeding anyway..."
        break
    fi
done
echo "[wait] RabbitMQ AMQP port is ready"

# ---------------------------------------------------------------------------
# Initialise MongoDB replica set
# ---------------------------------------------------------------------------
REPLICA_STATUS=$(mongosh --quiet --eval "try { rs.status().ok } catch(e) { 0 }" 2>/dev/null || echo "0")
if [ "$REPLICA_STATUS" != "1" ]; then
    echo "[init] Initialising MongoDB replica set..."
    mongosh --quiet --eval "
        rs.initiate({
            _id: 'dbrs',
            members: [{ _id: 0, host: 'localhost:27017' }]
        })
    "
    echo "[wait] Waiting for replica set primary..."
    until mongosh --quiet --eval "rs.isMaster().ismaster" 2>/dev/null | grep -q "true"; do
        sleep 2
    done
else
    echo "[init] MongoDB replica set already initialised."
fi

# ---------------------------------------------------------------------------
# Create PostgreSQL databases
# ---------------------------------------------------------------------------
echo "[init] Creating PostgreSQL databases if they do not exist..."
psql -h 127.0.0.1 -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='feedrequests'" \
    | grep -q 1 \
    || psql -h 127.0.0.1 -U postgres -c "CREATE DATABASE feedrequests;"

psql -h 127.0.0.1 -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='userfeeds'" \
    | grep -q 1 \
    || psql -h 127.0.0.1 -U postgres -c "CREATE DATABASE userfeeds;"

# ---------------------------------------------------------------------------
# Run database migrations
# ---------------------------------------------------------------------------
export NODE_ENV="${NODE_ENV:-production}"

echo "[migrate] Running feed-requests migrations..."
cd /app/services/feed-requests
export FEED_REQUESTS_POSTGRES_URI="${FEED_REQUESTS_POSTGRES_URI:-postgres://postgres@127.0.0.1:5432/feedrequests}"
export FEED_REQUESTS_POSTGRES_SCHEMA="${FEED_REQUESTS_POSTGRES_SCHEMA:-feedrequests}"
export FEED_REQUESTS_API_KEY="${FEED_REQUESTS_API_KEY:-feed-requests-api-key}"
export FEED_REQUESTS_API_PORT="${FEED_REQUESTS_API_PORT:-5000}"
export FEED_REQUESTS_RABBITMQ_BROKER_URL="${FEED_REQUESTS_RABBITMQ_BROKER_URL:-amqp://guest:guest@localhost:5672}"
export FEED_REQUESTS_REDIS_URI="${FEED_REQUESTS_REDIS_URI:-redis://localhost:6379}"
export FEED_REQUESTS_REDIS_DISABLE_CLUSTER=true
_UA_BASE="MonitoRSS [Self-Hosted]/1.0"
if [ -n "$CONTACT_EMAIL" ]; then
    _UA_BASE="$_UA_BASE $CONTACT_EMAIL"
fi
export FEED_REQUESTS_FEED_REQUEST_DEFAULT_USER_AGENT="${FEED_REQUESTS_FEED_REQUEST_DEFAULT_USER_AGENT:-$_UA_BASE}"
export FEED_REQUESTS_FEEDS_MONGODB_URI="${FEED_REQUESTS_FEEDS_MONGODB_URI:-mongodb://localhost:27017/rss?replicaSet=dbrs&directConnection=true}"
export FEED_REQUESTS_HISTORY_PERSISTENCE_MONTHS="${FEED_REQUESTS_HISTORY_PERSISTENCE_MONTHS:-1}"
export FEED_REQUESTS_MAX_FAIL_ATTEMPTS="${FEED_REQUESTS_MAX_FAIL_ATTEMPTS:-11}"
export FEED_REQUESTS_REQUEST_TIMEOUT_MS="${FEED_REQUESTS_REQUEST_TIMEOUT_MS:-15000}"
npm run migration:up

echo "[migrate] Running user-feeds migrations..."
cd /app/services/user-feeds-next
USER_FEEDS_POSTGRES_URI="${USER_FEEDS_POSTGRES_URI:-postgres://postgres@127.0.0.1:5432/userfeeds}" \
    node ./dist/src/scripts/run-migrations.js

# ---------------------------------------------------------------------------
# Export environment variables with localhost defaults
# ---------------------------------------------------------------------------

# Shared Discord credentials
export BACKEND_API_DISCORD_BOT_TOKEN="${BOT_PRESENCE_DISCORD_BOT_TOKEN}"
export BACKEND_API_DISCORD_CLIENT_ID="${BOT_PRESENCE_DISCORD_BOT_CLIENT_ID}"
export DISCORD_REST_LISTENER_BOT_TOKEN="${BOT_PRESENCE_DISCORD_BOT_TOKEN}"
export DISCORD_REST_LISTENER_BOT_CLIENT_ID="${BOT_PRESENCE_DISCORD_BOT_CLIENT_ID}"
export USER_FEEDS_DISCORD_CLIENT_ID="${BOT_PRESENCE_DISCORD_BOT_CLIENT_ID}"
export USER_FEEDS_DISCORD_API_TOKEN="${BOT_PRESENCE_DISCORD_BOT_TOKEN}"

# MongoDB
export BACKEND_API_MONGODB_URI="${BACKEND_API_MONGODB_URI:-mongodb://localhost:27017/rss}"
export DISCORD_REST_LISTENER_MONGO_URI="${DISCORD_REST_LISTENER_MONGO_URI:-mongodb://localhost:27017/rss?replicaSet=dbrs&directConnection=true}"
export FEED_REQUESTS_FEEDS_MONGODB_URI="${FEED_REQUESTS_FEEDS_MONGODB_URI:-mongodb://localhost:27017/rss?replicaSet=dbrs&directConnection=true}"

# PostgreSQL (force TCP via 127.0.0.1 to bypass peer auth)
export FEED_REQUESTS_POSTGRES_URI="${FEED_REQUESTS_POSTGRES_URI:-postgres://postgres@127.0.0.1:5432/feedrequests}"
export FEED_REQUESTS_POSTGRES_SCHEMA="${FEED_REQUESTS_POSTGRES_SCHEMA:-feedrequests}"
export USER_FEEDS_POSTGRES_URI="${USER_FEEDS_POSTGRES_URI:-postgres://postgres@127.0.0.1:5432/userfeeds}"

# RabbitMQ
export BOT_PRESENCE_RABBITMQ_URL="${BOT_PRESENCE_RABBITMQ_URL:-amqp://guest:guest@localhost:5672}"
export DISCORD_REST_LISTENER_RABBITMQ_URI="${DISCORD_REST_LISTENER_RABBITMQ_URI:-amqp://guest:guest@localhost:5672}"
export DISCORD_REST_LISTENER_MAX_REQ_PER_SEC="${DISCORD_REST_LISTENER_MAX_REQ_PER_SEC:-40}"
export FEED_REQUESTS_RABBITMQ_BROKER_URL="${FEED_REQUESTS_RABBITMQ_BROKER_URL:-amqp://guest:guest@localhost:5672}"
export USER_FEEDS_RABBITMQ_BROKER_URL="${USER_FEEDS_RABBITMQ_BROKER_URL:-amqp://guest:guest@localhost:5672}"
export BACKEND_API_RABBITMQ_BROKER_URL="${BACKEND_API_RABBITMQ_BROKER_URL:-amqp://guest:guest@localhost:5672/}"

# Redis
export FEED_REQUESTS_REDIS_URI="${FEED_REQUESTS_REDIS_URI:-redis://localhost:6379}"
export FEED_REQUESTS_REDIS_DISABLE_CLUSTER=true
export USER_FEEDS_REDIS_URI="${USER_FEEDS_REDIS_URI:-redis://localhost:6379}"
export USER_FEEDS_REDIS_DISABLE_CLUSTER=true

# Backend API general settings
export BACKEND_API_NODE_ENV="${NODE_ENV:-production}"
export BACKEND_API_FEED_USER_AGENT="${BACKEND_API_FEED_USER_AGENT:-$_UA_BASE}"
export BACKEND_API_DEFAULT_MAX_FEEDS="${BACKEND_API_DEFAULT_MAX_FEEDS:-999999}"
export BACKEND_API_DEFAULT_REFRESH_RATE_MINUTES="${BACKEND_API_DEFAULT_REFRESH_RATE_MINUTES:-10}"
export BACKEND_API_DEFAULT_MAX_USER_FEEDS="${BACKEND_API_DEFAULT_MAX_USER_FEEDS:-10000}"
export BACKEND_API_MAX_DAILY_ARTICLES_DEFAULT="${BACKEND_API_MAX_DAILY_ARTICLES_DEFAULT:-100000}"
export BACKEND_API_ALLOW_LEGACY_REVERSION="${BACKEND_API_ALLOW_LEGACY_REVERSION:-true}"
export LOG_LEVEL="${LOG_LEVEL:-info}"

# Optional: email notifications (SMTP)
[ -n "$BACKEND_API_SMTP_HOST" ]     && export BACKEND_API_SMTP_HOST
[ -n "$BACKEND_API_SMTP_USERNAME" ] && export BACKEND_API_SMTP_USERNAME
[ -n "$BACKEND_API_SMTP_PASSWORD" ] && export BACKEND_API_SMTP_PASSWORD
[ -n "$BACKEND_API_SMTP_FROM" ]     && export BACKEND_API_SMTP_FROM

# Optional: Reddit feed authorization
[ -n "$BACKEND_API_REDDIT_CLIENT_ID" ]     && export BACKEND_API_REDDIT_CLIENT_ID
[ -n "$BACKEND_API_REDDIT_CLIENT_SECRET" ] && export BACKEND_API_REDDIT_CLIENT_SECRET
[ -n "$BACKEND_API_REDDIT_REDIRECT_URI" ]  && export BACKEND_API_REDDIT_REDIRECT_URI

# BACKEND_API_ENCRYPTION_KEY_HEX is required (exactly 64 hex chars).
# Auto-generate on first run and persist so it survives restarts.
if [ -z "$BACKEND_API_ENCRYPTION_KEY_HEX" ]; then
    _KEY_FILE="$DATA_DIR/encryption_key.hex"
    if [ -f "$_KEY_FILE" ]; then
        export BACKEND_API_ENCRYPTION_KEY_HEX=$(cat "$_KEY_FILE")
        echo "[init] Loaded encryption key from $_KEY_FILE"
    else
        export BACKEND_API_ENCRYPTION_KEY_HEX=$(openssl rand -hex 32)
        echo "$BACKEND_API_ENCRYPTION_KEY_HEX" > "$_KEY_FILE"
        chmod 600 "$_KEY_FILE"
        echo "[init] Generated and saved new encryption key to $_KEY_FILE"
    fi
fi

# Internal API keys
export FEED_REQUESTS_API_KEY="${FEED_REQUESTS_API_KEY:-feed-requests-api-key}"
export FEED_REQUESTS_API_PORT="${FEED_REQUESTS_API_PORT:-5000}"
export USER_FEEDS_API_KEY="${USER_FEEDS_API_KEY:-user-feeds-api-key}"
export USER_FEEDS_API_PORT="${USER_FEEDS_API_PORT:-5001}"
export USER_FEEDS_FEED_REQUESTS_API_URL="${USER_FEEDS_FEED_REQUESTS_API_URL:-http://localhost:5000/v1/feed-requests}"
export USER_FEEDS_FEED_REQUESTS_API_KEY="${USER_FEEDS_FEED_REQUESTS_API_KEY:-feed-requests-api-key}"
export BACKEND_API_USER_FEEDS_API_HOST="${BACKEND_API_USER_FEEDS_API_HOST:-http://localhost:5001}"
export BACKEND_API_USER_FEEDS_API_KEY="${BACKEND_API_USER_FEEDS_API_KEY:-user-feeds-api-key}"
export BACKEND_API_FEED_REQUESTS_API_HOST="${BACKEND_API_FEED_REQUESTS_API_HOST:-http://localhost:5000}"
export BACKEND_API_FEED_REQUESTS_API_KEY="${BACKEND_API_FEED_REQUESTS_API_KEY:-feed-requests-api-key}"

# ---------------------------------------------------------------------------
# Hand off to supervisord
# ---------------------------------------------------------------------------
_CLIENT_ID="${BOT_PRESENCE_DISCORD_BOT_CLIENT_ID:-YOUR_CLIENT_ID}"
_LOGIN_URI="${BACKEND_API_LOGIN_REDIRECT_URI:-http://your-domain}"

echo "[start] All infrastructure ready. Starting MonitoRSS services..."
echo "[start] Web UI will be available at: ${_LOGIN_URI}"
echo ""
echo "[info] Discord invite links:"
echo "[info]   With permissions: https://discord.com/oauth2/authorize?client_id=${_CLIENT_ID}&scope=bot&permissions=19456"
echo "[info]   Without role:     https://discord.com/oauth2/authorize?client_id=${_CLIENT_ID}&scope=bot"
echo ""

# Background process: waits until all 6 services are RUNNING, then prints a
# clear "all up" banner. Runs after exec so it doesn't block supervisord startup.
(
    sleep 20
    while true; do
        RUNNING=$(supervisorctl -c /etc/supervisor/supervisord.conf status 2>/dev/null | grep -c "RUNNING")
        if [ "$RUNNING" -ge 6 ]; then
            echo ""
            echo "========================================================"
            echo "  All MonitoRSS services are UP and running!"
            echo ""
            echo "  Web UI:                  ${_LOGIN_URI}"
            echo "  Invite (with perms):     https://discord.com/oauth2/authorize?client_id=${_CLIENT_ID}&scope=bot&permissions=19456"
            echo "  Invite (without role):   https://discord.com/oauth2/authorize?client_id=${_CLIENT_ID}&scope=bot"
            echo "========================================================"
            echo ""
            break
        fi
        sleep 5
    done
) &

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
