FROM ubuntu:24.04
LABEL org.opencontainers.image.source="https://github.com/voipappz/db"

ENV DEBIAN_FRONTEND=noninteractive
ENV PG_VERSION=17

# Base dependencies + pgEdge apt repository
# (build-essential + git are only for compiling the `prefix` extension below;
#  cmake/libssl-dev were only needed by the removed TimescaleDB build.)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gnupg2 lsb-release ca-certificates \
    build-essential git cmake libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# pgEdge apt repository
RUN curl -sSL https://apt.pgedge.com/repodeb/pgedge-release_latest_all.deb \
      -o /tmp/pgedge-release.deb \
    && dpkg -i /tmp/pgedge-release.deb \
    && rm -f /tmp/pgedge-release.deb \
    && apt-get update

# pgEdge Enterprise Postgres + dev headers (needed to compile extensions).
# pgedge-postgrest removed 2026-08-03: nothing consumed that API.
RUN apt-get install -y --no-install-recommends \
    pgedge-enterprise-postgres-${PG_VERSION} \
    pgedge-postgresql-server-dev-${PG_VERSION} \
    && rm -rf /var/lib/apt/lists/*

# Pin TimescaleDB; build against the pgEdge PostgreSQL headers in this image.
ARG TIMESCALEDB_VERSION=2.31.0
RUN curl -fSL "https://github.com/timescale/timescaledb/archive/refs/tags/${TIMESCALEDB_VERSION}.tar.gz" -o /tmp/timescaledb.tar.gz \
    && mkdir /tmp/timescaledb \
    && tar xzf /tmp/timescaledb.tar.gz -C /tmp/timescaledb --strip-components=1 \
    && cd /tmp/timescaledb \
    && ./bootstrap -DREGRESS_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF \
    && cmake --build build --parallel 2 \
    && cmake --install build \
    && rm -rf /tmp/timescaledb /tmp/timescaledb.tar.gz

# Build prefix extension from source (telephone prefix range type for LCR)
RUN git clone --depth 1 https://github.com/dimitri/prefix.git /tmp/prefix \
    && cd /tmp/prefix \
    && make \
    && make install \
    && rm -rf /tmp/prefix

# Build set_user from source (CIS: audited privilege escalation; the pgEdge
# apt repo has no PG17 package). Loaded only when PG_SET_USER=on.
RUN git clone --depth 1 https://github.com/pgaudit/set_user.git /tmp/set_user \
    && cd /tmp/set_user \
    && make USE_PGXS=1 \
    && make USE_PGXS=1 install \
    && rm -rf /tmp/set_user

# Clean up build deps
RUN apt-get purge -y build-essential pgedge-postgresql-server-dev-${PG_VERSION} git \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Ensure pgedge user exists and owns PostgreSQL directories
# (pgedge packages may create user/cluster owned by postgres)
RUN (getent group pgedge || groupadd -r pgedge) \
    && (id pgedge 2>/dev/null || useradd -r -g pgedge -m -d /home/pgedge -s /bin/bash pgedge) \
    && mkdir -p /data/pgdata && chown -R pgedge:pgedge /data \
    && pg_dropcluster --stop 17 main 2>/dev/null || true
RUN mkdir -p /etc/postgresql /var/lib/postgresql /var/log/postgresql /var/run/postgresql \
    && chown -R pgedge:pgedge /etc/postgresql /var/lib/postgresql /var/log/postgresql /var/run/postgresql

# Copy per-database SQL init files and node init script
COPY sql/ /home/pgedge/scripts/sql/
COPY init-node.sh /home/pgedge/scripts/init-node.sh
RUN chmod +x /home/pgedge/scripts/init-node.sh \
    && chown -R pgedge:pgedge /home/pgedge/scripts

EXPOSE 5432
USER pgedge

ENTRYPOINT ["/home/pgedge/scripts/init-node.sh"]
