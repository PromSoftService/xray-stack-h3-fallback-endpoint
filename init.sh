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

mkdir -p nginx/conf.d xray site certbot/www certbot/conf

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

if [[ "${VERIFY_HTTP3_IMAGE:-yes}" == "yes" ]]; then
  echo "Checking nginx image for --with-http_v3_module..."
  if ! docker run --rm "${NGINX_IMAGE}" nginx -V 2>&1 | grep -q -- '--with-http_v3_module'; then
    echo "ERROR: nginx image does not include --with-http_v3_module"
    exit 1
  fi
fi

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

prepare_cert_permissions() {
  local live_dir="certbot/conf/live/${DOMAIN}"
  local archive_dir="certbot/conf/archive/${DOMAIN}"

  if [[ ! -d "$live_dir" || ! -d "$archive_dir" ]]; then
    echo "ERROR: certificate directories not found for domain ${DOMAIN}"
    exit 1
  fi

  chmod 755 certbot/conf/live
  chmod 755 certbot/conf/archive
  chmod 755 "$live_dir"
  chmod 755 "$archive_dir"

  shopt -s nullglob
  local fullchain_files=("$archive_dir"/fullchain*.pem)
  local privkey_files=("$archive_dir"/privkey*.pem)
  shopt -u nullglob

  if [[ ${#fullchain_files[@]} -eq 0 ]]; then
    echo "ERROR: fullchain*.pem not found in $archive_dir"
    exit 1
  fi

  if [[ ${#privkey_files[@]} -eq 0 ]]; then
    echo "ERROR: privkey*.pem not found in $archive_dir"
    exit 1
  fi

  chmod 644 "${fullchain_files[@]}"
  chmod 644 "${privkey_files[@]}"

  echo "Adjusted certificate permissions for rootless nginx."
}

XRAY_PATH_NORMALIZED="$(normalize_path "$XRAY_PATH")"

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

if [[ ! -f xray/config.json.template ]]; then
  echo "ERROR: xray/config.json.template not found"
  exit 1
fi

if [[ ! -f nginx/conf.d/default.conf.template ]]; then
  echo "ERROR: nginx/conf.d/default.conf.template not found"
  exit 1
fi

if [[ ! -f nginx/conf.d/bootstrap.conf.template ]]; then
  echo "ERROR: nginx/conf.d/bootstrap.conf.template not found"
  exit 1
fi

cp xray/config.json.template xray/config.json

replace_token xray/config.json "__XRAY_LOGLEVEL__" "$XRAY_LOGLEVEL"
replace_token xray/config.json "__DOH_URL__" "$DOH_URL"
replace_token xray/config.json "__XRAY_PORT__" "$XRAY_PORT"
replace_token xray/config.json "__XRAY_UUID__" "$XRAY_UUID"
replace_token xray/config.json "__XRAY_PATH__" "$XRAY_PATH_NORMALIZED"
replace_token xray/config.json "__XRAY_XHTTP_MODE__" "$XRAY_XHTTP_MODE"

CERT_DIR="certbot/conf/live/${DOMAIN}"

if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
  echo "Certificate found. Generating full TLS + H3/H2 nginx config..."
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

  MODE_MESSAGE="TLS certificate present. nginx should serve HTTPS + HTTP/3 + H2 fallback."
else
  echo "Certificate not found. Generating bootstrap HTTP-only nginx config for ACME..."
  cp nginx/conf.d/bootstrap.conf.template nginx/conf.d/default.conf
  replace_token nginx/conf.d/default.conf "__DOMAIN__" "$DOMAIN"

  MODE_MESSAGE="Bootstrap mode enabled. Only HTTP/80 is expected until certificate is issued."
fi

echo
echo "Generated files:"
echo "  xray/config.json"
echo "  nginx/conf.d/default.conf"

echo
echo "Starting xray and nginx..."
docker compose up -d xray nginx

echo
echo "Reloading generated configs..."
docker compose restart xray nginx

echo
echo "${MODE_MESSAGE}"

echo
echo "===== xray/config.json ====="
sed -n '1,240p' xray/config.json

echo
echo "===== nginx/conf.d/default.conf ====="
sed -n '1,260p' nginx/conf.d/default.conf