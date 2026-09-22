#!/bin/sh
# Xcode 빌드 단계(Runner, "Bundle Framework" 뒤): collaboCore 런타임을
# <App>.app/Contents/Resources/collabo_core_runtime/ 로 복사한다 — CollaboRuntime.locate() 가 찾는 자리.
# CollaboCore/flutter/collabo_core_demo/macos/collabo_core_embed.sh 에서 가져왔고, 원본만 다르다
# (이 앱은 런타임을 리포 안 collabo_core_runtime/ 에 복사해 둔다).
set -e
src="${COLLABO_CORE_RUNTIME_DIR:-$SRCROOT/../collabo_core_runtime}"
dest="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/collabo_core_runtime"
mkdir -p "$dest"
found=0
for a in darwin-arm64 darwin-x64; do
  if [ -f "$src/collabo-core-$a/manifest.json" ]; then
    rsync -a --delete "$src/collabo-core-$a" "$dest/"
    # 공유 폴더를 거쳐 오면 실행 비트가 빠질 수 있다(Z:\ 경유 복사).
    chmod +x "$dest/collabo-core-$a/bin/collabo-core-engine"
    # 엔진은 실행 중에 wasm 을 컴파일한다(JIT). 복사본의 격리 표시는 여기서 지운다.
    xattr -dr com.apple.quarantine "$dest/collabo-core-$a" 2>/dev/null || true
    found=1
  fi
done
if [ "$found" != 1 ]; then
  echo "error: collaboCore runtime not found in $src (CollaboCore/dist/runtime 에서 복사할 것)"
  exit 1
fi
