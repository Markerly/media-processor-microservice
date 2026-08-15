FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS dependencies

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

FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS runtime

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
