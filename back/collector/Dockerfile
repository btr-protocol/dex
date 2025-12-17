# Minimal Bun image for market data collector
FROM oven/bun:1-alpine AS base
WORKDIR /app

# Install dependencies
FROM base AS deps
COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile --production

# Production image
FROM base AS runner
ENV NODE_ENV=production
ENV PORT=3000

# Create data directory for SQLite
RUN mkdir -p /app/data

# Copy dependencies and source
COPY --from=deps /app/node_modules ./node_modules
COPY src ./src
COPY package.json ./

# Non-root user for security
RUN addgroup -g 1001 -S collector && \
    adduser -S collector -u 1001 && \
    chown -R collector:collector /app
USER collector

EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1

CMD ["bun", "run", "src/server-main.ts"]
