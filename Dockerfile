FROM node:26-alpine@sha256:aadf416b2cdce311a8811ba3f0608a61b77dbf997500e2eafe781b51f6a0b019 AS dependencies

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

# Cloud Build executes this target as the release-blocking test environment.
# Keeping the test graph in the Dockerfile makes the deploy system test the
# same Node base and dependency lock used to assemble production.
FROM dependencies AS test
RUN apk add --no-cache bash python3
COPY .eslintrc.cjs ./
COPY src/ ./src/
COPY test/ ./test/
COPY scripts/ ./scripts/
CMD ["sh", "-ceu", "npm test -- --runInBand && npm run lint && npm audit --audit-level=moderate && bash scripts/test-release-cloud-run.sh"]

FROM dependencies AS production-dependencies
RUN npm prune --omit=dev \
    && npm cache clean --force

FROM node:26-alpine@sha256:aadf416b2cdce311a8811ba3f0608a61b77dbf997500e2eafe781b51f6a0b019 AS runtime

RUN apk add --no-cache ffmpeg \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
    && rm -f /usr/local/bin/npm /usr/local/bin/npx \
        /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/pnpm

WORKDIR /app

COPY --from=production-dependencies /app/node_modules ./node_modules
COPY src/ ./src/

USER node:node

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

# Start Node directly: no package manager or shell is needed at runtime, and
# Node receives Cloud Run termination signals as PID 1.
ENTRYPOINT []
CMD ["node", "src/index.js"]
