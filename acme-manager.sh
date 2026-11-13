#!/usr/bin/env bash
# SolarLogger ACME certificate maintenance for certbot-managed broker certificates.
set -Eeuo pipefail
umask 077
usage(){ printf '%s\n' 'Usage: solarlogger-acme status | renew | test | show'; }
(( EUID == 0 )) || { echo 'Run as root.' >&2; exit 1; }
[[ -r /etc/solarlogger/mqtt-acme.conf ]] || { echo 'ACME is not managed by SolarLogger on this host (manual certificate mode).' >&2; exit 1; }
source /etc/solarlogger/mqtt-acme.conf
[[ "${CERT_DOMAIN:-}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || { echo 'Invalid ACME domain.' >&2; exit 1; }
command -v certbot >/dev/null || { echo 'certbot is not installed.' >&2; exit 1; }
case "${1:-}" in
  status)
    certbot certificates --cert-name "$CERT_DOMAIN"
    openssl x509 -in /etc/mosquitto/certs/fullchain.pem -noout -subject -issuer -dates
    systemctl is-active mosquitto
    systemctl is-enabled certbot.timer || true
    ;;
  show)
    openssl x509 -in /etc/mosquitto/certs/fullchain.pem -noout -subject -issuer -dates -ext subjectAltName
    ;;
  test)
    certbot renew --cert-name "$CERT_DOMAIN" --dry-run
    ;;
  renew)
    certbot renew --cert-name "$CERT_DOMAIN"
    ;;
  *) usage; exit 2;;
esac
