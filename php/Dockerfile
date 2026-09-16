FROM php:8.3-cli-alpine
RUN apk add --no-cache linux-headers && \
    docker-php-ext-install pcntl sockets && \
    apk del linux-headers
WORKDIR /app
COPY server.php ./
EXPOSE 8080
CMD ["php", "server.php"]
