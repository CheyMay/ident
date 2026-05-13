FROM node:24-bookworm-slim

WORKDIR /app
ENV NODE_ENV=production

COPY package.json ./
COPY src ./src
COPY scripts ./scripts
COPY README.md ./

RUN mkdir -p /app/data

EXPOSE 8080
VOLUME ["/app/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:' + (process.env.PORT || 8080) + '/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "src/index.js"]
