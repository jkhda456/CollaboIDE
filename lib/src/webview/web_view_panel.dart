import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../app/workspace_controller.dart';
import '../ui/app_theme.dart';
import 'platform_web_view.dart';
import 'web_assets.dart';
import 'web_bridge.dart';

/// 가운데 대화 + 우측 트리/뷰어가 렌더링되는 웹뷰 영역.
///
/// 백엔드는 [PlatformWebView] 로 추상화된다(Windows=webview_windows,
/// macOS/Android/iOS=webview_flutter). Linux 등 미지원 플랫폼은 플레이스홀더.
class WebViewPanel extends StatefulWidget {
  const WebViewPanel({
    super.key,
    required this.workspace,
    required this.projectPath,
    required this.themeMode,
    required this.langCode,
  });

  final WorkspaceController workspace;
  final String? projectPath;
  final ThemeMode themeMode;

  /// 웹 UI 언어 코드('ko' | 'en').
  final String langCode;

  @override
  State<WebViewPanel> createState() => _WebViewPanelState();
}

class _WebViewPanelState extends State<WebViewPanel> {
  PlatformWebView? _view;
  WebBridge? _bridge;
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
      _bridge = WebBridge(view, widget.workspace)..start();
      // 페이지 로드가 끝나면 테마/프로젝트(=트리 루트)를 전달.
      _loadingSub = view.pageFinished.listen((_) {
        _pushStrings();
        _pushTheme();
        _bridge?.setProject(widget.projectPath);
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
    if (oldWidget.projectPath != widget.projectPath) {
      _bridge?.setProject(widget.projectPath);
    }
    if (oldWidget.themeMode != widget.themeMode) _pushTheme();
    if (oldWidget.langCode != widget.langCode) _pushStrings();
  }

  @override
  void dispose() {
    _loadingSub?.cancel();
    _bridge?.dispose();
    _view?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (!isPlatformWebViewSupported) {
      return _Placeholder(
        message: l.webviewUnsupported,
        projectPath: widget.projectPath,
      );
    }
    if (_runtimeDownloadUrl != null) {
      final url = _runtimeDownloadUrl!;
      return _Placeholder(
        message: l.webviewRuntimeMissing,
        projectPath: widget.projectPath,
        actionLabel: url.isEmpty ? null : l.webviewRuntimeDownload,
        onAction: url.isEmpty
            ? null
            : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      );
    }
    if (_error != null) {
      return _Placeholder(
        message: l.webviewInitFailed('$_error'),
        projectPath: widget.projectPath,
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
