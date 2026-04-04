#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

load_env() {
  if [[ -f ".env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source ".env"
    set +a
  fi
}

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

first_nonempty() {
  local candidate
  for candidate in "$@"; do
    candidate="$(trim "$candidate")"
    if [[ -n "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

build_domain_args() {
  local raw_domains="${1:-}"
  local domain
  local args=()

  IFS=',' read -r -a domain_list <<< "$raw_domains"
  for domain in "${domain_list[@]}"; do
    domain="$(trim "$domain")"
    if [[ -n "$domain" ]]; then
      args+=("-d" "$domain")
    fi
  done

  if [[ "${#args[@]}" -eq 0 ]]; then
    return 1
  fi

  printf '%s\n' "${args[@]}"
}

self_check_acme_webroot() {
  local probe_name="probe-$(date +%s)"
  local probe_rel=".well-known/acme-challenge/${probe_name}"
  local probe_fs="certbot/www/${probe_rel}"
  local probe_url="http://${PRIMARY_DOMAIN}/.well-known/acme-challenge/${probe_name}"
  local response

  mkdir -p "$(dirname "$probe_fs")"
  printf '%s\n' "acme-ok-${probe_name}" > "$probe_fs"

  echo
  echo "Checking ACME webroot mapping..."
  echo "Probe file: ${probe_fs}"
  echo "Probe URL : ${probe_url}"

  response="$(curl -fsS --max-time 10 "$probe_url" || true)"
  if [[ "$response" != "acme-ok-${probe_name}" ]]; then
    echo "ERROR: nginx does not serve ACME challenge file correctly."
    echo "Expected: acme-ok-${probe_name}"
    echo "Got     : ${response:-<empty>}"
    echo
    echo "Check these:"
    echo "  1. DNS for ${PRIMARY_DOMAIN} points to this VPS"
    echo "  2. Port 80 is reachable from the internet"
    echo "  3. nginx location /.well-known/acme-challenge/ serves ./certbot/www"
    rm -f "$probe_fs"
    exit 1
  fi

  rm -f "$probe_fs"
  echo "ACME webroot mapping looks good."
}

load_env

DOMAIN_CANDIDATES=(
  "${DOMAIN:-}"
  "${DOMAINS:-}"
  "${SERVER_NAME:-}"
  "${XRAY_DOMAIN:-}"
  "${CERTBOT_DOMAIN:-}"
)

EMAIL_CANDIDATES=(
  "${EMAIL:-}"
  "${ACME_EMAIL:-}"
  "${CERTBOT_EMAIL:-}"
  "${LETSENCRYPT_EMAIL:-}"
)

DOMAINS_RAW="$(first_nonempty "${DOMAIN_CANDIDATES[@]}")" || {
  echo "ERROR: domain is not set in .env"
  echo "Set one of: DOMAIN, DOMAINS, SERVER_NAME, XRAY_DOMAIN, CERTBOT_DOMAIN"
  exit 1
}

EMAIL_VALUE="$(first_nonempty "${EMAIL_CANDIDATES[@]}")" || {
  echo "ERROR: email is not set in .env"
  echo "Set one of: EMAIL, ACME_EMAIL, CERTBOT_EMAIL, LETSENCRYPT_EMAIL"
  exit 1
}

PRIMARY_DOMAIN="$(trim "${DOMAINS_RAW%%,*}")"
CERT_PATH="certbot/conf/live/${PRIMARY_DOMAIN}/fullchain.pem"

echo "Using domains: ${DOMAINS_RAW}"
echo "Using email: ${EMAIL_VALUE}"
echo "Primary domain: ${PRIMARY_DOMAIN}"

echo
echo "Ensuring bootstrap nginx/xray are up..."
./init.sh

if [[ ! -f "$CERT_PATH" ]]; then
  echo
  echo "Certificate not found for ${PRIMARY_DOMAIN}. Issuing initial certificate..."

  self_check_acme_webroot

  mapfile -t DOMAIN_ARGS < <(build_domain_args "$DOMAINS_RAW") || {
    echo "ERROR: failed to parse domains from value: ${DOMAINS_RAW}"
    exit 1
  }

  docker compose run --rm certbot \
    certonly \
    --webroot -w /var/www/certbot \
    "${DOMAIN_ARGS[@]}" \
    --email "${EMAIL_VALUE}" \
    --agree-tos \
    --no-eff-email
else
  echo
  echo "Certificate already exists for ${PRIMARY_DOMAIN}. Running renewal..."
  docker compose run --rm certbot renew
fi

echo
echo "Rebuilding configs after certificate step..."
./init.sh

echo
echo "===== xray/config.json ====="
sed -n '1,240p' xray/config.json

echo
echo "===== nginx/conf.d/default.conf ====="
sed -n '1,260p' nginx/conf.d/default.conf

echo
echo "Restarting xray and nginx..."
docker compose restart xray nginx

echo
echo "===== live logs ====="
docker compose logs --since=30s -f xray nginx