#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'ID=ubuntu\n' > "$tmp/ubuntu"
printf 'ID=debian\n' > "$tmp/debian"
printf 'ID=fedora\nID_LIKE="rhel fedora"\n' > "$tmp/fedora"
check() {
  local expected="$1"; shift
  local result=0
  env "$@" bash "$root/platform-check.sh" > "$tmp/log" 2>&1 || result=$?
  if [[ "$result" != "$expected" ]]; then
    printf 'FAIL expected=%s got=%s: %s\n' "$expected" "$result" "$(cat "$tmp/log")"
    exit 1
  fi
}
check 0 SOLARLOGGER_TEST_UNAME=Linux SOLARLOGGER_TEST_WSL=0 SOLARLOGGER_TEST_OS_RELEASE="$tmp/ubuntu"
check 0 SOLARLOGGER_TEST_UNAME=Linux SOLARLOGGER_TEST_WSL=0 SOLARLOGGER_TEST_OS_RELEASE="$tmp/debian"
check 20 SOLARLOGGER_TEST_UNAME=MINGW64_NT-10.0 SOLARLOGGER_TEST_OS_RELEASE="$tmp/ubuntu"
check 20 SOLARLOGGER_TEST_UNAME=MSYS_NT-10.0 SOLARLOGGER_TEST_OS_RELEASE="$tmp/ubuntu"
check 20 SOLARLOGGER_TEST_UNAME=CYGWIN_NT-10.0 SOLARLOGGER_TEST_OS_RELEASE="$tmp/ubuntu"
check 20 SOLARLOGGER_TEST_UNAME=Darwin SOLARLOGGER_TEST_OS_RELEASE="$tmp/ubuntu"
check 21 SOLARLOGGER_TEST_UNAME=Linux SOLARLOGGER_TEST_WSL=1 SOLARLOGGER_TEST_OS_RELEASE="$tmp/ubuntu"
check 22 SOLARLOGGER_TEST_UNAME=Linux SOLARLOGGER_TEST_WSL=0 SOLARLOGGER_TEST_OS_RELEASE="$tmp/fedora"
check 22 SOLARLOGGER_TEST_UNAME=Linux SOLARLOGGER_TEST_WSL=0 SOLARLOGGER_TEST_OS_RELEASE="$tmp/missing"
python3 - "$root/install.sh" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
guard=s.index('solarlogger_platform_check')
for pattern in ['EUID == 0', 'apt-get update', 'command -v apt-get']:
    assert guard < s.index(pattern), f'platform check too late: {pattern}'
assert 'source "$SCRIPT_DIR/platform-check.sh"' in s
print('PASS installer platform preflight executes before privileged operations')
PY
printf 'PASS 9 OS/platform scenarios\n'
