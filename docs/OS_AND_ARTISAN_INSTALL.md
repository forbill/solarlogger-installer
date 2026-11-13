## Supported operating systems and a safe installation boundary

The **Mosquitto VPS** installer is Linux-specific. It supports Ubuntu and Debian on a native Linux host only.

```bash
# Read-only diagnostic; does not need root:
bash platform-check.sh
# Real server install after reviewing the script:
sudo bash install.sh --guided --ip PUBLIC_IPV4
```

Before asking for root access, installing packages, opening ACME validation, or changing Mosquitto, `install.sh` sources `platform-check.sh` and exits unless the host is native Ubuntu/Debian with `apt-get`.

The following modes are rejected with a clear explanation and **no package installation**: Windows Git Bash, MSYS2, Cygwin, macOS, WSL, Fedora, RHEL, Alpine, and unknown operating systems. Windows PowerShell cannot execute this Bash installer directly; do not attempt to run Linux `apt-get` or `systemctl` there.

Run local contract tests on a Linux development machine:

```bash
bash -n install.sh
bash -n platform-check.sh
bash tests/test-platform.sh
```

### Planned unified Laravel installer

The actual Laravel application must own the interactive `php artisan solarlogger:install` command and its Laravel Prompts interface. The native Linux bootstrap installer first checks the OS and prerequisites, then starts Artisan. On Windows, Artisan must offer **Windows-safe local configuration/diagnostics** only, without calling `apt`, `systemctl`, certbot or OS package managers.

The installer repository currently contains the **Mosquitto bootstrap** only; it does not yet include a deployable Laravel app or an implemented Artisan command. The required next integration is to introduce that command in the **current Laravel Cloud repository**, not in the historical FastAPI code, with explicit OS-specific service adapters. Never pretend an unlinked command is installed.

A second run must not rotate MQTT credentials or certificates, rewrite foreign Mosquitto instances, or duplicate ACME renewal jobs. That idempotent upgrade workflow remains an explicit follow-up and is not enabled by the platform guard.
