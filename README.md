# SolarLogger MQTT Installer

Public standalone installer for a NEW Ubuntu/Debian VPS, using Mosquitto with Dynamic Security and TLS.

**Status (2026-11-13):** Guided first installation tested on Ubuntu 26.04.1 LTS (x86_64), Mosquitto 2.0.22. ACME IP certificate issuance, verified TLS connection, broker startup, DynSec account generation, role separation, and secret file permissions passed. **Automated ACME renewal, reboot recovery, and a second-install refusal test are not yet verified.**

## Install on a new server

Download, inspect and run (replace placeholders with your own values):

~~~bash
curl -fsSL https://raw.githubusercontent.com/forbill/solarlogger-installer/main/install.sh -o install.sh
less install.sh
bash -n install.sh
sudo bash install.sh --guided --ip <SERVER_IP>
~~~

The `--guided` flag pauses at each installation stage for review. This option obtains a short-lived ACME IP certificate. Inbound TCP/80 is required for certificate validation/renewal, TCP/8883 for encrypted MQTT. TCP/1883 binds to loopback only.

Alternatively, use a domain or supply an already issued trusted certificate:

~~~bash
sudo bash install.sh --domain <YOUR_DOMAIN> --email <YOUR_EMAIL>
sudo bash install.sh --host <SERVER_IP> --cert <FULLCHAIN_PATH> --key <PRIVATE_KEY_PATH>
~~~

The installer generates three independently randomized usernames (human-readable functional prefix + random suffix) and three independently randomized passwords. No static usernames or passwords are published in this README.

At completion it displays the generated credentials and a Laravel Cloud environment configuration block. An owner-only copy is stored under /root/solarlogger-mqtt-credentials.env (mode 0600). Do not post terminal output, credentials, screenshots or the actual configuration publicly.

## Diagnostics

~~~bash
systemctl status mosquitto --no-pager
ss -lntp
openssl x509 -in /etc/mosquitto/certs/fullchain.pem -noout -dates -ext subjectAltName
~~~

Then configure the private Laravel Cloud environment and run php artisan mqtt:dynsec-check --probe.

## Scope

New server only: refuses existing SolarLogger broker configuration or Dynamic Security database; does not migrate an old installation. This public repository contains no Cloud source code, actual server addresses, real user names or credentials.
## Verified installation checks

On the first Ubuntu 26.04.1 test, the broker passed TLS verification against its IP certificate, the telemetry service account could subscribe to permitted topics and was denied access to the administrative Dynamic Security channel. The independent provisioning account could subscribe to its authorized control-response channel. The generated secrets file was owned by root with permissions `0600`.

The service account login names and passwords are generated at runtime, and **must not be recorded in this public repository**. The admin password is not for use by Laravel Cloud. After deploying, verify automatic certificate renewal, then rotate any bootstrap SSH passwords that have been shared outside a secret manager.
