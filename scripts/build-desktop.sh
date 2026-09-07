#!/usr/bin/env bash
#
# Build desktop release bundles. macOS uses its Network Extension; Windows and
# Linux embed the sing-box CLI.
# Usage: ./scripts/build-desktop.sh [macos|windows|linux|all]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

PLATFORM="${1:-macos}"

package_macos() {
  local app
  app="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
  if [[ -z "${app}" ]]; then
    echo "✗ macOS .app not found — run flutter build macos first"
    exit 1
  fi
  local tag="${1:-local}"
  mkdir -p dist
  local out="dist/erebrus-vpn-macos-${tag}.zip"
  ditto -c -k --keepParent "${app}" "${out}"
  echo "✓ packaged → ${out}"
}

package_linux() {
  local bundle="${ROOT_DIR}/build/linux/x64/release/bundle"
  if [[ ! -d "${bundle}" ]]; then
    echo "✗ linux bundle not found"
    exit 1
  fi
  local tag="${1:-local}"
  mkdir -p dist
  local out="dist/erebrus-vpn-linux-${tag}.tar.gz"
  [[ -x "${bundle}/sing-box" ]] || {
    echo "CMake did not package sing-box in ${bundle}; rebuild the Linux x64 release." >&2
    exit 1
  }
  tar -czf "${out}" -C "$(dirname "${bundle}")" "$(basename "${bundle}")"
  echo "✓ packaged → ${out}"
}

package_windows() {
  local runner_dir="${ROOT_DIR}/build/windows/x64/runner/Release"
  if [[ ! -d "${runner_dir}" ]]; then
    echo "✗ windows Release folder not found"
    exit 1
  fi
  local tag="${1:-local}"
  mkdir -p dist
  # Absolute path — zip resolves relative paths against the cd'd runner dir.
  local out="${ROOT_DIR}/dist/erebrus-vpn-windows-${tag}.zip"
  [[ -f "${runner_dir}/sing-box.exe" ]] || {
    echo "CMake did not package sing-box.exe in ${runner_dir}; rebuild the Windows x64 release." >&2
    exit 1
  }
  (cd "${runner_dir}" && zip -qr "${out}" .)
  echo "✓ packaged → dist/erebrus-vpn-windows-${tag}.zip"
}

read_version_tag() {
  local version_line
  version_line="$(grep '^version:' pubspec.yaml | awk '{print $2}')"
  local version_name="${version_line%%+*}"
  echo "v${version_name}"
}

dart_define_args() {
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    echo "--dart-define-from-file=${ROOT_DIR}/.env"
  else
    echo "⚠ .env missing — cp .env.example .env and set REOWN_PROJECT_ID" >&2
  fi
}

build_one() {
  local p="$1"
  local tag
  tag="$(read_version_tag)"
  local define_args
  define_args="$(dart_define_args)"
  if [[ "${p}" == "macos" ]]; then
    echo "▸ build macOS libbox + configure Network Extension"
    "${SCRIPT_DIR}/build-libbox-macos.sh"
    ruby "${SCRIPT_DIR}/setup-macos-tunnel.rb"
  fi
  case "${p}" in
    linux|windows) "${SCRIPT_DIR}/fetch-singbox-cli.sh" "${p}" ;;
  esac
  echo "▸ flutter pub get"
  flutter pub get
  echo "▸ generate desktop brand assets"
  python3 scripts/generate-desktop-assets.py
  echo "▸ flutter build ${p} --release ${define_args}"
  # shellcheck disable=SC2086
  flutter build "${p}" --release ${define_args}
  case "${p}" in
    macos) package_macos "${tag}" ;;
    linux) package_linux "${tag}" ;;
    windows) package_windows "${tag}" ;;
  esac
}

case "${PLATFORM}" in
  macos) build_one macos ;;
  linux) build_one linux ;;
  windows) build_one windows ;;
  all)
    build_one macos
    build_one linux || echo "⚠ linux build skipped (needs Linux host)"
    build_one windows || echo "⚠ windows build skipped (needs Windows host)"
    ;;
  *) echo "usage: $0 [macos|windows|linux|all]"; exit 1 ;;
esac
