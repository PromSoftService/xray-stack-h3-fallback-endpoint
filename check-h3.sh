#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ ! -f ".env" ]]; then
  echo "ERROR: .env not found"
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

log() {
  echo
  echo "== $* =="
}

print_file() {
  local title="$1"
  local file="$2"

  echo
  echo "===== ${title} (${file}) ====="
  if [[ -f "$file" ]]; then
    sed -n '1,400p' "$file"
  else
    echo "FILE NOT FOUND"
  fi
}

log "Recreate services"
docker compose down || true
docker compose up -d --force-recreate

log "docker compose ps"
docker compose ps || true

log "Rendered configs and artifacts"
print_file "xray config" "xray/config.json"
print_file "nginx config" "nginx/conf.d/default.conf"
print_file "generated client env" "generated/client.env"
print_file "generated client config" "generated/client-config.json"
print_file "environment" ".env"

log "Xray config syntax"
docker run --rm \
  --network host \
  -v "$ROOT_DIR/xray:/usr/local/etc/xray:ro" \
  "$XRAY_IMAGE" \
  run -test -config /usr/local/etc/xray/config.json || true

log "nginx runtime config syntax"
docker compose exec nginx nginx -t || true

log "nginx image build flags"
docker run --rm "${NGINX_IMAGE}" nginx -V 2>&1 | tee /tmp/nginx-v.txt || true
grep -- --with-http_v3_module /tmp/nginx-v.txt || true

log "Generated nginx directives"
grep -nE 'listen 80|listen 443|http2|http3|Alt-Svc|QUIC-Status|ssl_certificate|ssl_certificate_key' nginx/conf.d/default.conf || true

log "Host listening sockets"
ss -ltnp | grep ':443' || true
ss -lunp | grep ':443' || true
ss -ltnp | grep ':80' || true

log "HTTP test"
curl -I --max-time 20 "http://${DOMAIN}" || true

log "HTTPS test"
curl -I --max-time 20 "https://${DOMAIN}" || true

log "HTTP/3 test with curl"
curl -I --http3 --max-time 20 "https://${DOMAIN}" || true

log "QUIC status header"
curl -I --http3 --max-time 20 "https://${DOMAIN}" | grep -i 'quic-status' || true

if [[ -f "check_h3.py" ]]; then
  log "check_h3.py"
  python3 check_h3.py "https://${DOMAIN}" || true
else
  log "check_h3.py"
  echo "check_h3.py not found, skipping"
fi

log "Container logs snapshot: xray"
docker compose logs --tail=200 xray || true

log "Container logs snapshot: nginx"
docker compose logs --tail=200 nginx || true

log "Follow logs (Ctrl+C to stop)"
docker compose logs -f nginx xray