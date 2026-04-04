#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ ! -f ".env" ]]; then
  echo "ERROR: .env not found. Create it from .env.example first."
  exit 1
fi

set -a
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

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

replace_token() {
  local file="$1"
  local token="$2"
  local value="$3"
  sed -i "s/${token}/$(escape_sed "$value")/g" "$file"
}

replace_token xray/config.json "__XRAY_LOGLEVEL__" "$XRAY_LOGLEVEL"
replace_token xray/config.json "__DOH_URL__" "$DOH_URL"
replace_token xray/config.json "__XRAY_PORT__" "$XRAY_PORT"
replace_token xray/config.json "__XRAY_UUID__" "$XRAY_UUID"
replace_token xray/config.json "__XRAY_PATH__" "$XRAY_PATH"
replace_token xray/config.json "__XRAY_XHTTP_MODE__" "$XRAY_XHTTP_MODE"

CERT_DIR="certbot/conf/live/${DOMAIN}"
if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
  echo "Certificate found. Generating full TLS + H3/H2 nginx config..."
  cp nginx/conf.d/default.conf.template nginx/conf.d/default.conf
  replace_token nginx/conf.d/default.conf "__DOMAIN__" "$DOMAIN"
  replace_token nginx/conf.d/default.conf "__XRAY_PATH__" "$XRAY_PATH"
  replace_token nginx/conf.d/default.conf "__XRAY_PORT__" "$XRAY_PORT"
  replace_token nginx/conf.d/default.conf "__NGINX_HTTP2__" "$NGINX_HTTP2"
  replace_token nginx/conf.d/default.conf "__NGINX_HTTP3__" "$NGINX_HTTP3"
  replace_token nginx/conf.d/default.conf "__NGINX_ALTSVC_MAX_AGE__" "$NGINX_ALTSVC_MAX_AGE"
  replace_token nginx/conf.d/default.conf "__NGINX_HSTS_MAX_AGE__" "$NGINX_HSTS_MAX_AGE"
  replace_token nginx/conf.d/default.conf "__NGINX_PROXY_READ_TIMEOUT__" "$NGINX_PROXY_READ_TIMEOUT"
  replace_token nginx/conf.d/default.conf "__NGINX_PROXY_SEND_TIMEOUT__" "$NGINX_PROXY_SEND_TIMEOUT"
else
  echo "Certificate not found yet. Generating bootstrap HTTP-only nginx config for ACME..."
  cp nginx/conf.d/bootstrap.conf.template nginx/conf.d/default.conf
  replace_token nginx/conf.d/default.conf "__DOMAIN__" "$DOMAIN"
fi

echo
echo "Generated files:"
echo "  xray/config.json"
echo "  nginx/conf.d/default.conf"
echo

echo "Starting xray and nginx..."
docker compose up -d xray nginx
echo

if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
  echo "TLS certificate already present. nginx should now serve HTTPS + HTTP/3 + H2 fallback."
else
  echo "Issue certificate with:"
  echo "docker compose run --rm certbot certonly --webroot -w /var/www/certbot -d ${DOMAIN} --email ${EMAIL} --agree-tos --no-eff-email"
  echo
  echo "Then run again:"
  echo "./init.sh"
fi

echo
