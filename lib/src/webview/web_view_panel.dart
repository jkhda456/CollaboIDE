import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../app/project_session.dart';
import '../ui/app_theme.dart';
import 'platform_web_view.dart';
import 'web_assets.dart';

/// 프로젝트 하나의 화면(가운데 대화 + 우측 트리/뷰어)을 그리는 웹뷰 영역.
///
/// ★ **이 패널은 브리지를 만들지 않는다.** 브리지는 [ProjectSession] 의 것이고,
/// 여기서는 웹뷰를 만들어 **붙였다 뗄** 뿐이다. 예전에는 패널이 브리지를 소유해서,
/// 화면이 사라지면 돌고 있던 에이전트 루프가 같이 죽었다 — 다른 프로젝트를 열거나
/// 웹 검색 화면으로 옮기는 것만으로 작업이 통째로 날아갔다.
///
/// 백엔드는 [PlatformWebView] 로 추상화된다(Windows=webview_windows,
/// macOS/Android/iOS=webview_flutter). Linux 등 미지원 플랫폼은 플레이스홀더.
class WebViewPanel extends StatefulWidget {
  const WebViewPanel({
    super.key,
    required this.session,
    required this.themeMode,
    required this.langCode,
    this.visible = true,
  });

  /// 이 패널이 보여 주는 프로젝트.
  final ProjectSession session;

  /// 지금 화면에 보이는지.
  ///
  /// 패널은 안 보여도 트리에 남아 있다(IndexedStack). 그동안 페이지가 **잘못된
  /// 크기로 잰 값을 인라인 스타일로 굳혀 둘 수 있어서**(입력창 높이가 대표적이다),
  /// 다시 보일 때 한 번 다시 재게 한다.
  final bool visible;

  final ThemeMode themeMode;

  /// 웹 UI 언어 코드('ko' | 'en').
  final String langCode;

  @override
  State<WebViewPanel> createState() => _WebViewPanelState();
}

class _WebViewPanelState extends State<WebViewPanel> {
  PlatformWebView? _view;
  StreamSubscription<void>? _loadingSub;
  bool _ready = false;
  String? _error;

  /// 런타임 미설치(WebView2 등) 시 안내 화면 + 다운로드 링크.
  String? _runtimeDownloadUrl;

  @override
  void initState() {
    super.initState();
    if (isPlatformWebViewSupported) _initWebView();
  }

  Future<void> _initWebView() async {
    try {
      final view = createPlatformWebView();
      _view = view;
      await view.initialize();
      // 페이지 로드가 끝나면 테마/언어를 넣고, 브리지에 이 웹뷰를 붙인다.
      _loadingSub = view.pageFinished.listen((_) {
        _pushStrings();
        _pushTheme();
        unawaited(widget.session.bridge?.attachView(view) ?? Future.value());
      });
      // 임베드된 웹 리소스를 디스크로 추출 후 file:// 로 로드(오프라인 동작).
      final indexUrl = await WebAssets.extractAndGetIndexUrl();
      await view.loadUrl(indexUrl);
      if (!mounted) return;
      setState(() => _ready = true);
    } on WebViewRuntimeMissing catch (e) {
      if (!mounted) return;
      setState(() => _runtimeDownloadUrl = e.downloadUrl ?? '');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  /// 현재 언어의 웹 언어팩(JSON)을 웹으로 전달한다.
  Future<void> _pushStrings() async {
    try {
      final json =
          await rootBundle.loadString('assets/web/lang/${widget.langCode}.json');
      await _view?.executeScript('window.collaboSetStrings($json)');
    } catch (_) {
      // 언어팩 누락 시 기본(HTML 내장) 문자열 유지.
    }
  }

  /// 현재 테마(라이트/다크)를 웹 페이지(Bootstrap)로 전달한다.
  Future<void> _pushTheme() async {
    final platform =
        MediaQuery.maybeOf(context)?.platformBrightness ?? Brightness.light;
    final theme = AppTheme.bootstrapTheme(widget.themeMode, platform);
    await _view?.executeScript('window.collaboSetTheme?.("$theme");');
  }

  @override
  void didUpdateWidget(WebViewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    if (oldWidget.themeMode != widget.themeMode) _pushTheme();
    if (oldWidget.langCode != widget.langCode) _pushStrings();
    if (widget.visible && !oldWidget.visible) _remeasure();
  }

  /// 화면에 (다시) 나타났을 때 페이지가 크기를 다시 재게 한다.
  ///
  /// 백엔드에 따라 `visibilitychange` 나 `resize` 가 안 올 수 있어 직접 쏜다.
  /// 웹은 이 이벤트에서 입력창 높이를 다시 계산한다(`index.html` 의 `autoGrow`).
  void _remeasure() {
    _view?.executeScript('window.dispatchEvent(new Event("resize"))');
  }

  @override
  void dispose() {
    _loadingSub?.cancel();
    // **브리지는 버리지 않는다** — 세션의 것이고, 화면만 떼어 낸다.
    unawaited(widget.session.bridge?.detachView() ?? Future.value());
    _view?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (!isPlatformWebViewSupported) {
      return _Placeholder(
        message: l.webviewUnsupported,
        projectPath: widget.session.path,
      );
    }
    if (_runtimeDownloadUrl != null) {
      final url = _runtimeDownloadUrl!;
      return _Placeholder(
        message: l.webviewRuntimeMissing,
        projectPath: widget.session.path,
        actionLabel: url.isEmpty ? null : l.webviewRuntimeDownload,
        onAction: url.isEmpty
            ? null
            : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      );
    }
    if (_error != null) {
      return _Placeholder(
        message: l.webviewInitFailed('$_error'),
        projectPath: widget.session.path,
      );
    }
    final view = _view;
    if (!_ready || view == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final child = view.buildView();
    if (!view.needsWheelWorkaround) return child;
    // webview_windows 0.4.0 은 마우스 휠을 항상 (0,0) 으로 보내는 버그가 있어
    // 어디서도 스크롤이 안 된다. 휠 신호를 가로채 커서 아래 요소를 JS 로 스크롤한다.
    return Listener(
      onPointerSignal: (signal) {
        if (signal is PointerScrollEvent) {
          final dx = signal.scrollDelta.dx;
          final dy = signal.scrollDelta.dy;
          view.executeScript('window.collaboWheel && collaboWheel($dx,$dy)');
        }
      },
      child: child,
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.message,
    required this.projectPath,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? projectPath;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.web_outlined,
              size: 48, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(message,
              textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            projectPath ?? AppLocalizations.of(context).noOpenProject,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.download, size: 18),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
