#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ ! -f ".env" ]]; then
  echo "ERROR: .env not found"
  exit 1
fi

set -a
source .env
set +a

echo "== 1. nginx image build flags =="
docker run --rm "${NGINX_IMAGE}" nginx -V 2>&1 | tee /tmp/nginx-v.txt
grep -- --with-http_v3_module /tmp/nginx-v.txt

echo
echo "== 2. nginx runtime config syntax =="
docker compose exec nginx nginx -t

echo
echo "== 3. generated nginx directives =="
grep -nE 'listen 443|http2|http3|Alt-Svc|QUIC-Status' nginx/conf.d/default.conf || true

echo
echo "== 4. host listening sockets =="
sudo ss -ltnp | grep ':443' || true
sudo ss -lunp | grep ':443' || true

echo
echo "== 5. container status =="
docker compose ps

echo
echo "== 6. HTTPS test =="
curl -I "https://${DOMAIN}" || true

echo
echo "== 7. HTTP/3 test =="
curl -I --http3 "https://${DOMAIN}" || true

echo
echo "== 8. QUIC status header =="
curl -I --http3 "https://${DOMAIN}" | grep -i 'quic-status' || true

echo
echo "Done."
