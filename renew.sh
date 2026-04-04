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

required_vars=(
  DOMAIN
  EMAIL
  CERTBOT_IMAGE
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: required variable '$var_name' is empty"
    exit 1
  fi
done

mkdir -p certbot/www certbot/conf

MODE="${1:-renew}"

log() {
  echo
  echo "== $* =="
}

cert_present() {
  [[ -f "certbot/conf/live/${DOMAIN}/fullchain.pem" && -f "certbot/conf/live/${DOMAIN}/privkey.pem" ]]
}

fix_cert_permissions() {
  local live_dir="certbot/conf/live/${DOMAIN}"
  local archive_dir="certbot/conf/archive/${DOMAIN}"

  if [[ ! -d "certbot/conf" ]]; then
    return 0
  fi

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

ensure_bootstrap_nginx() {
  log "Ensuring nginx is running for ACME webroot"
  docker compose up -d --force-recreate nginx
  sleep 2
}

issue_cert() {
  ensure_bootstrap_nginx

  log "Issuing new certificate for ${DOMAIN}"
  docker compose run --rm certbot certonly \
    --webroot -w /var/www/certbot \
    -d "${DOMAIN}" \
    --email "${EMAIL}" \
    --agree-tos \
    --no-eff-email \
    --non-interactive

  log "Fixing certificate permissions"
  fix_cert_permissions

  if cert_present; then
    echo
    echo "Certificate issued successfully for ${DOMAIN}"
  else
    echo
    echo "ERROR: certificate issuance command finished but certificate files were not found"
    echo "Check paths:"
    echo "  certbot/conf/live/${DOMAIN}/fullchain.pem"
    echo "  certbot/conf/live/${DOMAIN}/privkey.pem"
    exit 1
  fi
}

renew_cert() {
  ensure_bootstrap_nginx

  log "Renewing certificates"
  docker compose run --rm certbot renew --webroot -w /var/www/certbot

  log "Fixing certificate permissions"
  fix_cert_permissions
}

case "$MODE" in
  issue)
    fix_cert_permissions
    if cert_present; then
      echo "Certificate already exists for ${DOMAIN}. Nothing to issue."
      exit 0
    fi
    issue_cert
    ;;
  renew)
    fix_cert_permissions
    if cert_present; then
      renew_cert
    else
      echo "Certificate not found for ${DOMAIN}. Running issue instead."
      issue_cert
    fi
    ;;
  *)
    echo "Usage: $0 [issue|renew]"
    exit 1
    ;;
esac

echo
echo "Done."