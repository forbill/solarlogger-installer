#!/usr/bin/env bash
# Source before any package installation, certificate issuance or privileged commands.
# Standalone execution is a read-only compatibility check.
set -Eeuo pipefail

solarlogger_platform_check() {
  local kernel distro id_like os_release
  kernel="${SOLARLOGGER_TEST_UNAME:-$(uname -s 2>/dev/null || printf unknown)}"
  case "$kernel" in
    Linux) ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      printf 'SolarLogger: Windows detected (%s). No Linux packages will be installed.\n' "$kernel" >&2
      printf 'On Windows use a local Laravel development workflow; deploy the server on Ubuntu/Debian.\n' >&2
      return 20 ;;
    *) printf 'SolarLogger: unsupported OS (%s). No system changes.\n' "$kernel" >&2; return 20 ;;
  esac

  if [[ "${SOLARLOGGER_TEST_WSL:-}" == 1 ]] ||
     { [[ "${SOLARLOGGER_TEST_WSL:-}" != 0 ]] &&
       { [[ -n "${WSL_DISTRO_NAME:-}" ]] ||
         grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; }; }; then
    printf 'SolarLogger: WSL detected. Production broker installation is blocked.\n' >&2
    return 21
  fi

  os_release="${SOLARLOGGER_TEST_OS_RELEASE:-/etc/os-release}"
  if [[ ! -f "$os_release" ]]; then
    printf 'SolarLogger: missing OS metadata; no system changes.\n' >&2
    return 22
  fi
  # Read only simple os-release values. Do not execute metadata as shell commands.
  distro="$(sed -n 's/^ID=//p' "$os_release" | head -1 | tr -d '"' | tr '[:upper:]' '[:lower:]')"
  id_like="$(sed -n 's/^ID_LIKE=//p' "$os_release" | head -1 | tr -d '"' | tr '[:upper:]' '[:lower:]')"
  case "$distro" in
    ubuntu|debian) ;;
    *) printf 'SolarLogger: unsupported distribution %s (%s). Only Ubuntu/Debian supported.\n' "$distro" "$id_like" >&2; return 22 ;;
  esac
  command -v apt-get >/dev/null 2>&1 || { printf 'SolarLogger: apt-get missing; no changes.\n' >&2; return 23; }
  printf 'SolarLogger: supported platform: %s Linux.\n' "$distro"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  solarlogger_platform_check
fi
