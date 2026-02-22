# =============================================================================
# Multi-stage Dockerfile for QuckChat Realtime Service (Elixir/Phoenix)
# =============================================================================

# =============================================================================
# Build Stage
# =============================================================================
FROM hexpm/elixir:1.15.7-erlang-26.2.1-alpine-3.18.4 AS builder

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    npm \
    curl

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build ENV
ENV MIX_ENV=prod

# Install mix dependencies
COPY mix.exs ./
RUN mix deps.get --only $MIX_ENV

# Create config directory and copy compile-time config
RUN mkdir -p config
COPY config/config.exs config/${MIX_ENV}.exs config/

# Compile dependencies
RUN mix deps.compile

# Copy application code
COPY lib lib
COPY priv priv

# Compile application
RUN mix compile

# Copy runtime config and build release
COPY config/runtime.exs config/

# Build the release
RUN mix release quckchat_realtime

# =============================================================================
# Runtime Stage
# =============================================================================
FROM alpine:3.18 AS runtime

# Install runtime dependencies
RUN apk add --no-cache \
    libstdc++ \
    openssl \
    ncurses-libs \
    curl \
    bash \
    ca-certificates

WORKDIR /app

# Create non-root user
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

# Copy release from builder
COPY --from=builder --chown=appuser:appgroup /app/_build/prod/rel/quckchat_realtime ./

# Set ownership
RUN chown -R appuser:appgroup /app

USER appuser

# Environment variables
ENV HOME=/app
ENV PORT=4003
ENV MIX_ENV=prod

# Expose Phoenix port and EPMD port (for Erlang distributed clustering)
EXPOSE 4003 4369

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:4003/health || exit 1

# Run the release
CMD ["bin/quckchat_realtime", "start"]
