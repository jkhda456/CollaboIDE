import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../l10n/app_localizations.dart';
import '../files/file_viewer.dart';
import '../ui/app_theme.dart';
import 'platform_web_view.dart';
import 'web_assets.dart';

/// 파일 뷰어의 **보기 영역** — 뷰어 전용 웹뷰(`assets/web/viewer.html`).
///
/// 틀(파일명·뷰어 선택·복사·전체화면)은 네이티브(`FileViewerFrame`)가 그리고, 여기는
/// 뷰어 플러그인이 그리는 자리다. 대화 웹뷰([WebViewPanel])와 같은 방식으로, 웹뷰를
/// 만들어 **컨트롤러에 붙였다 뗄** 뿐이다 — 연 파일·뷰어 선택은 컨트롤러가 들고 있어,
/// 이 위젯이 다시 만들어져도(패널 재배치 등) 페이지가 `ready` 를 보내면 되살아난다.
class ViewerWebView extends StatefulWidget {
  const ViewerWebView({
    super.key,
    required this.controller,
    required this.themeMode,
    required this.langCode,
    this.visible = true,
  });

  final FileViewerController controller;
  final ThemeMode themeMode;
  final String langCode;

  /// 지금 보이는지. 다시 보일 때 페이지가 크기를 다시 재게 한다(대화 웹뷰와 같은 이유).
  final bool visible;

  @override
  State<ViewerWebView> createState() => _ViewerWebViewState();
}

class _ViewerWebViewState extends State<ViewerWebView> {
  PlatformWebView? _view;
  StreamSubscription<void>? _loadingSub;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (isPlatformWebViewSupported) unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final view = createPlatformWebView();
      _view = view;
      await view.initialize();
      _loadingSub = view.pageFinished.listen((_) {
        unawaited(_pushStrings());
        unawaited(_pushTheme());
        unawaited(widget.controller.attachView(view));
      });
      await view.loadUrl(await WebAssets.pageUrl('viewer.html'));
      if (mounted) setState(() => _ready = true);
    } on WebViewRuntimeMissing {
      // 런타임 안내는 대화 웹뷰가 이미 크게 띄운다 — 여기선 조용히 비워 둔다.
      if (mounted) setState(() => _error = '');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 대화 페이지와 **같은 언어팩**을 쓴다(뷰어 문구가 거기 있다 — 뷰어 플러그인도 T() 로 쓴다).
  Future<void> _pushStrings() async {
    try {
      final json = await rootBundle.loadString('assets/web/lang/${widget.langCode}.json');
      await _view?.executeScript('window.collaboSetStrings($json)');
    } catch (_) {}
  }

  Future<void> _pushTheme() async {
    final platform = MediaQuery.maybeOf(context)?.platformBrightness ?? Brightness.light;
    final theme = AppTheme.bootstrapTheme(widget.themeMode, platform);
    await _view?.executeScript('window.collaboSetTheme?.("$theme");');
  }

  @override
  void didUpdateWidget(ViewerWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    if (!identical(oldWidget.controller, widget.controller)) {
      final v = _view;
      if (v != null) {
        unawaited(oldWidget.controller.detachView());
        unawaited(widget.controller.attachView(v));
      }
    }
    if (oldWidget.themeMode != widget.themeMode) unawaited(_pushTheme());
    if (oldWidget.langCode != widget.langCode) unawaited(_pushStrings());
    if (widget.visible && !oldWidget.visible) {
      _view?.executeScript('window.dispatchEvent(new Event("resize"))');
    }
  }

  @override
  void dispose() {
    _loadingSub?.cancel();
    // 컨트롤러는 세션의 것 — 화면만 뗀다(연 파일은 컨트롤러가 기억한다).
    unawaited(widget.controller.detachView());
    _view?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!isPlatformWebViewSupported || _error != null) {
      final msg = !isPlatformWebViewSupported
          ? AppLocalizations.of(context).webviewUnsupported
          : (_error!.isEmpty ? '' : AppLocalizations.of(context).webviewInitFailed(_error!));
      return Container(
        color: theme.colorScheme.surface,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Text(msg,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    final view = _view;
    if (!_ready || view == null) {
      return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final child = view.buildView();
    if (!view.needsWheelWorkaround) return child;
    // webview_windows 0.4.0 은 휠을 (0,0) 으로 보낸다 — 대화 웹뷰와 같은 보정.
    return Listener(
      onPointerSignal: (signal) {
        if (signal is PointerScrollEvent) {
          view.executeScript(
              'window.collaboWheel && collaboWheel(${signal.scrollDelta.dx},${signal.scrollDelta.dy})');
        }
      },
      child: child,
    );
  }
}
