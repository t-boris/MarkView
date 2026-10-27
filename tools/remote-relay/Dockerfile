FROM node:22-alpine
WORKDIR /app
COPY server.mjs ./server.mjs
USER node
ENV HOST=0.0.0.0 PORT=8787
EXPOSE 8787
CMD ["node", "server.mjs"]
