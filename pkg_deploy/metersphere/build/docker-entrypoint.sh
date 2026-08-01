#!/bin/bash
# ============================================================
# MeterSphere Docker 入口
# ============================================================
set -euo pipefail

MS_PORT="${MS_PORT:-8081}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-metersphere}"
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-Password123!@#}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASS="${REDIS_PASS:-Pg1@zendao2024}"
KAFKA_BOOTSTRAP="${KAFKA_BOOTSTRAP:-127.0.0.1:9092}"
HEAP_MIN="${HEAP_MIN:-2048m}"
HEAP_MAX="${HEAP_MAX:-4096m}"

MS_JAR=$(find /opt/metersphere -name "metersphere*.jar" -not -name "*sources*" -not -name "*javadoc*" | head -1)

exec java \
    -Xms${HEAP_MIN} -Xmx${HEAP_MAX} \
    -jar "${MS_JAR}" \
    --server.port=${MS_PORT} \
    --spring.datasource.url="jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}?useSSL=false&serverTimezone=UTC" \
    --spring.datasource.username="${DB_USER}" \
    --spring.datasource.password="${DB_PASS}" \
    --spring.redis.host="${REDIS_HOST}" \
    --spring.redis.port="${REDIS_PORT}" \
    --spring.redis.password="${REDIS_PASS}" \
    --spring.kafka.bootstrap-servers="${KAFKA_BOOTSTRAP}"
