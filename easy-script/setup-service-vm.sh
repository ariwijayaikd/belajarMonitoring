#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Service VM Stack (Docker Compose)
# - node_exporter (host metrics)
# - cadvisor (container metrics)
# - app (placeholder)
# =========================================================

mkdir -p /opt/service-stack
cd /opt/service-stack

cat > docker-compose.yml <<'YAML'
services:
  node_exporter:
    image: prom/node-exporter:v1.8.2
    container_name: node_exporter
    network_mode: host
    pid: host
    restart: unless-stopped
    command:
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--path.rootfs=/rootfs"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: cadvisor
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:rw
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    privileged: true

  app:
    image: ghcr.io/org-kamu/app-kamu:latest
    container_name: app
    restart: unless-stopped
    ports:
      - "8088:8088"
    environment:
      - NODE_ENV=production
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8088/health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
YAML

docker compose up -d

echo "SELESAI node_exporter(:9100) + cadvisor(:8080) + app(:8088) jalan."
echo "Pastikan firewall hanya mengizinkan IP VM monitoring akses port 9100 & 8080."