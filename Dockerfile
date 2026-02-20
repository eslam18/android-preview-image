# Dockerfile.android-preview
#
# Pre-baked Android emulator image with a fully-booted snapshot.
# Sandbox starts resume from snapshot instead of cold-booting, cutting
# start time from 10+ minutes to ~60-90 seconds.
#
# Build:
#   docker build -f Dockerfile.android-preview \
#     --build-arg API_LEVEL=34 \
#     --build-arg SYSTEM_IMAGE=system-images;android-34;default;x86_64 \
#     --build-arg AVD_ID=mag_mobile_preview_api_34 \
#     --build-arg DEVICE_PROFILE=pixel_6 \
#     -t mag-android-preview:latest .
#
# All paths match env.ts constants:
#   SDK at /opt/android-sdk-linux
#   AVDs at /opt/android-sdk-linux/avd

FROM ghcr.io/cirruslabs/flutter:stable

ARG API_LEVEL=34
ARG SYSTEM_IMAGE="system-images;android-${API_LEVEL};default;x86_64"
ARG AVD_ID="mag_mobile_preview_api_${API_LEVEL}"
ARG DEVICE_PROFILE="pixel_6"
ARG SKIP_SNAPSHOT=false

ENV ANDROID_SDK_ROOT=/opt/android-sdk-linux \
    ANDROID_HOME=/opt/android-sdk-linux \
    ANDROID_AVD_HOME=/opt/android-sdk-linux/avd \
    DEBIAN_FRONTEND=noninteractive

ENV PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator:${PATH}"

# ---------- Install prerequisites ----------
USER root
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      openjdk-17-jre-headless \
      unzip \
      curl \
      e2fsprogs \
      procps && \
    rm -rf /var/lib/apt/lists/*

# ---------- Install Android SDK components ----------
RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" "${ANDROID_SDK_ROOT}/platform-tools" "${ANDROID_SDK_ROOT}/emulator" "${ANDROID_AVD_HOME}" && \
    if [ ! -x "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" ]; then \
      TMP_ZIP="/tmp/cmdlinetools.zip" && \
      curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" -o "$TMP_ZIP" && \
      unzip -q -o "$TMP_ZIP" -d "${ANDROID_SDK_ROOT}/cmdline-tools/tmp" && \
      mv "${ANDROID_SDK_ROOT}/cmdline-tools/tmp/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest" && \
      rm -rf "${ANDROID_SDK_ROOT}/cmdline-tools/tmp" "$TMP_ZIP"; \
    fi

RUN yes | sdkmanager --licenses >/dev/null 2>&1 || true && \
    sdkmanager --install "platform-tools" "emulator" && \
    sdkmanager --install "${SYSTEM_IMAGE}"

# ---------- Create AVD ----------
RUN echo no | avdmanager create avd \
      --force \
      -n "${AVD_ID}" \
      -k "${SYSTEM_IMAGE}" \
      -d "${DEVICE_PROFILE}"

# ---------- Pre-create userdata-qemu.img (mirrors bootstrap.ts logic) ----------
RUN AVD_DATA_DIR="${ANDROID_AVD_HOME}/${AVD_ID}.avd" && \
    rm -f "${AVD_DATA_DIR}/userdata-qemu.img" "${AVD_DATA_DIR}/userdata-qemu.img.qcow2" && \
    truncate -s 2048M "${AVD_DATA_DIR}/userdata-qemu.img" && \
    mkfs.ext4 -q -F "${AVD_DATA_DIR}/userdata-qemu.img"

# ---------- Configure AVD for snapshot support ----------
RUN AVD_CONFIG="${ANDROID_AVD_HOME}/${AVD_ID}.avd/config.ini" && \
    if [ -f "$AVD_CONFIG" ]; then \
      if grep -q "^disk.dataPartition.size=" "$AVD_CONFIG"; then \
        sed -i "s/^disk.dataPartition.size=.*/disk.dataPartition.size=2048m/" "$AVD_CONFIG"; \
      else \
        echo "disk.dataPartition.size=2048m" >> "$AVD_CONFIG"; \
      fi && \
      if grep -q "^fastboot.forceColdBoot=" "$AVD_CONFIG"; then \
        sed -i "s/^fastboot.forceColdBoot=.*/fastboot.forceColdBoot=no/" "$AVD_CONFIG"; \
      else \
        echo "fastboot.forceColdBoot=no" >> "$AVD_CONFIG"; \
      fi; \
    fi

# ---------- Boot emulator to create Quick Boot snapshot ----------
# This is a one-time CI cost (up to 15 minutes under software emulation).
# The emulator boots fully, then `adb emu kill` triggers a snapshot save.
# When SKIP_SNAPSHOT=true (CI two-phase build), this step is skipped;
# the CI workflow boots with KVM and commits the snapshot separately.
RUN if [ "${SKIP_SNAPSHOT}" != "true" ]; then \
    set -e && \
    nohup emulator -avd "${AVD_ID}" \
      -no-accel -no-window -no-audio -no-metrics \
      -gpu guest \
      -partition-size 2048 -memory 1024 \
      > /tmp/emulator-boot.log 2>&1 & \
    EMU_PID=$! && \
    echo "Waiting for emulator boot (PID=${EMU_PID})..." && \
    BOOT_DEADLINE=$(($(date +%s) + 900)) && \
    while true; do \
      if [ "$(date +%s)" -ge "$BOOT_DEADLINE" ]; then \
        echo "ERROR: Emulator boot timed out after 15 minutes" && \
        kill "$EMU_PID" 2>/dev/null || true && \
        tail -n 100 /tmp/emulator-boot.log && \
        exit 1; \
      fi && \
      BOOT_DONE="$(adb shell getprop sys.boot_completed 2>/dev/null || true)" && \
      if [ "$BOOT_DONE" = "1" ]; then \
        echo "Emulator booted successfully" && \
        break; \
      fi && \
      sleep 5; \
    done && \
    echo "Stopping emulator to save Quick Boot snapshot..." && \
    adb emu kill && \
    sleep 5 && \
    wait "$EMU_PID" 2>/dev/null || true && \
    echo "Emulator stopped, snapshot saved"; \
    else echo "SKIP_SNAPSHOT=true: skipping emulator boot (CI two-phase build)"; fi

# ---------- Verify snapshot and write sentinel ----------
RUN if [ "${SKIP_SNAPSHOT}" != "true" ]; then \
    AVD_DATA_DIR="${ANDROID_AVD_HOME}/${AVD_ID}.avd" && \
    test -d "${AVD_DATA_DIR}/snapshots/default_boot" && \
    echo "Snapshot directory verified: ${AVD_DATA_DIR}/snapshots/default_boot" && \
    printf '{"avdId":"%s","apiLevel":%s,"arch":"x86_64","systemImage":"%s"}\n' \
      "${AVD_ID}" "${API_LEVEL}" "${SYSTEM_IMAGE}" \
      > "${ANDROID_SDK_ROOT}/.mag-prebaked" && \
    echo "Sentinel written to ${ANDROID_SDK_ROOT}/.mag-prebaked" && \
    cat "${ANDROID_SDK_ROOT}/.mag-prebaked"; \
    else echo "SKIP_SNAPSHOT=true: skipping sentinel write (CI two-phase build)"; fi

# Clean up build artifacts
RUN if [ "${SKIP_SNAPSHOT}" != "true" ]; then \
    rm -f /tmp/emulator-boot.log; \
    fi
