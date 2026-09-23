import Cocoa
import FlutterMacOS
import WebKit

class MainFlutterWindow: NSWindow {
  /// 파일 선택 채널 핸들러(생명주기 동안 유지).
  private var filePicker: NativeFilePicker?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 심링크를 해석하지 않고 고른 경로를 그대로 돌려주는 파일 선택 채널.
    let registrar = flutterViewController.registrar(forPlugin: "CollaboFilePicker")
    filePicker = NativeFilePicker(messenger: registrar.messenger, window: self)

    super.awakeFromNib()
  }

  /// 웹뷰(WKWebView — 채팅·뷰어·웹 검색)가 한 번 키보드 포커스(first responder)를 가져가면,
  /// 그 뒤 Flutter 쪽(트리·버튼·다른 패널)을 눌러도 되찾지 못한다 — Flutter 의 마우스 처리는
  /// first responder 를 바꾸지 않고, 웹뷰 플러그인도 돌려주지 않는다. 그래서 키 입력·단축키가
  /// 계속 웹뷰로 가서 "메인 창이 포커스를 못 받는" 것처럼 보였다.
  ///
  /// 창 단계에서 클릭을 보고, **웹뷰 바깥을 눌렀는데 포커스가 웹뷰 안에 있으면** Flutter 뷰로
  /// 돌려준다. 웹뷰 안을 누른 경우는 건드리지 않는다(웹뷰가 스스로 포커스를 가져간다).
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      reclaimFocusFromWebViewIfNeeded(for: event)
    default:
      break
    }
    super.sendEvent(event)
  }

  private func reclaimFocusFromWebViewIfNeeded(for event: NSEvent) {
    guard let flutterView = contentViewController?.view,
      let responder = firstResponder as? NSView,
      Self.enclosingWebView(of: responder) != nil,
      let content = contentView
    else { return }
    let point = content.convert(event.locationInWindow, from: nil)
    guard let hit = content.hitTest(point), Self.enclosingWebView(of: hit) == nil else { return }
    makeFirstResponder(flutterView)
  }

  /// [view] 자신이나 조상 중 WKWebView (웹뷰 내부 뷰에서 눌려도 찾도록 위로 올라간다).
  private static func enclosingWebView(of view: NSView) -> WKWebView? {
    var current: NSView? = view
    while let v = current {
      if let web = v as? WKWebView { return web }
      current = v.superview
    }
    return nil
  }
}

/// macOS 파일 선택기. NSOpenPanel 의 별칭 해석을 끄고(`resolvesAliases=false`),
/// 선택된 URL 의 경로를 **심링크 해석 없이** 그대로 반환한다(`url.path`).
///
/// venv 의 `bin/python` 은 base 인터프리터로의 심링크라, 기본 파일 선택창(및
/// file_selector)이 이를 풀어 base 경로로 바꿔 버린다 → venv 가 아니라 base 로
/// 실행돼 pip 이 PEP 668(externally-managed) 등으로 막힌다. 그래서 여기서는
/// 해석을 끄고 사용자가 고른 경로 그대로 넘긴다.
///
/// (별도 .swift 파일은 Xcode 프로젝트에 따로 등록해야 컴파일되므로, 이미 빌드에
///  포함된 이 파일 안에 함께 둔다.)
class NativeFilePicker {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?

  init(messenger: FlutterBinaryMessenger, window: NSWindow?) {
    self.window = window
    self.channel = FlutterMethodChannel(
      name: "collabo/macos_files", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "pickFile": pickFile(call.arguments as? [String: Any], result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func pickFile(_ args: [String: Any]?, _ result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = false               // 별칭 해석 끔
    panel.showsHiddenFiles = true               // .collabo/venv 등 숨김 경로 접근
    panel.treatsFilePackagesAsDirectories = true
    if let title = args?["title"] as? String, !title.isEmpty { panel.message = title }
    // 확장자 필터(예: 이미지 첨부). 미지정이면 모든 파일.
    if let exts = args?["extensions"] as? [String], !exts.isEmpty {
      panel.allowedFileTypes = exts
    }

    let respond: (NSApplication.ModalResponse) -> Void = { resp in
      guard resp == .OK, let url = panel.url else { result(nil); return }
      // 심링크를 풀지 않은, 고른 그대로의 경로를 반환한다
      // (resolvingSymlinksInPath / standardizedFileURL 등을 쓰지 않는다).
      result(url.path)
    }

    if let window = window {
      panel.beginSheetModal(for: window, completionHandler: respond)
    } else {
      respond(panel.runModal())
    }
  }
}
