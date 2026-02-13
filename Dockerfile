# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t sandcastle .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name sandcastle sandcastle

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.0
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips libpq5 postgresql-client openssh-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock vendor ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile


# Development stage for live source mounting
FROM base AS development

# Install development dependencies
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    build-essential \
    git \
    libpq-dev \
    node-gyp \
    pkg-config \
    python-is-python3 \
    ca-certificates \
    gnupg && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install Docker CLI
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y docker-ce-cli && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Create user early
RUN groupadd --system --gid 220568 sandcastle && \
    useradd sandcastle --uid 220568 --gid 220568 --create-home --shell /bin/bash && \
    groupadd --system docker && \
    usermod -aG docker sandcastle

# Switch to development bundle config
ENV RAILS_ENV="development" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT=""

# Install all gems (including development/test)
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Set working directory
WORKDIR /rails

# Run as sandcastle user
USER 220568:220568

# Entrypoint for db readiness
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Default to bin/dev (Foreman with Rails + Tailwind)
EXPOSE 80
CMD ["./bin/dev"]


# Final stage for app image
FROM base

# Install Docker CLI for container management via mounted socket
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates gnupg && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y docker-ce-cli && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 220568 sandcastle && \
    useradd sandcastle --uid 220568 --gid 220568 --create-home --shell /bin/bash && \
    groupadd --system docker && \
    usermod -aG docker sandcastle
USER 220568:220568

# Copy built artifacts: gems, application
COPY --chown=sandcastle:sandcastle --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=sandcastle:sandcastle --from=build /rails /rails

# Build metadata for version footer
ARG BUILD_VERSION
ARG BUILD_GIT_SHA
ARG BUILD_GIT_DIRTY
ARG BUILD_DATE
ENV BUILD_VERSION=${BUILD_VERSION} \
    BUILD_GIT_SHA=${BUILD_GIT_SHA} \
    BUILD_GIT_DIRTY=${BUILD_GIT_DIRTY} \
    BUILD_DATE=${BUILD_DATE}

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# OCI labels for ghcr.io package linking
LABEL service="sandcastle"
LABEL org.opencontainers.image.source="https://github.com/thieso2/sandcastle"
LABEL org.opencontainers.image.description="Self-hosted shared Docker sandbox platform"
LABEL org.opencontainers.image.licenses="MIT"

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
