#!/usr/bin/env bash
# Collabo IDE — macOS 배포 패키징 (release 빌드 → dmg)
#
# 사용법:  scripts/package_macos.sh
# 결과:    dist/CollaboIDE-<버전>-macos.dmg
#
# dmg 안에는 앱과 /Applications 심링크가 들어가 드래그 설치 형태가 된다.
# 서명/공증(codesign/notarytool)은 하지 않는다 — 필요 시 별도 단계로 추가.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Collabo IDE"
# pubspec.yaml 의 version(+빌드번호 제외)을 파일명에 쓴다.
VERSION=$(sed -n 's/^version: *//p' pubspec.yaml | sed 's/+.*//' | tr -d '[:space:]')
[ -n "$VERSION" ] || { echo "error: version not found in pubspec.yaml" >&2; exit 1; }

flutter pub get
flutter build macos --release

APP="build/macos/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: app not found: $APP" >&2; exit 1; }

DIST="dist"
DMG="$DIST/CollaboIDE-$VERSION-macos.dmg"
mkdir -p "$DIST"
rm -f "$DMG"

# 스테이징 폴더: 앱 + /Applications 심링크(드래그 설치용).
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "Created: $DMG"
