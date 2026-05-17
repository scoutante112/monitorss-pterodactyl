ARG MONITORSS_VERSION=7

# ---------------------------------------------------------------------------
# base – system dependencies (MongoDB, PostgreSQL, RabbitMQ, Redis, Node.js)
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gnupg lsb-release ca-certificates \
    supervisor wget git procps libnss-wrapper \
    && rm -rf /var/lib/apt/lists/*

# Allow RabbitMQ to start as any non-root user
ENV RABBITMQ_ALLOW_RUNNING_AS_ROOT=1

# Node.js 24
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# MongoDB 8.0 + mongosh
RUN curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc \
    | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg \
    && echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" \
    | tee /etc/apt/sources.list.d/mongodb-org-8.0.list \
    && apt-get update && apt-get install -y mongodb-org mongodb-mongosh \
    && rm -rf /var/lib/apt/lists/*

# PostgreSQL 17
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
    | tee /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y postgresql-17 \
    && rm -rf /var/lib/apt/lists/*

# RabbitMQ + Erlang + Redis (all from Debian Bookworm main repos)
RUN apt-get update && apt-get install -y rabbitmq-server redis-server \
    && rm -rf /var/lib/apt/lists/*

# Replace /usr/sbin/rabbitmq-server entirely with a minimal wrapper.
# The Debian wrapper hardcodes a redirect to /var/log/rabbitmq/startup_log at
# line 33 before reading any environment variables – unfixable with sed alone.
RUN printf '#!/bin/sh\nmkdir -p /tmp/rabbitmq-logs\nexport RABBITMQ_LOG_BASE=/tmp/rabbitmq-logs\nexec /usr/lib/rabbitmq/bin/rabbitmq-server "$@"\n' \
    > /usr/sbin/rabbitmq-server \
    && chmod +x /usr/sbin/rabbitmq-server

# Patch the actual rabbitmq binary so it also uses /tmp instead of /var/log/rabbitmq
RUN sed -i 's|/var/log/rabbitmq|/tmp/rabbitmq-logs|g' /usr/lib/rabbitmq/bin/rabbitmq-server

# ---------------------------------------------------------------------------
# builder – clone MonitoRSS and build all services
# ---------------------------------------------------------------------------
FROM base AS builder

ARG MONITORSS_VERSION

WORKDIR /build

RUN git clone --depth 1 https://github.com/synzen/MonitoRSS.git .

# Install ALL workspace dependencies from root so workspace symlinks are
# set up correctly and local packages aren't rebuilt with wrong tsconfig.
RUN npm install

# Build shared packages first (services depend on these)
RUN npm run build:packages

# Build each service from workspace root
RUN npm run build --workspace=services/bot-presence
RUN npm run build --workspace=services/discord-rest-listener
RUN npm run build --workspace=services/feed-requests
RUN npm run build --workspace=services/user-feeds-next
RUN npm run build --workspace=services/backend-api

# Do NOT prune dev dependencies – mikro-orm CLI (used for migrations) lives in devDeps

# ---------------------------------------------------------------------------
# final – lean runtime image
# ---------------------------------------------------------------------------
FROM base

WORKDIR /app

COPY --from=builder /build/packages             ./packages
COPY --from=builder /build/services/bot-presence            ./services/bot-presence
COPY --from=builder /build/services/discord-rest-listener   ./services/discord-rest-listener
COPY --from=builder /build/services/feed-requests           ./services/feed-requests
COPY --from=builder /build/services/user-feeds-next         ./services/user-feeds-next
COPY --from=builder /build/services/backend-api             ./services/backend-api

COPY start.sh         /start.sh
COPY supervisord.conf /etc/supervisor/conf.d/monitorss.conf
RUN chmod +x /start.sh

EXPOSE 8000

CMD ["/start.sh"]
