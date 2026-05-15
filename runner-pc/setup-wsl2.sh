#!/usr/bin/env bash
# Run this inside WSL2 Ubuntu on the Windows PC.
# Installs GitLab Runner + Flutter SDK + Android SDK + Java 17.
set -euo pipefail

FLUTTER_VERSION="${FLUTTER_VERSION:-3.19.6}"
FLUTTER_HOME="/opt/flutter"
ANDROID_HOME="/opt/android-sdk"
JAVA_VERSION="17"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup]${NC} $*"; }
error() { echo -e "${RED}[setup]${NC} $*" >&2; exit 1; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
info "Updating apt packages..."
sudo apt-get update -q

info "Installing base dependencies..."
sudo apt-get install -y -q \
  curl \
  wget \
  unzip \
  xz-utils \
  git \
  bc \
  gettext-base \
  openjdk-${JAVA_VERSION}-jdk \
  lib32z1 \
  libstdc++6 \
  libgcc-s1

# ── GitLab Runner ─────────────────────────────────────────────────────────────
if command -v gitlab-runner >/dev/null 2>&1; then
  info "GitLab Runner already installed: $(gitlab-runner --version | head -1)"
else
  info "Installing GitLab Runner..."
  curl -fsSL https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh \
    | sudo bash
  sudo apt-get install -y gitlab-runner
  info "GitLab Runner installed: $(gitlab-runner --version | head -1)"
fi

# ── Flutter SDK ───────────────────────────────────────────────────────────────
if [ -d "${FLUTTER_HOME}/bin" ]; then
  INSTALLED_VERSION=$("${FLUTTER_HOME}/bin/flutter" --version 2>/dev/null | grep -oP 'Flutter \K[\d.]+' || echo "unknown")
  info "Flutter already installed at ${FLUTTER_HOME} (version ${INSTALLED_VERSION})"
else
  info "Downloading Flutter SDK ${FLUTTER_VERSION}..."
  sudo mkdir -p /opt
  FLUTTER_ARCHIVE="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${FLUTTER_ARCHIVE}"

  wget -q --show-progress -O "/tmp/${FLUTTER_ARCHIVE}" "${FLUTTER_URL}"
  sudo tar -xf "/tmp/${FLUTTER_ARCHIVE}" -C /opt
  rm "/tmp/${FLUTTER_ARCHIVE}"
  sudo chown -R "${USER}:${USER}" "${FLUTTER_HOME}"
  info "Flutter SDK installed at ${FLUTTER_HOME}"
fi

# Add Flutter to PATH for current session and future logins
if ! grep -q "flutter/bin" ~/.bashrc 2>/dev/null; then
  echo "export PATH=\"${FLUTTER_HOME}/bin:\$PATH\"" >> ~/.bashrc
fi
export PATH="${FLUTTER_HOME}/bin:${PATH}"

# ── Android SDK ───────────────────────────────────────────────────────────────
if [ -d "${ANDROID_HOME}/cmdline-tools" ]; then
  info "Android SDK already installed at ${ANDROID_HOME}"
else
  info "Downloading Android command-line tools..."
  CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  sudo mkdir -p "${ANDROID_HOME}/cmdline-tools"
  wget -q --show-progress -O /tmp/cmdline-tools.zip "${CMDLINE_TOOLS_URL}"
  sudo unzip -q /tmp/cmdline-tools.zip -d /tmp/android-cmdline
  sudo mv /tmp/android-cmdline/cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest"
  rm /tmp/cmdline-tools.zip
  sudo chown -R "${USER}:${USER}" "${ANDROID_HOME}"
fi

export ANDROID_HOME="${ANDROID_HOME}"
export PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

if ! grep -q "android-sdk" ~/.bashrc 2>/dev/null; then
  cat >> ~/.bashrc <<EOF

export ANDROID_HOME="${ANDROID_HOME}"
export PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:\$PATH"
EOF
fi

info "Accepting Android SDK licenses..."
yes | sdkmanager --licenses >/dev/null 2>&1 || true

info "Installing Android SDK platforms and build tools..."
sdkmanager \
  "platform-tools" \
  "platforms;android-34" \
  "build-tools;34.0.0" \
  >/dev/null 2>&1

# ── Flutter precache + doctor ─────────────────────────────────────────────────
info "Running flutter precache (downloads Dart SDK and tools)..."
flutter precache --no-web --no-macos --no-windows --no-linux --no-fuchsia 2>/dev/null || true

info "Running flutter doctor..."
flutter doctor --android-licenses 2>/dev/null || true
flutter doctor -v || true

# ── Summary ───────────────────────────────────────────────────────────────────
info ""
info "========================================"
info "  Setup complete!"
info "========================================"
info "  Flutter: $(flutter --version 2>/dev/null | grep -oP 'Flutter \K[\d.]+' || echo 'check PATH')"
info "  Java:    $(java -version 2>&1 | head -1)"
info "  Runner:  $(gitlab-runner --version | head -1)"
info ""
info "Next step: run bash runner-pc/register.sh"
info "========================================"
