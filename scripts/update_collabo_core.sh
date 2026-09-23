#!/bin/sh
# collaboCore(Dart 패키지·런타임)를 collabo_ide 로 들여온다 — update_collabo_core.py 를 부르는 얇은 껍데기.
# 인자는 그대로 넘긴다:
#   scripts/update_collabo_core.sh --check
#   scripts/update_collabo_core.sh --only runtime --platform darwin-arm64
# 설정: scripts/collabo_core_update.json (경로는 그 파일 기준 상대 경로)
set -e
here=$(cd "$(dirname "$0")" && pwd)

for py in python3 python; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null; then
    exec "$py" "$here/update_collabo_core.py" "$@"
  fi
done
echo "update_collabo_core.sh: Python 3.8 이상이 필요합니다 (python3 / python 을 찾지 못함)" >&2
exit 1
