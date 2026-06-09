#!/bin/bash
# Build the Commander executable with SwiftPM and assemble it into a Commander.app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"          # release | debug
APP_NAME="XFinder"

cd "$ROOT"

echo "==> Building (${CONFIG})..."
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

APP_DIR="${ROOT}/build/${APP_NAME}.app"
echo "==> Assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "$BIN_PATH" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${ROOT}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# App icon, if present (Resources/AppIcon.icns)
if [[ -f "${ROOT}/Resources/AppIcon.icns" ]]; then
    cp "${ROOT}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${APP_DIR}/Contents/Info.plist" 2>/dev/null || true
fi

# 자체 서명 인증서가 있으면 그것으로 서명(서명 정체성이 빌드마다 동일 → TCC/전체 디스크 접근 권한 유지).
# 없으면 ad-hoc로 폴백. 인증서는 Scripts/make_codesign_cert.sh 로 한 번 생성한다.
SIGN_ID="XFinder Self Signed"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    echo "==> Signing with '$SIGN_ID'"
    codesign --force --deep --sign "$SIGN_ID" "$APP_DIR" || echo "   (codesign failed)"
else
    echo "==> '$SIGN_ID' 없음 — ad-hoc 서명으로 폴백 (Scripts/make_codesign_cert.sh 실행 권장)"
    codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "   (codesign skipped)"
fi

# Refresh Launch Services registration.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DIR" >/dev/null 2>&1 || true

echo "==> Done: ${APP_DIR}"
echo "    Run with:  open \"${APP_DIR}\""
