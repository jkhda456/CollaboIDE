# afm_bridge (Flutter)

Apple Foundation Models(온디바이스 LLM)를 **OpenAI Chat Completions 형식**으로 쓰는 Flutter 플러그인. **iOS / macOS** 공용.

- 네이티브: 저장소 루트의 AFMBridge Swift 패키지 (`AFMEngine`, `AFMServer`) 를 SwiftPM 으로 링크
- 통신: MethodChannel `afm_bridge` + EventChannel `afm_bridge/stream` (요청·응답은 OpenAI JSON)
- 앱 내장 로컬 서버(`127.0.0.1`) 도 켤 수 있어, OpenAI 호환 클라이언트/SDK 를 그대로 붙일 수 있음

## 요구 사항

| 항목 | 값 |
|---|---|
| 앱 배포 타깃 | **iOS 16.0+ / macOS 13.0+** (그 이상 OS 에서 설치 가능) |
| 모델 동작 | iOS / macOS **26.4+**, Apple Intelligence 지원 기기 + 활성화. 그 이하에서는 `status().reason == unsupportedOS` |
| Flutter | Swift Package Manager 통합 사용 (3.44 기본값). CocoaPods 전용 프로젝트는 미지원 |
| macOS 샌드박스 | 내장 서버 사용 시 `com.apple.security.network.server` (+ 클라이언트로 붙으면 `network.client`) |

앱의 Xcode 프로젝트에서 `IPHONEOS_DEPLOYMENT_TARGET = 16.0`, `MACOSX_DEPLOYMENT_TARGET = 13.0` 이상으로 올려야 한다.

## 사용법

```dart
import 'package:afm_bridge/afm_bridge.dart';

// 1) 상태 확인 — 사용 불가 이유와 안내 문구 제공
final status = await AfmBridge.status();
if (!status.available) {
  print(status.messageKo); // 예: "Apple Intelligence 가 꺼져 있습니다. 시스템 설정 > …"
}

// 2) 설정 (한국어 서비스는 permissive 권장 — 기본 가드레일이 평범한 질문도 차단하는 경우가 있음)
await AfmBridge.configure(permissiveGuardrails: true);
await AfmBridge.prewarm();

// 3) 간단 호출
final answer = await AfmBridge.chat('서울 여행 코스 추천해줘', system: '간결하게');
await for (final delta in AfmBridge.chatStream('가을 시 한 편')) { print(delta); }

// 4) OpenAI 형식 그대로
final res = await AfmBridge.chatCompletions({
  'messages': [AfmMessage.system('JSON 으로만'), AfmMessage.user('도시와 인구')],
  'response_format': {
    'type': 'json_schema',
    'json_schema': {'name': 'City', 'schema': {'type': 'object', 'properties': {'city': {'type': 'string'}}}}
  },
});
final stream = AfmBridge.chatCompletionsStream({'messages': [AfmMessage.user('hi')]}); // chunk Map 스트림, cancel 시 생성 취소

// 5) 앱 내장 OpenAI 호환 서버
final port = await AfmBridge.startServer(); // port 0 = 자동
// → http://127.0.0.1:$port/v1/chat/completions
await AfmBridge.stopServer();
```

에러는 `AfmBridgeException` (`status`, `code`: `context_length_exceeded`, `content_filter`, `rate_limited`, `appleIntelligenceNotEnabled`, `cancelled` …).

## 개발

```bash
flutter test                                   # Dart 단위 테스트 (채널 모킹)
cd example
flutter test integration_test -d macos         # 실제 모델
flutter test integration_test -d <iOS 시뮬레이터 id>   # 시뮬레이터는 호스트 Mac 의 모델 사용
flutter run -d macos
```

## 알려진 이슈

- **Flutter 3.44 + Xcode 27**: 유니버설 바이너리를 만드는 빌드(`flutter build macos --release`, `flutter build ios --simulator` 의 generic 대상)가
  `does not contain architectures "arm64 x86_64"` 로 실패. Xcode 27 의 `lipo -verify_arch` 가 여러 아키텍처 인자를 받지 않도록 바뀐 탓으로,
  플러그인과 무관한 Flutter 도구 문제. 특정 기기/시뮬레이터 대상 빌드(`flutter run -d …`, `flutter build ios --release --no-codesign`)와 macOS debug 는 정상.
  `flutter upgrade` 로 해결되는지 확인 필요.
- Package.swift 가 AFMBridge 패키지를 **로컬 경로**로 참조한다 (모노레포 전제). 저장소 공개 후 git URL 의존성으로 교체 예정.
