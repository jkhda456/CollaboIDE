# afm_bridge — collabo_ide 안의 복사본

원본은 별도 저장소(AFMBridge)의 Flutter 플러그인 `flutter/afm_bridge` 와 Swift 패키지이고, 여기 있는 것은
**collabo_ide 가 쓰는 파일만 추려 온 복사본**이다(`packages/collabo_core` 와 같은 방식).
**외부 저장소·환경변수 없이 이 폴더만으로 빌드된다**(2026-09-23 — Swift 소스까지 포함).

| 가져온 것 | 원본 위치 | 왜 |
|---|---|---|
| `lib/` | `flutter/afm_bridge/lib/` | Dart API(`AfmBridge`, `AfmStatus`, `AfmBridgeException`) — 앱이 직접 쓴다 |
| `darwin/afm_bridge/Sources/afm_bridge/` | `flutter/afm_bridge/darwin/…` | iOS/macOS 채널 플러그인(Swift) + `PrivacyInfo.xcprivacy` |
| `darwin/afm_bridge/Sources/AFMBridgeCore/` | `Sources/AFMBridgeCore/` | OpenAI 타입·JSON·스키마 변환 (FoundationModels 비의존) |
| `darwin/afm_bridge/Sources/AFMBridgeEngine/` | `Sources/AFMBridgeEngine/` | `AFMEngine` — OpenAI 요청 → Foundation Models |
| `darwin/afm_bridge/Sources/AFMBridgeServer/` | `Sources/AFMBridgeServer/` | `AFMServer` — 앱 내장 OpenAI 호환 로컬 서버 |
| `darwin/afm_bridge/Package.swift` | (collabo 전용으로 새로 씀) | 위 4개 타깃을 한 패키지로 묶는다 — 외부 의존성은 Flutter 가 만드는 `FlutterFramework` 뿐 |
| `pubspec.yaml`, `README.md`, `LICENSE`, `CHANGELOG.md` | 플러그인 루트 | 패키지로 성립하는 데 필요한 것 |

가져오지 않은 것: `example/`, `test/`, AFMBridge 의 CLI(`afm-bridge`)·C ABI(`AFMBridgeFFI`)·Python 예제.
앱 쪽 시험은 `collabo_ide/test/apple_foundation_client_test.dart` 에 있다(채널을 가짜로 끼운다).

## 갱신 방법

AFMBridge 저장소가 `<작업 폴더>/AFMBridge` 에 있을 때:

```sh
A=../AFMBridge   # collabo_ide 에서 본 경로
D=packages/afm_bridge/darwin/afm_bridge/Sources
for t in AFMBridgeCore AFMBridgeEngine AFMBridgeServer; do rsync -a --delete "$A/Sources/$t/" "$D/$t/"; done
cp "$A/flutter/afm_bridge/darwin/afm_bridge/Sources/afm_bridge/AfmBridgePlugin.swift" "$D/afm_bridge/"
rsync -a --delete "$A/flutter/afm_bridge/lib/" packages/afm_bridge/lib/
```

`Package.swift` 는 덮어쓰지 않는다(원본은 AFMBridge 를 경로 의존성으로 가리키는 모양이라 다르다).
원본에 타깃·파일이 새로 생기면 여기 `Package.swift` 에도 반영한다.

## 빌드 조건

- 최소 배포 타깃 **iOS 15 / macOS 12** (collabo_ide: iOS 15.0, macOS 12.0 — 그대로 맞는다).
- Swift 6.2 이상 툴체인(Xcode 26+). 엔진 타깃은 Swift 6 언어 모드, 플러그인 타깃만 Swift 5 모드.
- FoundationModels 는 **약한 링크**(`LC_LOAD_WEAK_DYLIB`) — 구형 OS 에서도 앱은 뜬다.

모델이 실제로 도는 조건은 iOS/macOS **26.4+**, Apple Intelligence 가 켜진 기기다. 그 아래에서는
연결 확인이 `unsupportedOS` 로 알려 준다 — 앱은 설정 → 모델에서 이 연결을 mac/iOS 에서만 보여 준다.
