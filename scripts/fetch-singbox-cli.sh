#!/usr/bin/env bash
#
# Download sing-box CLI binaries for desktop packaging.
# Usage:
#   ./scripts/fetch-singbox-cli.sh           # current host arch
#   ./scripts/fetch-singbox-cli.sh all       # macOS arm64+amd64, linux, windows
#   ./scripts/fetch-singbox-cli.sh macos
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=libbox-common.sh
source "${SCRIPT_DIR}/libbox-common.sh"

CMAKE="${CMAKE:-cmake}"
command -v "${CMAKE}" >/dev/null 2>&1 || {
  echo "CMake is required to fetch and verify sing-box; install CMake or set CMAKE to its executable." >&2
  exit 1
}

fetch_one() {
  "${CMAKE}" "-DSINGBOX_PLATFORM=$1-$2" -P "${SCRIPT_DIR}/singbox-runtime.cmake"
}

host_arch() {
  case "$(uname -m)" in
    x86_64|amd64|AMD64) echo amd64 ;;
    arm64|aarch64) echo arm64 ;;
    *) echo "unsupported host architecture: $(uname -m)" >&2; return 1 ;;
  esac
}

case "${1:-host}" in
  all)
    fetch_one darwin arm64
    fetch_one darwin amd64
    fetch_one linux amd64
    fetch_one windows amd64
    ;;
  macos|darwin)
    fetch_one darwin "$(host_arch)"
    ;;
  linux)
    fetch_one linux amd64
    ;;
  windows)
    fetch_one windows amd64
    ;;
  host)
    arch="$(host_arch)"
    case "$(uname -s)" in
      Darwin) fetch_one darwin "${arch}" ;;
      Linux) fetch_one linux "${arch}" ;;
      MINGW*|MSYS*|CYGWIN*) fetch_one windows "${arch}" ;;
      *) echo "unsupported host OS" >&2; exit 1 ;;
    esac
    ;;
  *) echo "usage: $0 [host|all|macos|linux|windows]" >&2; exit 1 ;;
esac