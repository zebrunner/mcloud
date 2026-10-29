#!/bin/bash
# tests/e2e/emulator.sh: the farm end to end with the emulator of the e2e job of CI (android-emulator-runner): its adb
# of the loopback of the runner is relayed to E2E_RELAY_PORT of every address, the containers reach it there.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERIAL="emulator-${EMULATOR_PORT:-5554}"
RELAY_PORT="${E2E_RELAY_PORT:-15555}"
LOGS="${E2E_LOGS:?the directory of the logs}"
mkdir -p "$LOGS"

adb -s "$SERIAL" wait-for-device
boot=""
for _ in $(seq 1 60); do
  boot="$(adb -s "$SERIAL" shell getprop sys.boot_completed 2> /dev/null | tr -d '\r\n')"
  [[ "$boot" == 1 ]] && break
  sleep 5
done
echo "[e2e] ${SERIAL} sys.boot_completed=${boot}"
adb -s "$SERIAL" shell input keyevent 82
adb -s "$SERIAL" shell wm dismiss-keyguard

socat "TCP-LISTEN:${RELAY_PORT},bind=0.0.0.0,reuseaddr,fork" "TCP:127.0.0.1:$((${EMULATOR_PORT:-5554} + 1))" \
  > "${LOGS}/adb-relay.log" 2>&1 &
relay=$!

host_ip="${E2E_HOST_IP:-$(hostname -I | awk '{print $1}')}"
E2E_ADB_ADDRESS="${host_ip}:${RELAY_PORT}" bash "${REPO}/tests/e2e/farm_test.sh"
status=$?

adb -s "$SERIAL" logcat -d -v time > "${LOGS}/logcat.txt" 2>&1
kill "$relay" 2> /dev/null
exit "$status"
