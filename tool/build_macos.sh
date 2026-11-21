#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/build_common.sh"

FORMAT="all"
ABI="$(uname -m)"

print_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --format <zip|dmg|all>  Only build the given package format (default: all)
  --abi <abi>             Target architecture: arm64 (aarch64), x86_64, universal (default: host)
  --dev                   Allow a dirty worktree and append git metadata to the package version
  --skip-clean-check
                          Skip the clean-worktree check
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      FORMAT="${2:?--format requires a value}"
      shift 2
      ;;
    --format=*)
      FORMAT="${1#*=}"
      shift
      ;;
    --abi)
      ABI="${2:?--abi requires a value}"
      shift 2
      ;;
    --abi=*)
      ABI="${1#*=}"
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      parse_common_args "$1"
      shift
      ;;
  esac
done

case "${FORMAT}" in
  zip|dmg|all) ;;
  *)
    log_error "Unknown format: ${FORMAT} (expected zip, dmg or all)"
    exit 1
    ;;
esac

case "${ABI}" in
  aarch64) ABI="arm64" ;;
  arm64|x86_64|universal) ;;
  *)
    log_error "Unknown ABI: ${ABI} (expected arm64, x86_64 or universal)"
    exit 1
    ;;
esac

if [[ "$(host_os)" != "macos" ]]; then
  log_error "macOS packages can only be built on macOS"
  exit 1
fi

init_build
log_info "Building macOS release packages for version ${VERSION} (format=${FORMAT}, abi=${ABI})"

require_flutter
if [[ "${FORMAT}" != "dmg" ]]; then
  require_command zip
fi
if [[ "${FORMAT}" == "dmg" ]]; then
  require_command hdiutil
fi
ensure_release_dir

MACOS_APP_NAME="OronBox"

if [[ "${ABI}" == "universal" ]]; then
  TARGET_ARCHS=(arm64 x86_64)
else
  TARGET_ARCHS=("${ABI}")
fi

DART_DEFINES=()
while IFS= read -r define; do
  DART_DEFINES+=("${define}")
done < <(flutter_release_defines)

FLUTTER_MACOS_ARM64_ONLY=false FLUTTER_XCODE_ARCHS="${TARGET_ARCHS[*]}" run_cmd flutter build macos \
  --release \
  --obfuscate \
  --split-debug-info="symbols/macos/${ABI}" \
  "${DART_DEFINES[@]}"

APP_BUNDLE="${PROJECT_ROOT}/build/macos/Build/Products/Release/${MACOS_APP_NAME}.app"
if [[ ! -d "${APP_BUNDLE}" ]]; then
  log_error "macOS app bundle not found: ${APP_BUNDLE}"
  exit 1
fi

SHERPA_LIBRARY="${APP_BUNDLE}/Contents/Frameworks/libsherpa-onnx-c-api.dylib"
if [[ "${ABI}" != "universal" && -f "${SHERPA_LIBRARY}" ]]; then
  SHERPA_ARCHS="$(lipo -archs "${SHERPA_LIBRARY}")"
  if [[ "${SHERPA_ARCHS}" != "${ABI}" ]]; then
    run_cmd lipo "${SHERPA_LIBRARY}" -thin "${ABI}" -output "${SHERPA_LIBRARY}"
  fi
fi

if [[ "${FORMAT}" != "dmg" ]]; then
  archive_zip "${APP_BUNDLE}" "${RELEASE_DIR}/${APP_NAME}-${VERSION}-macos-${ABI}.zip"
fi
archive_symbols_if_present \
  "${PROJECT_ROOT}/symbols/macos/${ABI}" \
  "${RELEASE_DIR}/${APP_NAME}-${VERSION}-macos-${ABI}.symbols.tar.gz"

if [[ "${FORMAT}" != "zip" ]] && command -v hdiutil >/dev/null 2>&1; then
  DMG_DST="${RELEASE_DIR}/${APP_NAME}-${VERSION}-macos-${ABI}.dmg"
  DMG_WORK_DIR="$(mktemp -d "${PROJECT_ROOT}/build/macos/dmg.XXXXXX")"
  DMG_STAGE="${DMG_WORK_DIR}/stage"
  DMG_BUILD="${DMG_WORK_DIR}/$(basename "${DMG_DST}")"
  close_dmg_finder_windows() {
    command -v osascript >/dev/null 2>&1 || return 0
    osascript >/dev/null 2>&1 <<'APPLESCRIPT' || true
tell application "Finder"
  repeat with finderWindow in every Finder window
    try
      set targetName to name of (target of finderWindow)
      if targetName starts with "dmg." then close finderWindow
    end try
  end repeat
end tell
APPLESCRIPT
  }
  cleanup_dmg() {
    close_dmg_finder_windows
    rm -rf "${DMG_WORK_DIR}"
  }
  trap cleanup_dmg EXIT
  mkdir -p "${DMG_STAGE}"
  ditto "${APP_BUNDLE}" "${DMG_STAGE}/${MACOS_APP_NAME}.app"
  rm -f "${DMG_DST}"

  if command -v create-dmg >/dev/null 2>&1; then
    # Do not set a background picture or color. Finder then uses its native
    # appearance-aware background while retaining the native app/folder icons.
    # Keep both icons on the same horizontal row with a smaller top margin.
    DMG_ICON_Y=160
    run_cmd create-dmg \
      --volname "OronBox" \
      --volicon "${APP_BUNDLE}/Contents/Resources/AppIcon.icns" \
      --window-pos 180 100 \
      --window-size 720 400 \
      --icon-size 128 \
      --icon "${MACOS_APP_NAME}.app" 160 "${DMG_ICON_Y}" \
      --hide-extension "${MACOS_APP_NAME}.app" \
      --app-drop-link 560 "${DMG_ICON_Y}" \
      --text-size 14 \
      --no-internet-enable \
      "${DMG_BUILD}" \
      "${DMG_STAGE}"
  else
    log_warn "create-dmg not found; using the basic DMG layout"
    ln -s /Applications "${DMG_STAGE}/Applications"
    run_cmd hdiutil create \
      -volname "OronBox" \
      -srcfolder "${DMG_STAGE}" \
      -ov \
      -format UDZO \
      "${DMG_BUILD}"
  fi

  mv -f "${DMG_BUILD}" "${DMG_DST}"
  cleanup_dmg
  trap - EXIT
  log_info "Produced ${DMG_DST}"
elif [[ "${FORMAT}" != "zip" ]]; then
  log_warn "hdiutil not found; skipped DMG package"
fi

log_info "macOS build complete"
