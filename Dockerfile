# Dockerfile.android-preview
#
# Pre-baked Android emulator image with a fully-booted snapshot.
# Sandboxes resume from snapshot instead of cold-booting, cutting
# start time from 10+ minutes to ~60-90 seconds.
#
# Uses ubuntu:22.04 instead of cirruslabs/flutter:stable to save ~3GB.
# Flutter is installed from the official tarball (~1.5GB) rather than
# the bloated Cirrus Labs image (~4.9GB) which bundles Chrome, Gradle,
# extra build-tools, etc. that aren't needed for mobile preview.
#
# All paths match env.ts constants:
#   SDK at /opt/android-sdk-linux
#   AVDs at /opt/android-sdk-linux/avd

FROM ubuntu:22.04

ARG API_LEVEL=34
ARG SYSTEM_IMAGE="system-images;android-${API_LEVEL};default;x86_64"
ARG AVD_ID="mag_mobile_preview_api_${API_LEVEL}"
ARG DEVICE_PROFILE="pixel_6"
ARG SKIP_SNAPSHOT=false

ENV ANDROID_SDK_ROOT=/opt/android-sdk-linux \
    ANDROID_HOME=/opt/android-sdk-linux \
    ANDROID_AVD_HOME=/opt/android-sdk-linux/avd \
    FLUTTER_HOME=/opt/flutter \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    DEBIAN_FRONTEND=noninteractive

ENV PATH="${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---------- Install system prerequisites ----------
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      openjdk-17-jdk-headless \
      curl \
      unzip \
      git \
      procps \
      python3 \
      xz-utils \
      libglu1-mesa \
      libpulse0 \
      libasound2 \
      libx11-6 \
      libxcomposite1 \
      libxcursor1 \
      libxi6 \
      libxtst6 \
      libnss3 \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ---------- Install Flutter SDK ----------
# Shallow clone (~700MB) of the stable channel. Much smaller than the
# cirruslabs/flutter:stable image (~4.9GB) which bundles Chrome, Gradle, etc.
RUN git clone --depth 1 --branch stable https://github.com/flutter/flutter.git ${FLUTTER_HOME} && \
    flutter config --no-analytics && \
    dart --disable-analytics && \
    flutter --version

# ---------- Install Android SDK components ----------
RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" "${ANDROID_SDK_ROOT}/platform-tools" "${ANDROID_SDK_ROOT}/emulator" "${ANDROID_AVD_HOME}" && \
    curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" -o /tmp/cmdlinetools.zip && \
    unzip -q -o /tmp/cmdlinetools.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools/tmp" && \
    mv "${ANDROID_SDK_ROOT}/cmdline-tools/tmp/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest" && \
    rm -rf "${ANDROID_SDK_ROOT}/cmdline-tools/tmp" /tmp/cmdlinetools.zip

RUN yes | sdkmanager --licenses >/dev/null 2>&1 || true && \
    sdkmanager --install "platform-tools" "emulator" && \
    sdkmanager --install "${SYSTEM_IMAGE}"

# ---------- Create AVD ----------
RUN echo no | avdmanager create avd \
      --force \
      -n "${AVD_ID}" \
      -k "${SYSTEM_IMAGE}" \
      -d "${DEVICE_PROFILE}"

# ---------- Pre-create userdata-qemu.img ----------
RUN if [ "${SKIP_SNAPSHOT}" != "true" ]; then \
    AVD_DATA_DIR="${ANDROID_AVD_HOME}/${AVD_ID}.avd" && \
    rm -f "${AVD_DATA_DIR}/userdata-qemu.img" "${AVD_DATA_DIR}/userdata-qemu.img.qcow2" && \
    truncate -s 512M "${AVD_DATA_DIR}/userdata-qemu.img" && \
    mkfs.ext4 -q -F "${AVD_DATA_DIR}/userdata-qemu.img"; \
    else echo "SKIP_SNAPSHOT=true: skipping userdata creation (CI two-phase build)"; fi

# ---------- Configure AVD for snapshot support ----------
RUN AVD_CONFIG="${ANDROID_AVD_HOME}/${AVD_ID}.avd/config.ini" && \
    if [ -f "$AVD_CONFIG" ]; then \
      if grep -q "^disk.dataPartition.size=" "$AVD_CONFIG"; then \
        sed -i "s/^disk.dataPartition.size=.*/disk.dataPartition.size=512m/" "$AVD_CONFIG"; \
      else \
        echo "disk.dataPartition.size=512m" >> "$AVD_CONFIG"; \
      fi && \
      if grep -q "^fastboot.forceColdBoot=" "$AVD_CONFIG"; then \
        sed -i "s/^fastboot.forceColdBoot=.*/fastboot.forceColdBoot=no/" "$AVD_CONFIG"; \
      else \
        echo "fastboot.forceColdBoot=no" >> "$AVD_CONFIG"; \
      fi; \
    fi

# ---------- Boot emulator to create Quick Boot snapshot ----------
RUN if [ "${SKIP_SNAPSHOT}" != "true" ]; then \
    set -e && \
    nohup emulator -avd "${AVD_ID}" \
      -no-accel -no-window -no-audio -no-metrics \
      -gpu guest \
      -partition-size 512 -memory 1024 \
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

# ---------- Cleanup to minimize image size ----------
# Remove cmdline-tools (not needed at runtime — sentinel skips bootstrap),
# SDK caches, licenses, and temp files.
RUN rm -rf "${ANDROID_SDK_ROOT}/cmdline-tools" \
           "${ANDROID_SDK_ROOT}/.android/cache" \
           "${ANDROID_SDK_ROOT}/.android/analytics"* \
           "${ANDROID_SDK_ROOT}/build-tools" \
           "${ANDROID_SDK_ROOT}/licenses" \
           "${ANDROID_SDK_ROOT}/patcher" \
           "${FLUTTER_HOME}/.pub-cache" \
           "${FLUTTER_HOME}/bin/cache/artifacts/engine/linux-x64" \
           "${FLUTTER_HOME}/bin/cache/artifacts/engine/linux-x64-profile" \
           "${FLUTTER_HOME}/bin/cache/artifacts/engine/linux-x64-release" \
           /tmp/* /var/tmp/* /root/.cache \
           /var/lib/apt/lists/* 2>/dev/null || true && \
    echo "==> Disk usage after cleanup:" && \
    du -sh "${ANDROID_SDK_ROOT}" "${ANDROID_AVD_HOME}" "${FLUTTER_HOME}" 2>/dev/null || true
