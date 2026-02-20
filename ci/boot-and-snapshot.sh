#!/usr/bin/env bash
# ci/boot-and-snapshot.sh
#
# Phase 2 of the CI two-phase Android emulator build.
# Runs INSIDE the base container (started with --device /dev/kvm by the
# GitHub Actions workflow).  Boots the emulator, waits for sys.boot_completed,
# triggers a Quick Boot snapshot save via `adb emu kill`, then writes the
# .mag-prebaked sentinel so the server bootstrap can skip SDK setup.
#
# Expects the following environment variables (set in the Dockerfile / workflow):
#   ANDROID_SDK_ROOT   – e.g. /opt/android-sdk-linux
#   ANDROID_AVD_HOME   – e.g. /opt/android-sdk-linux/avd
#   AVD_ID             – e.g. mag_mobile_preview_api_34
#   API_LEVEL          – e.g. 34
#   SYSTEM_IMAGE       – e.g. system-images;android-34;default;x86_64

set -euo pipefail

BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"  # 5 minutes default (KVM is fast)
POLL_INTERVAL=3

# ---------- Resolve variables ----------
AVD_HOME="${ANDROID_AVD_HOME:-${ANDROID_SDK_ROOT}/avd}"
AVD_DATA_DIR="${AVD_HOME}/${AVD_ID}.avd"
SENTINEL_PATH="${ANDROID_SDK_ROOT}/.mag-prebaked"
SNAPSHOT_DIR="${AVD_DATA_DIR}/snapshots/default_boot"

echo "==> boot-and-snapshot.sh"
echo "    AVD_ID=${AVD_ID}"
echo "    API_LEVEL=${API_LEVEL}"
echo "    AVD_DATA_DIR=${AVD_DATA_DIR}"

# ---------- Detect KVM ----------
ACCEL_FLAG="-no-accel"
if [ -w /dev/kvm ]; then
  echo "==> KVM detected and writable — using hardware acceleration"
  ACCEL_FLAG="-accel on"
else
  echo "==> KVM not available — falling back to software emulation (slow)"
fi

# ---------- Start emulator ----------
echo "==> Starting emulator..."
nohup emulator -avd "${AVD_ID}" \
  ${ACCEL_FLAG} -no-window -no-audio -no-metrics \
  -gpu guest \
  -partition-size 2048 -memory 1024 \
  > /tmp/emulator-boot.log 2>&1 &
EMU_PID=$!
echo "    Emulator PID=${EMU_PID}"

# ---------- Poll for boot completion ----------
echo "==> Waiting for sys.boot_completed (timeout=${BOOT_TIMEOUT}s)..."
DEADLINE=$(($(date +%s) + BOOT_TIMEOUT))

while true; do
  # Fast-fail if emulator process died
  if ! kill -0 "$EMU_PID" 2>/dev/null; then
    echo "ERROR: Emulator process (PID=${EMU_PID}) is no longer running"
    echo "--- Last 80 lines of emulator log ---"
    tail -n 80 /tmp/emulator-boot.log || true
    exit 1
  fi

  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "ERROR: Emulator boot timed out after ${BOOT_TIMEOUT} seconds"
    kill "$EMU_PID" 2>/dev/null || true
    echo "--- Last 80 lines of emulator log ---"
    tail -n 80 /tmp/emulator-boot.log || true
    exit 1
  fi

  BOOT_DONE="$(adb shell getprop sys.boot_completed 2>/dev/null || true)"
  if [ "$BOOT_DONE" = "1" ]; then
    echo "==> Emulator booted successfully"
    break
  fi

  sleep "$POLL_INTERVAL"
done

# ---------- Save Quick Boot snapshot ----------
echo "==> Stopping emulator to save Quick Boot snapshot..."
adb emu kill
sleep 5
wait "$EMU_PID" 2>/dev/null || true
echo "==> Emulator stopped"

# ---------- Verify snapshot ----------
if [ ! -d "$SNAPSHOT_DIR" ]; then
  echo "ERROR: Snapshot directory not found at ${SNAPSHOT_DIR}"
  ls -la "${AVD_DATA_DIR}/snapshots/" 2>/dev/null || echo "(no snapshots directory)"
  exit 1
fi
echo "==> Snapshot verified: ${SNAPSHOT_DIR}"

# ---------- Write sentinel ----------
printf '{"avdId":"%s","apiLevel":%s,"arch":"x86_64","systemImage":"%s"}\n' \
  "${AVD_ID}" "${API_LEVEL}" "${SYSTEM_IMAGE}" \
  > "${SENTINEL_PATH}"
echo "==> Sentinel written to ${SENTINEL_PATH}"
cat "${SENTINEL_PATH}"

# ---------- Clean up ----------
rm -f /tmp/emulator-boot.log
echo "==> Done — container is ready for docker commit"
