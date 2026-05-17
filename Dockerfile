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

# Erlang OTP 25 from Debian Bookworm + Redis.
# RabbitMQ 3.12.x requires OTP 25+ (compatible); 3.13 requires OTP 26 which
# Bookworm does not ship — so we use 3.12 to avoid the timer:tc/2 version mismatch.
RUN apt-get update && apt-get install -y \
    erlang-base erlang-asn1 erlang-crypto erlang-mnesia erlang-os-mon \
    erlang-public-key erlang-ssl erlang-runtime-tools erlang-inets \
    erlang-tools erlang-syntax-tools erlang-xmerl erlang-parsetools \
    erlang-eldap \
    redis-server \
    && rm -rf /var/lib/apt/lists/*

# RabbitMQ 3.12.14 generic Unix binary (compatible with OTP 25 from Bookworm)
RUN RABBITMQ_VERSION=3.12.14 \
    && curl -fsSL "https://github.com/rabbitmq/rabbitmq-server/releases/download/v${RABBITMQ_VERSION}/rabbitmq-server-generic-unix-${RABBITMQ_VERSION}.tar.xz" \
       -o /tmp/rabbitmq.tar.xz \
    && apt-get install -y xz-utils && rm -rf /var/lib/apt/lists/* \
    && tar xf /tmp/rabbitmq.tar.xz -C /usr/local \
    && mv /usr/local/rabbitmq_server-${RABBITMQ_VERSION} /usr/local/rabbitmq \
    && rm /tmp/rabbitmq.tar.xz

ENV PATH="/usr/local/rabbitmq/sbin:$PATH"

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

# Build the React frontend (served by backend-api from client/dist at runtime)
RUN cd services/backend-api/client && npm install && npm run build

# Do NOT prune dev dependencies – mikro-orm CLI (used for migrations) lives in devDeps

# ---------------------------------------------------------------------------
# final – lean runtime image
# ---------------------------------------------------------------------------
FROM base

WORKDIR /app

COPY --from=builder /build/packages             ./packages
# Root node_modules contains @monitorss/* workspace symlinks that services depend on
COPY --from=builder /build/node_modules         ./node_modules
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
