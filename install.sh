#!/usr/bin/env bash
# New Debian/Ubuntu host only. Download, inspect, then run interactively as root.
set -Eeuo pipefail
umask 077
die(){ echo "ERROR: $*" >&2; exit 1; }
usage(){ echo 'Add --guided for stage-by-stage terminal pauses.'; echo 'Usage: sudo bash install.sh --ip <SERVER_IP> [--email ops@example.com]'; echo '   or: sudo bash install.sh --domain mqtt.example.com --email ops@example.com'; echo '   or: sudo bash install.sh --host <SERVER_IP> --cert /path/fullchain.pem --key /path/privkey.pem'; }
HOST='' DOMAIN='' IP='' EMAIL='' CERT='' KEY=''
GUIDED=0
checkpoint(){ if (( GUIDED )); then printf '\n[PAUSE] %s\n' "$1"; read -r -p 'Press ENTER to continue: ' </dev/tty; fi; }
while (( $# )); do
  if [[ "$1" == '--guided' ]]; then GUIDED=1; shift; continue; fi
  (( $# >= 2 )) || { usage; exit 2; }
  case "$1" in
    --host) HOST=$2;; --domain) DOMAIN=$2;; --ip) IP=$2;; --email) EMAIL=$2;;
    --cert) CERT=$2;; --key) KEY=$2;;
    *) usage; exit 2;;
  esac
  shift 2
done
(( EUID == 0 )) || die 'Run as root'
[[ -t 0 ]] || die 'Interactive terminal required; do not pipe wget into bash'
command -v apt-get >/dev/null || die 'Debian/Ubuntu with apt required'
if [[ -n "$IP" ]]; then
  [[ -z "$DOMAIN" && -z "$HOST" && -z "$CERT" && -z "$KEY" ]] || die 'Use --ip alone, optionally with --email'
  python3 -c 'import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); assert ip.version == 4 and ip.is_global, "Public IPv4 required"' "$IP" || die 'Invalid public IPv4 address'
  HOST=$IP
elif [[ -n "$DOMAIN" ]]; then
  [[ -z "$HOST" && -z "$CERT" && -z "$KEY" && "$EMAIL" == *@* ]] || die 'Use --domain and --email only'
  [[ "$DOMAIN" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || die 'Invalid domain'
  HOST=$DOMAIN
else
  [[ -n "$HOST" && -f "$CERT" && -f "$KEY" ]] || { usage; exit 2; }
fi
[[ ! -e /etc/mosquitto/conf.d/solarlogger.conf ]] || die 'Existing SolarLogger config; refusing overwrite'
[[ ! -e /var/lib/mosquitto/dynamic-security.json ]] || die 'Existing DynSec database; refusing overwrite'
[[ ! -e /root/solarlogger-mqtt-credentials.env ]] || die 'Existing secrets file; refusing overwrite'
if grep -RhEq '^[[:space:]]*(listener|password_file|acl_file|plugin)[[:space:]]+' /etc/mosquitto/mosquitto.conf /etc/mosquitto/conf.d 2>/dev/null; then
  die 'Existing broker listeners/auth; use migration runbook, not fresh install'
fi
checkpoint 'Preflight passed. Next: OS packages; no MQTT credentials yet.'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y mosquitto mosquitto-clients python3-paho-mqtt apparmor-utils openssl ca-certificates expect git curl
checkpoint 'OS packages installed. Next: obtain TLS certificate via ACME.'
if [[ -n "$IP" ]]; then
  # Short-lived IP certificates (~6 days): standalone HTTP-01 needs inbound TCP/80.
  # acme.sh uses cron for renewals, and install-cert's reloadcmd redeploys to Mosquitto.
  ss -lnt | grep -Eq '(^|[[:space:]])[^[:space:]]+:80[[:space:]]' &&
    die 'TCP/80 in use: cannot perform standalone ACME IP validation'
  git clone --depth 1 https://github.com/acmesh-official/acme.sh.git /root/solarlogger-acme-src
  if [[ -n "$EMAIL" ]]; then
    (cd /root/solarlogger-acme-src && ./acme.sh --install --home /root/.acme.sh --accountemail "$EMAIL")
  else
    (cd /root/solarlogger-acme-src && ./acme.sh --install --home /root/.acme.sh)
  fi
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
  /root/.acme.sh/acme.sh --issue -d "$IP" --standalone \
    --server letsencrypt --cert-profile shortlived --days 3
  install -d -o root -g mosquitto -m 750 /etc/mosquitto/certs
  # A renewal hook will re-copy keys and restart broker on successful renewal.
  cat >/usr/local/sbin/solarlogger-acme-deploy <<'DEPLOY'
#!/usr/bin/env bash
set -Eeuo pipefail
chown root:mosquitto /etc/mosquitto/certs/fullchain.pem /etc/mosquitto/certs/privkey.pem
chmod 640 /etc/mosquitto/certs/fullchain.pem /etc/mosquitto/certs/privkey.pem
systemctl try-restart mosquitto
DEPLOY
  chmod 700 /usr/local/sbin/solarlogger-acme-deploy
  /root/.acme.sh/acme.sh --install-cert -d "$IP" \
    --key-file /etc/mosquitto/certs/privkey.pem \
    --fullchain-file /etc/mosquitto/certs/fullchain.pem \
    --reloadcmd /usr/local/sbin/solarlogger-acme-deploy
  /usr/local/sbin/solarlogger-acme-deploy
  CERT=/etc/mosquitto/certs/fullchain.pem
  KEY=/etc/mosquitto/certs/privkey.pem
fi
if [[ -n "$DOMAIN" ]]; then
  apt-get install -y certbot
  certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"
  CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
fi
[[ -r "$CERT" && -r "$KEY" ]] || die 'TLS files unreadable'
checkpoint 'TLS certificate obtained. Next: initialize Mosquitto, AppArmor and DynSec.'
PLUGIN=$(find /usr/lib -type f -name mosquitto_dynamic_security.so -print -quit)
[[ -n "$PLUGIN" ]] || die 'DynSec plugin missing'

install -d -m 700 /root/mosquitto-backups
tar -czpf "/root/mosquitto-backups/pre-solarlogger-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" -C /etc mosquitto
install -d -o root -g mosquitto -m 750 /etc/mosquitto/certs
if [[ "$CERT" != /etc/mosquitto/certs/fullchain.pem ]]; then
  install -o root -g mosquitto -m 640 "$CERT" /etc/mosquitto/certs/fullchain.pem
fi
if [[ "$KEY" != /etc/mosquitto/certs/privkey.pem ]]; then
  install -o root -g mosquitto -m 640 "$KEY" /etc/mosquitto/certs/privkey.pem
fi
systemctl stop mosquitto || true
# Generate all passwords on the VPS using a CSPRNG. No passwords in CLI argv,
# repository, interactive prompt, shell history or stdout before final summary.
install -m 600 /dev/null /root/solarlogger-mqtt-credentials.env
python3 - <<'SECRETS' >>/root/solarlogger-mqtt-credentials.env
import secrets
for key in (
    'SOLARLOGGER_BROKER_ADMIN_PASSWORD',
    'SOLARLOGGER_MQTT_PASSWORD',
    'SOLARLOGGER_DYNSEC_PASSWORD',
):
    print(key+'='+secrets.token_urlsafe(36))
for key,prefix in (('SOLARLOGGER_BROKER_ADMIN_USERNAME','solarlogger-broker-admin'),('SOLARLOGGER_MQTT_USERNAME','solarlogger-cloud-worker'),('SOLARLOGGER_DYNSEC_USERNAME','solarlogger-cloud-provisioner')):
    print(key+'='+prefix+'-'+secrets.token_hex(6))
SECRETS
# mosquitto_ctrl init asks twice on a TTY; Expect supplies a random value
# directly from the root-only file without leaking it via ps or the terminal.
expect <<'BOOTSTRAP'
set timeout 30
log_user 0
set f [open "/root/solarlogger-mqtt-credentials.env" r]
set data [read $f]
close $f
if {![regexp -line {^SOLARLOGGER_BROKER_ADMIN_PASSWORD=(.+)$} $data -> adminpw]} {
    puts stderr "Cannot read generated bootstrap password"
    exit 1
}
if {![regexp -line {^SOLARLOGGER_BROKER_ADMIN_USERNAME=(.+)$} $data -> adminuser]} {
    puts stderr "Cannot read generated admin username"
    exit 1
}
spawn mosquitto_ctrl dynsec init /var/lib/mosquitto/dynamic-security.json $adminuser
expect {
    -re {New password for .*:} {send -- "$adminpw\r"}
    timeout {puts stderr "Timed out initializing DynSec admin"; exit 1}
    eof {puts stderr "mosquitto_ctrl exited before asking password"; exit 1}
}
expect {
    -re {Reenter password for .*:} {send -- "$adminpw\r"}
    timeout {puts stderr "Timed out confirming DynSec password"; exit 1}
    eof {puts stderr "mosquitto_ctrl exited before confirmation"; exit 1}
}
expect eof
set status [wait]
if {[lindex $status 3] != 0} {
    puts stderr "mosquitto_ctrl dynsec init failed"
    exit 1
}
puts "Generated random administrator password and initialized DynSec"
BOOTSTRAP
chown mosquitto:mosquitto /var/lib/mosquitto/dynamic-security.json
chmod 600 /var/lib/mosquitto/dynamic-security.json
if [[ -f /etc/apparmor.d/mosquitto ]]; then
  grep -Fq 'include if exists <local/mosquitto>' /etc/apparmor.d/mosquitto || die 'AppArmor local include missing'
  install -d -m 755 /etc/apparmor.d/local
  cat >>/etc/apparmor.d/local/mosquitto <<'RULES'

# SolarLogger Dynamic Security
/var/lib/mosquitto/dynamic-security.json rwk,
/var/lib/mosquitto/dynamic-security.json.new rwk,
RULES
  apparmor_parser -r /etc/apparmor.d/mosquitto
fi
cat >/etc/mosquitto/conf.d/solarlogger.conf <<EOF
per_listener_settings false
allow_anonymous false
plugin $PLUGIN
plugin_opt_config_file /var/lib/mosquitto/dynamic-security.json
listener 1883 127.0.0.1
protocol mqtt
listener 8883 0.0.0.0
protocol mqtt
certfile /etc/mosquitto/certs/fullchain.pem
keyfile /etc/mosquitto/certs/privkey.pem
tls_version tlsv1.2
EOF
chmod 644 /etc/mosquitto/conf.d/solarlogger.conf
systemctl enable --now mosquitto
systemctl is-active --quiet mosquitto || die 'Broker did not start: journalctl -u mosquitto'
checkpoint 'Mosquitto TLS listener started. Next: create randomized service accounts.'
# Bootstrap accounts using broker API via loopback; no plaintext passwords in command arguments.
python3 - <<'PY'
import json, os, queue, secrets, threading
import paho.mqtt.client as mqtt
from pathlib import Path
values = {}
for line in Path('/root/solarlogger-mqtt-credentials.env').read_text().splitlines():
    key, value = line.split('=', 1)
    values[key] = value
admin = values['SOLARLOGGER_BROKER_ADMIN_PASSWORD']
adminuser = values['SOLARLOGGER_BROKER_ADMIN_USERNAME']
workeruser = values['SOLARLOGGER_MQTT_USERNAME']
provisioneruser = values['SOLARLOGGER_DYNSEC_USERNAME']
worker = values['SOLARLOGGER_MQTT_PASSWORD']
provisioner = values['SOLARLOGGER_DYNSEC_PASSWORD']
c = mqtt.Client(client_id='solarlogger-bootstrap-'+secrets.token_hex(4), protocol=mqtt.MQTTv311)
c.username_pw_set(adminuser, admin)
ready, subscribed, q = threading.Event(), threading.Event(), queue.Queue()
def on_connect(client, userdata, flags, code):
    if code == 0: ready.set()
def on_subscribe(client, userdata, mid, qos):
    subscribed.set()
def on_message(client, userdata, msg):
    q.put(msg.payload)
c.on_connect, c.on_subscribe, c.on_message = on_connect, on_subscribe, on_message
c.connect('127.0.0.1',1883,30)
c.loop_start()
def send(cmd):
    c.publish('$CONTROL/dynamic-security/v1',json.dumps({'commands':[cmd]}),qos=1)
    try: response=json.loads(q.get(timeout=10))['responses'][0]
    except queue.Empty: raise RuntimeError('DynSec timeout: partial setup possible')
    if response.get('command') != cmd['command'] or 'error' in response:
        raise RuntimeError('DynSec rejected '+cmd['command']+': '+str(response.get('error')))
try:
    if not ready.wait(10): raise RuntimeError('Admin authentication failed')
    c.subscribe('$CONTROL/dynamic-security/v1/response',qos=1)
    if not subscribed.wait(10): raise RuntimeError('Admin subscription failed')
    base='solarlogger/v1/devices/+/'
    w=[{'acltype':kind,'topic':base+suffix,'allow':True,'priority':10}
       for suffix in ('telemetry','state','events','ack')
       for kind in ('subscribeLiteral','publishClientReceive')]
    w.append({'acltype':'publishClientSend','topic':base+'cmd','allow':True,'priority':10})
    p=[{'acltype':kind,'topic':topic,'allow':True,'priority':10} for kind,topic in (
        ('publishClientSend','$CONTROL/dynamic-security/v1'),
        ('subscribeLiteral','$CONTROL/dynamic-security/v1/response'),
        ('publishClientReceive','$CONTROL/dynamic-security/v1/response'))]
    send({'command':'createRole','rolename':'solarlogger-cloud-worker','acls':w})
    send({'command':'createRole','rolename':'solarlogger-cloud-provisioner','acls':p})
    for name,password,role in (
        (workeruser,worker,'solarlogger-cloud-worker'),
        (provisioneruser,provisioner,'solarlogger-cloud-provisioner')):
        send({'command':'createClient','username':name,'password':password,
              'roles':[{'rolename':role,'priority':10}]})
        print('Created:',name)
finally:
    c.loop_stop()
    c.disconnect()
print('Generated service accounts. Passwords remain in root-only /root/solarlogger-mqtt-credentials.env (0600)')
PY
if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  openssl s_client -connect "$HOST:8883" -verify_ip "$HOST" -verify_return_error </dev/null >/dev/null 2>&1 || die 'TLS IP SAN/chain verification failed'
else
  openssl s_client -connect "$HOST:8883" -verify_hostname "$HOST" -verify_return_error </dev/null >/dev/null 2>&1 || die 'TLS DNS SAN/chain verification failed'
fi
if [[ -n "$DOMAIN" ]]; then
  cat >/etc/letsencrypt/renewal-hooks/deploy/solarlogger-mosquitto.sh <<EOF
#!/bin/bash
set -e
install -o root -g mosquitto -m 640 /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/mosquitto/certs/fullchain.pem
install -o root -g mosquitto -m 640 /etc/letsencrypt/live/$DOMAIN/privkey.pem /etc/mosquitto/certs/privkey.pem
systemctl restart mosquitto
EOF
  chmod 700 /etc/letsencrypt/renewal-hooks/deploy/solarlogger-mosquitto.sh
  install -d -m 700 /etc/solarlogger
  printf 'CERT_DOMAIN=%q\n' "$DOMAIN" >/etc/solarlogger/mqtt-acme.conf
  chmod 600 /etc/solarlogger/mqtt-acme.conf
  cat >/usr/local/sbin/solarlogger-acme <<'ACME_MANAGER'
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
ACME_MANAGER
  chmod 700 /usr/local/sbin/solarlogger-acme
  systemctl enable --now certbot.timer || true
fi
checkpoint 'Provisioning finished and TLS checked. Next: display sensitive credentials on your terminal. Do not share screenshots.'
printf '\n'
printf '%s\n' '==========================================================='
printf '%s\n' '        SOLARLOGGER MQTT — INSTALLATION COMPLETE'
printf '%s\n' '==========================================================='
printf 'Broker host:             %s\n' "$HOST"
printf '%s\n' 'MQTT over TLS port:      8883 (remote)'
printf '%s\n' 'MQTT plain port:         1883 (127.0.0.1 only)'
printf 'Mosquitto version:       %s\n' "$(mosquitto -h 2>&1 | head -1)"
printf '%s\n' 'Authentication:          Dynamic Security'
if [[ -n "$IP" ]]; then
  printf '%s\n' 'ACME issuer:             Lets Encrypt short-lived IP certificate (acme.sh)'
  printf 'ACME IP:                 %s\n' "$IP"
  printf '%s\n' 'ACME renewal:            acme.sh cron + certificate reload hook'
elif [[ -n "$DOMAIN" ]]; then
  printf '%s\n' 'ACME issuer:             Lets Encrypt (Certbot standalone)'
  printf 'ACME domain:             %s\n' "$DOMAIN"
  printf '%s\n' 'ACME management:         sudo solarlogger-acme status|show|test|renew'
  printf '%s\n' 'ACME renewal:            certbot.timer + deploy hook'
else
  printf '%s\n' 'TLS certificates:        externally provided; renewal is manual'
fi
printf 'Admin username:          %s\n' "$(grep '^SOLARLOGGER_BROKER_ADMIN_USERNAME=' /root/solarlogger-mqtt-credentials.env | cut -d= -f2-)"
printf 'Cloud Worker username:   %s\n' "$(grep '^SOLARLOGGER_MQTT_USERNAME=' /root/solarlogger-mqtt-credentials.env | cut -d= -f2-)"
printf 'Provisioner username:    %s\n' "$(grep '^SOLARLOGGER_DYNSEC_USERNAME=' /root/solarlogger-mqtt-credentials.env | cut -d= -f2-)"
printf '%s\n' '-----------------------------------------------------------'
printf '%s\n' 'ADMIN PASSWORD (root-only; do NOT put in Laravel .env):'
grep '^SOLARLOGGER_BROKER_ADMIN_PASSWORD=' /root/solarlogger-mqtt-credentials.env
printf '%s\n' '-----------------------------------------------------------'
printf '%s\n' 'COPY THE BLOCK BELOW TO PRIVATE Laravel Cloud .env:'
printf '%s\n' '-----------------------------------------------------------'
printf '%s\n' 'SOLARLOGGER_MQTT_ENABLED=true'
printf 'SOLARLOGGER_MQTT_HOST=%s\n' "$HOST"
printf '%s\n' 'SOLARLOGGER_MQTT_PORT=8883'
grep '^SOLARLOGGER_MQTT_USERNAME=' /root/solarlogger-mqtt-credentials.env
grep '^SOLARLOGGER_MQTT_PASSWORD=' /root/solarlogger-mqtt-credentials.env
printf '%s\n' 'SOLARLOGGER_MQTT_TLS=true'
printf '%s\n' 'SOLARLOGGER_MQTT_CLIENT_ID=solarlogger-cloud-worker'
printf '%s\n' ''
printf '%s\n' 'SOLARLOGGER_DYNSEC_ENABLED=true'
printf 'SOLARLOGGER_DYNSEC_HOST=%s\n' "$HOST"
printf '%s\n' 'SOLARLOGGER_DYNSEC_PORT=8883'
grep '^SOLARLOGGER_DYNSEC_USERNAME=' /root/solarlogger-mqtt-credentials.env
grep '^SOLARLOGGER_DYNSEC_PASSWORD=' /root/solarlogger-mqtt-credentials.env
printf '%s\n' 'SOLARLOGGER_DYNSEC_TLS=true'
printf '%s\n' '-----------------------------------------------------------'
printf '%s\n' 'Passwords generated with Python secrets; shown ONCE here.'
printf '%s\n' 'A root-only copy is saved to /root/solarlogger-mqtt-credentials.env (0600).'
printf '%s\n' 'This console output contains secrets: do not share screenshots/logs.'
printf '%s\n' 'After .env setup: php artisan config:clear && php artisan mqtt:dynsec-check --probe'
printf '%s\n' '==========================================================='
