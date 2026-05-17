#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# MonitoRSS – Pterodactyl all-in-one startup script
# Runs once to initialise databases, then hands off to supervisord.
# ---------------------------------------------------------------------------

DATA_DIR="${DATA_DIR:-/home/container/data}"
LOG_DIR="/var/log/monitorss"

MONGO_DATA="$DATA_DIR/mongodb"
PG_DATA="$DATA_DIR/postgresql"
RABBITMQ_DATA="$DATA_DIR/rabbitmq"
REDIS_DATA="$DATA_DIR/redis"

mkdir -p "$MONGO_DATA" "$PG_DATA" "$RABBITMQ_DATA" "$REDIS_DATA" "$LOG_DIR"

# ---------------------------------------------------------------------------
# PostgreSQL – initialise cluster if needed
# ---------------------------------------------------------------------------
if [ ! -f "$PG_DATA/PG_VERSION" ]; then
    echo "[init] Initialising PostgreSQL data directory..."
    chown -R postgres:postgres "$PG_DATA"
    gosu postgres /usr/lib/postgresql/17/bin/initdb -D "$PG_DATA" --encoding=UTF8
fi
chown -R postgres:postgres "$PG_DATA"

# ---------------------------------------------------------------------------
# Start infrastructure services in the background
# ---------------------------------------------------------------------------
echo "[start] Starting MongoDB..."
mongod \
    --dbpath "$MONGO_DATA" \
    --replSet dbrs \
    --bind_ip_all \
    --logpath "$LOG_DIR/mongo.log" \
    --fork

echo "[start] Starting PostgreSQL..."
gosu postgres /usr/lib/postgresql/17/bin/pg_ctl start \
    -D "$PG_DATA" \
    -l "$LOG_DIR/postgresql.log" \
    -w

echo "[start] Starting Redis..."
redis-server \
    --daemonize yes \
    --dir "$REDIS_DATA" \
    --logfile "$LOG_DIR/redis.log" \
    --save 60 1

echo "[start] Starting RabbitMQ..."
RABBITMQ_MNESIA_BASE="$RABBITMQ_DATA" \
RABBITMQ_LOG_BASE="$LOG_DIR" \
    rabbitmq-server -detached
sleep 5  # Give Erlang time to start epmd + broker

# ---------------------------------------------------------------------------
# Wait for services to become ready
# ---------------------------------------------------------------------------
echo "[wait] Waiting for MongoDB..."
until mongosh --quiet --eval "db.adminCommand('ping')" &>/dev/null 2>&1; do
    sleep 1
done

echo "[wait] Waiting for PostgreSQL..."
until gosu postgres /usr/lib/postgresql/17/bin/pg_isready &>/dev/null 2>&1; do
    sleep 1
done

echo "[wait] Waiting for RabbitMQ..."
until rabbitmqctl status &>/dev/null 2>&1; do
    sleep 2
done

# ---------------------------------------------------------------------------
# Initialise MongoDB replica set (required by discord-rest-listener & feed-requests)
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
gosu postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='feedrequests'" \
    | grep -q 1 \
    || gosu postgres psql -c "CREATE DATABASE feedrequests;"

gosu postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='userfeeds'" \
    | grep -q 1 \
    || gosu postgres psql -c "CREATE DATABASE userfeeds;"

# ---------------------------------------------------------------------------
# Run database migrations
# ---------------------------------------------------------------------------
echo "[migrate] Running feed-requests migrations..."
cd /app/services/feed-requests
FEED_REQUESTS_POSTGRES_URI="${FEED_REQUESTS_POSTGRES_URI:-postgres://postgres@localhost:5432/feedrequests}" \
FEED_REQUESTS_POSTGRES_SCHEMA="${FEED_REQUESTS_POSTGRES_SCHEMA:-feedrequests}" \
FEED_REQUESTS_API_KEY="${FEED_REQUESTS_API_KEY:-feed-requests-api-key}" \
FEED_REQUESTS_API_PORT="${FEED_REQUESTS_API_PORT:-5000}" \
FEED_REQUESTS_RABBITMQ_BROKER_URL="${FEED_REQUESTS_RABBITMQ_BROKER_URL:-amqp://guest:guest@localhost:5672}" \
FEED_REQUESTS_REDIS_URI="${FEED_REQUESTS_REDIS_URI:-redis://localhost:6379}" \
FEED_REQUESTS_REDIS_DISABLE_CLUSTER=true \
    npx mikro-orm migration:up

echo "[migrate] Running user-feeds migrations..."
cd /app/services/user-feeds-next
USER_FEEDS_POSTGRES_URI="${USER_FEEDS_POSTGRES_URI:-postgres://postgres@localhost:5432/userfeeds}" \
    node ./dist/src/scripts/run-migrations.js

# ---------------------------------------------------------------------------
# Export environment variables with localhost defaults so supervisord
# inherits them for all child processes.
# ---------------------------------------------------------------------------

# Shared Discord credentials – set via Pterodactyl egg variables
export BACKEND_API_DISCORD_BOT_TOKEN="${BOT_PRESENCE_DISCORD_BOT_TOKEN}"
export BACKEND_API_DISCORD_CLIENT_ID="${BOT_PRESENCE_DISCORD_BOT_CLIENT_ID}"
export DISCORD_REST_LISTENER_BOT_TOKEN="${BOT_PRESENCE_DISCORD_BOT_TOKEN}"
export DISCORD_REST_LISTENER_BOT_CLIENT_ID="${BOT_PRESENCE_DISCORD_BOT_CLIENT_ID}"
export USER_FEEDS_DISCORD_CLIENT_ID="${BOT_PRESENCE_DISCORD_BOT_CLIENT_ID}"
export USER_FEEDS_DISCORD_API_TOKEN="${BOT_PRESENCE_DISCORD_BOT_TOKEN}"

# MongoDB URIs
export BACKEND_API_MONGODB_URI="${BACKEND_API_MONGODB_URI:-mongodb://localhost:27017/rss}"
export DISCORD_REST_LISTENER_MONGO_URI="${DISCORD_REST_LISTENER_MONGO_URI:-mongodb://localhost:27017/rss?replicaSet=dbrs&directConnection=true}"
export FEED_REQUESTS_FEEDS_MONGODB_URI="${FEED_REQUESTS_FEEDS_MONGODB_URI:-mongodb://localhost:27017/rss?replicaSet=dbrs&directConnection=true}"

# PostgreSQL
export FEED_REQUESTS_POSTGRES_URI="${FEED_REQUESTS_POSTGRES_URI:-postgres://postgres@localhost:5432/feedrequests}"
export FEED_REQUESTS_POSTGRES_SCHEMA="${FEED_REQUESTS_POSTGRES_SCHEMA:-feedrequests}"
export USER_FEEDS_POSTGRES_URI="${USER_FEEDS_POSTGRES_URI:-postgres://postgres@localhost:5432/userfeeds}"

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

# Internal API keys (inter-service communication, no need to change)
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
# Hand off to supervisord which manages all Node.js services
# ---------------------------------------------------------------------------
echo "[start] All infrastructure ready. Starting MonitoRSS services via supervisord..."
echo "[start] Web UI will be available on port ${BACKEND_API_PORT:-8000}"
echo "[ready] All MonitoRSS services started"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
