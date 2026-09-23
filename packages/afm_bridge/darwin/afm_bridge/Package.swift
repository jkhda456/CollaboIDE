// swift-tools-version: 6.2
import PackageDescription

// afm_bridge 플러그인 — collabo_ide 안의 복사본. **외부 의존성 없이 이 폴더만으로 빌드된다.**
//
// AFMBridge Swift 패키지의 소스(Core / Engine / Server)를 Sources/ 아래에 그대로 복사해 두었다
// (원본: AFMBridge 저장소의 Sources/AFMBridge{Core,Engine,Server}). 갱신 방법은 README.collabo.md.
//
//   AFMBridgeCore    OpenAI 타입, 순서 보존 JSON, JSON Schema IR, SSE (FoundationModels 비의존)
//   AFMBridgeEngine  AFMEngine — OpenAI 요청 → FoundationModels 호출 (26.4+ 가용성 분기, weak link)
//   AFMBridgeServer  AFMServer — 앱 내장 OpenAI 호환 로컬 서버 (Network.framework)
//   afm_bridge       Flutter 채널 플러그인 (MethodChannel `afm_bridge`, EventChannel `afm_bridge/stream`)
//
// 최소 배포 타깃은 iOS 15 / macOS 12 — 모델 자체는 26.4+ 에서만 동작하고, 그 아래에서는
// status 가 unsupportedOS 를 돌려준다(앱은 정상 실행).

let afmSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
  name: "afm_bridge",
  platforms: [
    .iOS("15.0"),
    .macOS("12.0"),
  ],
  products: [
    .library(name: "afm-bridge", targets: ["afm_bridge"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(name: "AFMBridgeCore", swiftSettings: afmSwiftSettings),
    .target(name: "AFMBridgeEngine", dependencies: ["AFMBridgeCore"], swiftSettings: afmSwiftSettings),
    .target(
      name: "AFMBridgeServer", dependencies: ["AFMBridgeCore", "AFMBridgeEngine"], swiftSettings: afmSwiftSettings),
    .target(
      name: "afm_bridge",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        "AFMBridgeCore",
        "AFMBridgeEngine",
        "AFMBridgeServer",
      ],
      resources: [
        .process("PrivacyInfo.xcprivacy")
      ],
      // Flutter 타입은 Sendable 주석이 없어 플러그인 타깃만 Swift 5 모드로 둔다
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
