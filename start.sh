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
echo "[start] Starting MongoDB..."
mongod \
    --dbpath "$MONGO_DATA" \
    --replSet dbrs \
    --bind_ip_all \
    --logpath "$LOG_DIR/mongo.log" \
    --pidfilepath /tmp/mongod.pid \
    --fork

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

echo "[start] Starting RabbitMQ..."
mkdir -p /tmp/rabbitmq-logs
# Pre-create the Erlang cookie in $HOME so Erlang never tries /.erlang.cookie.
# Remove any leftover cookie from a previous run (chmod 400 would block overwrite).
ERLANG_COOKIE="monitorss-pterodactyl-cookie"
rm -f "$HOME/.erlang.cookie"
echo "$ERLANG_COOKIE" > "$HOME/.erlang.cookie"
chmod 600 "$HOME/.erlang.cookie"

RABBITMQ_MNESIA_BASE="$RABBITMQ_DATA" \
RABBITMQ_LOG_BASE="$LOG_DIR" \
RABBITMQ_PID_FILE="/tmp/rabbitmq.pid" \
RABBITMQ_ERLANG_COOKIE="$ERLANG_COOKIE" \
    rabbitmq-server -detached
sleep 5

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

echo "[wait] Waiting for RabbitMQ..."
until rabbitmqctl status &>/dev/null 2>&1; do
    sleep 2
done

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
echo "[migrate] Running feed-requests migrations..."
cd /app/services/feed-requests
FEED_REQUESTS_POSTGRES_URI="${FEED_REQUESTS_POSTGRES_URI:-postgres://postgres@127.0.0.1:5432/feedrequests}" \
FEED_REQUESTS_POSTGRES_SCHEMA="${FEED_REQUESTS_POSTGRES_SCHEMA:-feedrequests}" \
FEED_REQUESTS_API_KEY="${FEED_REQUESTS_API_KEY:-feed-requests-api-key}" \
FEED_REQUESTS_API_PORT="${FEED_REQUESTS_API_PORT:-5000}" \
FEED_REQUESTS_RABBITMQ_BROKER_URL="${FEED_REQUESTS_RABBITMQ_BROKER_URL:-amqp://guest:guest@localhost:5672}" \
FEED_REQUESTS_REDIS_URI="${FEED_REQUESTS_REDIS_URI:-redis://localhost:6379}" \
FEED_REQUESTS_REDIS_DISABLE_CLUSTER=true \
    npx mikro-orm migration:up

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
export FEED_REQUESTS_RABBITMQ_BROKER_URL="${FEED_REQUESTS_RABBITMQ_BROKER_URL:-amqp://guest:guest@localhost:5672}"
export USER_FEEDS_RABBITMQ_BROKER_URL="${USER_FEEDS_RABBITMQ_BROKER_URL:-amqp://guest:guest@localhost:5672}"
export BACKEND_API_RABBITMQ_BROKER_URL="${BACKEND_API_RABBITMQ_BROKER_URL:-amqp://guest:guest@localhost:5672/}"

# Redis
export FEED_REQUESTS_REDIS_URI="${FEED_REQUESTS_REDIS_URI:-redis://localhost:6379}"
export FEED_REQUESTS_REDIS_DISABLE_CLUSTER=true
export USER_FEEDS_REDIS_URI="${USER_FEEDS_REDIS_URI:-redis://localhost:6379}"
export USER_FEEDS_REDIS_DISABLE_CLUSTER=true

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
echo "[start] All infrastructure ready. Starting MonitoRSS services..."
echo "[start] Web UI will be available on port ${BACKEND_API_PORT:-8000}"
echo "[ready] All MonitoRSS services started"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
