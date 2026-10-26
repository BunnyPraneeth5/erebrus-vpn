#!/usr/bin/env bash
# Shared sing-box / libbox build settings for all Erebrus platforms.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pin sing-box SOURCE by commit (reproducible input).
export SING_BOX_VERSION="${SING_BOX_VERSION:-v1.11.15}"
export SING_BOX_COMMIT="${SING_BOX_COMMIT:-bc35aca01704497c179da1a03e45ad8e32f1a51b}"

# Pin gomobile toolchain (avoid @latest drift between machines).
export GOMOBILE_VERSION="${GOMOBILE_VERSION:-v0.0.0-20260611195102-4dd8f1dbf5d2}"

# REALITY + QUIC (Hysteria2) + uTLS + gvisor tun + wireguard endpoint.
export LIBBOX_TAGS="${LIBBOX_TAGS:-with_gvisor,with_quic,with_utls,with_wireguard,with_clash_api}"

ensure_gomobile() {
  command -v gomobile >/dev/null 2>&1 || {
    echo "installing gomobile ${GOMOBILE_VERSION}…"
    go install "golang.org/x/mobile/cmd/gomobile@${GOMOBILE_VERSION}"
    go install "golang.org/x/mobile/cmd/gobind@${GOMOBILE_VERSION}"
  }
  export PATH="${PATH}:$(go env GOPATH)/bin"
}

prepare_singbox_source() {
  local work="$1"
  git clone https://github.com/SagerNet/sing-box "${work}/sing-box"
  cd "${work}/sing-box"
  git checkout --quiet "${SING_BOX_COMMIT}"
  local actual
  actual="$(git rev-parse HEAD)"
  if [[ "${actual}" != "${SING_BOX_COMMIT}" ]]; then
    echo "✗ sing-box commit mismatch: expected ${SING_BOX_COMMIT} got ${actual}"
    exit 1
  fi
  go get "golang.org/x/mobile/cmd/gomobile@${GOMOBILE_VERSION}" \
         "golang.org/x/mobile/cmd/gobind@${GOMOBILE_VERSION}"
  # No `gomobile init`: it only builds OpenAL (unused here) and runs
  # `go install gobind@latest`, which replaces the pinned gobind above.
}