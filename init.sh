#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ ! -f ".env" ]]; then
  echo "ERROR: .env not found. Create it from .env.example first."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

echo "Checking sudo access..."
sudo -v

mkdir -p nginx/conf.d xray site certbot/www certbot/conf generated

required_vars=(
  DOMAIN
  EMAIL
  XRAY_UUID
  XRAY_PATH
  XRAY_PORT
  XRAY_LOGLEVEL
  XRAY_XHTTP_MODE
  DOH_URL
  NGINX_HTTP2
  NGINX_HTTP3
  NGINX_ALTSVC_MAX_AGE
  NGINX_HSTS_MAX_AGE
  NGINX_PROXY_READ_TIMEOUT
  NGINX_PROXY_SEND_TIMEOUT
  XRAY_IMAGE
  NGINX_IMAGE
  CERTBOT_IMAGE
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: required variable '$var_name' is empty"
    exit 1
  fi
done

log() {
  echo
  echo "== $* =="
}

normalize_path() {
  local value="$1"

  if [[ -z "$value" ]]; then
    echo "/"
    return
  fi

  if [[ "$value" != /* ]]; then
    value="/$value"
  fi

  if [[ "$value" != "/" && "$value" != */ ]]; then
    value="${value}/"
  fi

  echo "$value"
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

replace_token() {
  local file="$1"
  local token="$2"
  local value="$3"
  sed -i "s/${token}/$(escape_sed "$value")/g" "$file"
}

json_quote() {
  local value="$1"
  python3 - <<'PY' "$value"
import json
import sys
print(json.dumps(sys.argv[1], ensure_ascii=False))
PY
}

build_xhttp_host_fragment() {
  local host="${XRAY_XHTTP_HOST:-}"

  if [[ -z "$host" ]]; then
    echo ""
    return
  fi

  printf ', "host": %s' "$(json_quote "$host")"
}

build_xhttp_headers_json() {
  python3 - <<'PY'
import json
import os
import sys

domain = os.environ["DOMAIN"].strip()
headers_raw = os.environ.get("XRAY_XHTTP_HEADERS_JSON", "").strip()

if not headers_raw:
    print("")
    raise SystemExit(0)

try:
    headers = json.loads(headers_raw)
except json.JSONDecodeError as exc:
    print(f"ERROR: XRAY_XHTTP_HEADERS_JSON is not valid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(headers, dict):
    print("ERROR: XRAY_XHTTP_HEADERS_JSON must be a JSON object", file=sys.stderr)
    raise SystemExit(1)

if "Referer" not in headers and domain:
    headers["Referer"] = f"https://{domain}/"

print(json.dumps(headers, ensure_ascii=False, separators=(",", ":")))
PY
}

build_xhttp_extra_fragment() {
  local headers_json="$1"

  XRAY_HEADERS_JSON="$headers_json" python3 - <<'PY'
import json
import os

headers_raw = os.environ.get("XRAY_HEADERS_JSON", "").strip()
padding = os.environ.get("XRAY_XHTTP_PADDING_BYTES", "").strip()

extra = {}

if headers_raw:
    extra["headers"] = json.loads(headers_raw)

if padding:
    extra["xPaddingBytes"] = padding

if not extra:
    print("")
else:
    print(', "extra": ' + json.dumps(extra, ensure_ascii=False, separators=(",", ":")))
PY
}

validate_mux_settings() {
  local enabled="${XRAY_MUX_ENABLED:-no}"

  case "$enabled" in
    yes|no)
      ;;
    *)
      echo "ERROR: XRAY_MUX_ENABLED must be 'yes' or 'no'"
      exit 1
      ;;
  esac

  if [[ "$enabled" == "yes" ]]; then
    if ! [[ "${XRAY_MUX_CONCURRENCY:-}" =~ ^[0-9]+$ ]]; then
      echo "ERROR: XRAY_MUX_CONCURRENCY must be an integer"
      exit 1
    fi

    if ! [[ "${XRAY_MUX_XUDP_CONCURRENCY:-}" =~ ^[0-9]+$ ]]; then
      echo "ERROR: XRAY_MUX_XUDP_CONCURRENCY must be an integer"
      exit 1
    fi
  fi
}

verify_nginx_http3_image() {
  if [[ "${VERIFY_HTTP3_IMAGE:-yes}" == "yes" ]]; then
    log "Checking nginx image for --with-http_v3_module"
    if ! docker run --rm "${NGINX_IMAGE}" nginx -V 2>&1 | grep -q -- '--with-http_v3_module'; then
      echo "ERROR: nginx image does not include --with-http_v3_module"
      exit 1
    fi
  fi
}

prepare_cert_permissions() {
  local live_dir="certbot/conf/live/${DOMAIN}"
  local archive_dir="certbot/conf/archive/${DOMAIN}"

  sudo chmod 755 certbot/conf || true
  sudo chmod 755 certbot/conf/live || true
  sudo chmod 755 certbot/conf/archive || true

  if [[ -d "$live_dir" ]]; then
    sudo chmod 755 "$live_dir" || true
  fi

  if [[ -d "$archive_dir" ]]; then
    sudo chmod 755 "$archive_dir" || true
    sudo find "$archive_dir" -type f -name '*.pem' -exec chmod 644 {} \; || true
  fi
}

ensure_default_site() {
  if [[ ! -f site/index.html ]]; then
    cat > site/index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>OK</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
</head>
<body>
OK
</body>
</html>
HTML
  fi
}

check_required_files() {
  local required_files=(
    "xray/config.json.template"
    "nginx/conf.d/default.conf.template"
    "nginx/conf.d/bootstrap.conf.template"
    "generate_client_config.py"
    "docker-compose.yml"
    "renew.sh"
  )

  for f in "${required_files[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "ERROR: required file '$f' not found"
      exit 1
    fi
  done
}

generate_xray_config() {
  XRAY_PATH_NORMALIZED="$(normalize_path "$XRAY_PATH")"
  XRAY_FINGERPRINT_VALUE="${XRAY_FINGERPRINT:-chrome}"
  XRAY_XHTTP_HOST_FRAGMENT="$(build_xhttp_host_fragment)"
  XRAY_XHTTP_HEADERS_JSON_COMPACT="$(build_xhttp_headers_json)"
  XRAY_XHTTP_EXTRA_FRAGMENT="$(build_xhttp_extra_fragment "$XRAY_XHTTP_HEADERS_JSON_COMPACT")"

  validate_mux_settings

  cp xray/config.json.template xray/config.json

  replace_token xray/config.json "__XRAY_LOGLEVEL__" "$XRAY_LOGLEVEL"
  replace_token xray/config.json "__DOH_URL__" "$DOH_URL"
  replace_token xray/config.json "__XRAY_PORT__" "$XRAY_PORT"
  replace_token xray/config.json "__XRAY_UUID__" "$XRAY_UUID"
  replace_token xray/config.json "__XRAY_PATH__" "$XRAY_PATH_NORMALIZED"
  replace_token xray/config.json "__XRAY_XHTTP_MODE__" "$XRAY_XHTTP_MODE"
  replace_token xray/config.json "__XRAY_XHTTP_HOST_FRAGMENT__" "$XRAY_XHTTP_HOST_FRAGMENT"
  replace_token xray/config.json "__XRAY_XHTTP_EXTRA_FRAGMENT__" "$XRAY_XHTTP_EXTRA_FRAGMENT"

  cat > generated/client.env <<EOF2
DOMAIN=${DOMAIN}
XRAY_UUID=${XRAY_UUID}
XRAY_PATH=${XRAY_PATH_NORMALIZED}
DOH_URL=${DOH_URL}
XRAY_FINGERPRINT=${XRAY_FINGERPRINT_VALUE}
XRAY_XHTTP_MODE=${XRAY_XHTTP_MODE}
XRAY_XHTTP_HOST=${XRAY_XHTTP_HOST:-}
XRAY_XHTTP_HEADERS_JSON=${XRAY_XHTTP_HEADERS_JSON_COMPACT}
XRAY_XHTTP_PADDING_BYTES=${XRAY_XHTTP_PADDING_BYTES:-}
XRAY_MUX_ENABLED=${XRAY_MUX_ENABLED:-no}
XRAY_MUX_CONCURRENCY=${XRAY_MUX_CONCURRENCY:-8}
XRAY_MUX_XUDP_CONCURRENCY=${XRAY_MUX_XUDP_CONCURRENCY:-16}
XRAY_MUX_XUDP_PROXY_UDP_443=${XRAY_MUX_XUDP_PROXY_UDP_443:-reject}
EOF2

  chmod +x generate_client_config.py || true

  client_args=(
    "$DOMAIN"
    "$XRAY_UUID"
    "$XRAY_PATH_NORMALIZED"
    --doh "$DOH_URL"
    --remark "$DOMAIN h3 fallback"
    --fingerprint "$XRAY_FINGERPRINT_VALUE"
    --xhttp-mode "$XRAY_XHTTP_MODE"
    -o generated/client-config.json
  )

  if [[ -n "${XRAY_XHTTP_HOST:-}" ]]; then
    client_args+=(--xhttp-host "$XRAY_XHTTP_HOST")
  fi

  if [[ -n "$XRAY_XHTTP_HEADERS_JSON_COMPACT" ]]; then
    client_args+=(--xhttp-headers-json "$XRAY_XHTTP_HEADERS_JSON_COMPACT")
  fi

  if [[ -n "${XRAY_XHTTP_PADDING_BYTES:-}" ]]; then
    client_args+=(--xhttp-padding-bytes "$XRAY_XHTTP_PADDING_BYTES")
  fi

  if [[ "${XRAY_MUX_ENABLED:-no}" == "yes" ]]; then
    client_args+=(
      --mux-enabled
      --mux-concurrency "${XRAY_MUX_CONCURRENCY:-8}"
      --mux-xudp-concurrency "${XRAY_MUX_XUDP_CONCURRENCY:-16}"
      --mux-xudp-proxy-udp-443 "${XRAY_MUX_XUDP_PROXY_UDP_443:-reject}"
    )
  fi

  python3 generate_client_config.py "${client_args[@]}"
}

render_bootstrap_nginx() {
  cp nginx/conf.d/bootstrap.conf.template nginx/conf.d/default.conf
  replace_token nginx/conf.d/default.conf "__DOMAIN__" "$DOMAIN"
}

render_tls_nginx() {
  prepare_cert_permissions

  cp nginx/conf.d/default.conf.template nginx/conf.d/default.conf
  replace_token nginx/conf.d/default.conf "__DOMAIN__" "$DOMAIN"
  replace_token nginx/conf.d/default.conf "__XRAY_PATH__" "$XRAY_PATH_NORMALIZED"
  replace_token nginx/conf.d/default.conf "__XRAY_PORT__" "$XRAY_PORT"
  replace_token nginx/conf.d/default.conf "__NGINX_HTTP2__" "$NGINX_HTTP2"
  replace_token nginx/conf.d/default.conf "__NGINX_HTTP3__" "$NGINX_HTTP3"
  replace_token nginx/conf.d/default.conf "__NGINX_ALTSVC_MAX_AGE__" "$NGINX_ALTSVC_MAX_AGE"
  replace_token nginx/conf.d/default.conf "__NGINX_HSTS_MAX_AGE__" "$NGINX_HSTS_MAX_AGE"
  replace_token nginx/conf.d/default.conf "__NGINX_PROXY_READ_TIMEOUT__" "$NGINX_PROXY_READ_TIMEOUT"
  replace_token nginx/conf.d/default.conf "__NGINX_PROXY_SEND_TIMEOUT__" "$NGINX_PROXY_SEND_TIMEOUT"
}

cert_present() {
  [[ -f "certbot/conf/live/${DOMAIN}/fullchain.pem" && -f "certbot/conf/live/${DOMAIN}/privkey.pem" ]]
}

print_generated_files() {
  echo
  echo "===== xray/config.json ====="
  sed -n '1,260p' xray/config.json || true

  echo
  echo "===== nginx/conf.d/default.conf ====="
  sed -n '1,260p' nginx/conf.d/default.conf || true

  echo
  echo "===== generated/client.env ====="
  sed -n '1,160p' generated/client.env || true

  echo
  echo "===== generated/client-config.json ====="
  sed -n '1,320p' generated/client-config.json || true
}

start_bootstrap_nginx_for_acme() {
  log "Starting bootstrap nginx for ACME"
  docker compose up -d --force-recreate nginx
  sleep 2

  echo
  echo "Bootstrap nginx started. If certificate issuance fails, check:"
  echo "  - DOMAIN points to this VPS"
  echo "  - TCP/80 is open"
  echo "  - nothing else occupies port 80"
}

main() {
  log "Checking prerequisites"
  verify_nginx_http3_image
  ensure_default_site
  check_required_files

  log "Generating xray config and client artifacts"
  generate_xray_config

  if cert_present; then
    log "Certificate found. Rendering TLS + H3/H2 nginx config"
    render_tls_nginx

    log "Starting full stack"
    docker compose up -d --force-recreate

    print_generated_files

    echo
    echo "Done."
    echo "Certificate already exists."
    echo "Services started in HTTPS + HTTP/3 + HTTP/2 fallback mode."
    echo "Run ./check-h3.sh for deep diagnostics."
    exit 0
  fi

  log "Certificate not found. Rendering bootstrap HTTP-only nginx config"
  render_bootstrap_nginx

  log "Starting bootstrap mode"
  start_bootstrap_nginx_for_acme

  log "Issuing certificate via ./renew.sh"
  chmod +x renew.sh || true
  ./renew.sh issue

  if ! cert_present; then
    echo "ERROR: certificate still not found after ./renew.sh issue"
    exit 1
  fi

  log "Certificate issued. Rendering final TLS + H3/H2 nginx config"
  render_tls_nginx

  log "Starting full stack in final mode"
  docker compose up -d --force-recreate

  print_generated_files

  echo
  echo "Done."
  echo "Certificate issued and full stack started."
  echo "Run ./check-h3.sh for deep diagnostics."
}

main "$@"