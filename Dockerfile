ARG MONITORSS_VERSION=7

# ---------------------------------------------------------------------------
# base – system dependencies (MongoDB, PostgreSQL, RabbitMQ, Redis, Node.js)
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gnupg lsb-release ca-certificates \
    supervisor wget git procps gosu \
    && rm -rf /var/lib/apt/lists/*

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

# ---------------------------------------------------------------------------
# builder – clone MonitoRSS and build all services
# ---------------------------------------------------------------------------
FROM base AS builder

ARG MONITORSS_VERSION

WORKDIR /build

RUN git clone --depth 1 --branch ${MONITORSS_VERSION} \
    https://github.com/synzen/MonitoRSS.git . \
    || git clone --depth 1 https://github.com/synzen/MonitoRSS.git .

# Build shared workspace packages
RUN npm install --workspace=packages/contracts --workspace=packages/logger \
    && npm run build:packages

# Build each service and prune dev dependencies
RUN cd services/bot-presence \
    && npm install && npm run build && npm prune --production

RUN cd services/discord-rest-listener \
    && npm install && npm run build && npm prune --production

RUN cd services/feed-requests \
    && npm install && npm run build && npm prune --production

RUN cd services/user-feeds-next \
    && npm install && npm run build && npm prune --production

RUN cd services/backend-api \
    && npm install && npm run build && npm prune --production

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
