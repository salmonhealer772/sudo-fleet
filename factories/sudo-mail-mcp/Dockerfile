# ============================================================================
# sudo-mail-mcp — fleet-shared IMAP/SMTP email MCP server (OAuth2/XOAUTH2)
#
# Vendored from codefuturist/email-mcp (v0.6.0, commit 7d31cd5eac8788bd69237c18
# e3ee1e1fe2816ab7) with ONE patch: `client_secret` made optional (Microsoft
# public client — the Thunderbird client id — has no secret). Everything else
# is stock upstream.
#
# Reuses the EXISTING ortie OAuth refresh tokens (Google + Microsoft) so no new
# OAuth consent is required. IMAP/SMTP with XOAUTH2, served over Streamable
# HTTP (path /mcp) so it fits the fleet's `mcp_servers.<name>.url` wiring.
# ============================================================================
FROM node:24-slim AS builder
RUN corepack enable
WORKDIR /app
COPY vendor/package.json vendor/pnpm-lock.yaml vendor/pnpm-workspace.yaml ./
COPY vendor/patches/ patches/
RUN pnpm install --frozen-lockfile
COPY vendor/tsconfig.json vendor/tsconfig.build.json ./
COPY vendor/src/ src/
RUN pnpm build && pnpm prune --prod

FROM node:24-slim AS production
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./
ENV NODE_ENV=production
EXPOSE 8080
ENTRYPOINT ["node", "dist/main.js"]
CMD ["stdio"]
