FROM node:18-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --no-fund --no-audit

COPY src/ ./src/

EXPOSE 8000

USER node

HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "\
    require('http') \
      .get('http://localhost:8000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)) \
      .on('error', () => process.exit(1))"

CMD ["node", "src/index.js"]
