import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app/workspace_controller.dart';
import '../browser/browser_controller.dart';
import '../browser/browser_tab.dart';
import '../browser/platform_browser_view.dart';

/// 웹 검색 화면. **VS Code 배치** — 위에 작은 도구 모음, 그 아래 탭 스트립,
/// 나머지 전부가 브라우저다.
///
/// 도구 모음·탭 스트립은 **Flutter 위젯**이고 웹뷰는 페이지 영역만 차지한다.
/// 브라우저 크롬까지 웹으로 그리면 임의의 페이지가 탭과 주소창을 흉내 낼 수
/// 있는데(스푸핑), 네이티브 크롬이면 그 길이 없다.
///
/// 탭과 웹뷰의 주인은 [BrowserController] 다 — 이 패널은 그리기만 한다. 그래서
/// 화면을 대화 쪽으로 돌려도 탭이 살아 있고, 도구가 화면 없이도 탭을 부린다.
class BrowserPanel extends StatefulWidget {
  const BrowserPanel({super.key, required this.workspace});

  final WorkspaceController workspace;

  @override
  State<BrowserPanel> createState() => _BrowserPanelState();
}

class _BrowserPanelState extends State<BrowserPanel> {
  final TextEditingController _address = TextEditingController();
  final FocusNode _addressFocus = FocusNode();

  BrowserController get _browser => widget.workspace.browser;

  /// 주소창에 마지막으로 **우리가** 넣은 값. 페이지가 이동했을 때만 갈아 끼우고
  /// 사용자가 치고 있는 중에는 건드리지 않기 위해 기억해 둔다.
  String _shownUrl = '';

  String _error = '';

  @override
  void initState() {
    super.initState();
    _browser.addListener(_onBrowserChanged);
  }

  @override
  void dispose() {
    _browser.removeListener(_onBrowserChanged);
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  void _onBrowserChanged() {
    if (!mounted) return;
    final url = _browser.activeTab?.url ?? '';
    // 사용자가 주소창을 편집 중이면 덮지 않는다(늦게 도착한 상태가 입력을
    // 지우는 것은 노트 §12-6 이 말하는 그 문제다).
    if (url != _shownUrl && !_addressFocus.hasFocus) {
      _shownUrl = url;
      _address.text = url;
    }
    setState(() {});
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _error = '');
    } on BrowserException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _submit() {
    final text = _address.text;
    _addressFocus.unfocus();
    _guard(() =>
        _browser.submitFromAddressBar(text, widget.workspace.searchEngine));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (!isPlatformBrowserSupported) {
      return _Message(icon: Icons.public_off, text: l.browserUnsupported);
    }
    final theme = Theme.of(context);
    return Column(
      children: [
        _Toolbar(
          address: _address,
          focus: _addressFocus,
          tab: _browser.activeTab,
          onSubmit: _submit,
          onBack: () => _guard(() =>
              _browser.navigateAction(_browser.activeId, 'back')),
          onForward: () => _guard(() =>
              _browser.navigateAction(_browser.activeId, 'forward')),
          onReloadOrStop: () => _guard(() => _browser.navigateAction(
              _browser.activeId,
              (_browser.activeTab?.isLoading ?? false) ? 'stop' : 'reload')),
        ),
        _TabStrip(
          tabs: _browser.tabs,
          activeId: _browser.activeId,
          onSelect: _browser.activate,
          onClose: (id) => _guard(() => _browser.closeTab(id)),
          onNew: () => _guard(() async {
            await _browser.newTab();
            _address.clear();
            _shownUrl = '';
            _addressFocus.requestFocus();
          }),
          onCloseAll: () => _guard(() async {
            await _browser.closeAll();
            _address.clear();
            _shownUrl = '';
          }),
          onCloseAgent: () =>
              _guard(() => _browser.closeAll(owner: TabOwner.agent)),
        ),
        if (_error.isNotEmpty)
          Container(
            width: double.infinity,
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              _error,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        const Divider(height: 1, thickness: 1),
        Expanded(child: _pages(l)),
      ],
    );
  }

  /// 탭마다의 웹뷰. **[IndexedStack] 이라 안 보이는 탭도 레이아웃을 받는다** —
  /// 크기가 0 이면 뷰포트에 기대는 페이지가 어긋나므로, 배경 탭을 그냥 트리에서
  /// 빼면 안 된다. 여기서는 그리지만 않는다.
  Widget _pages(AppLocalizations l) {
    final tabs = _browser.tabs;
    if (tabs.isEmpty) {
      return _Message(
        icon: Icons.travel_explore,
        text: l.browserEmpty,
        actionLabel: l.browserNewTab,
        onAction: () => _guard(() async {
          await _browser.newTab();
          _addressFocus.requestFocus();
        }),
      );
    }
    var index = tabs.indexWhere((t) => t.id == _browser.activeId);
    if (index < 0) index = 0;
    return IndexedStack(
      index: index,
      children: [
        for (final t in tabs)
          KeyedSubtree(
            key: ValueKey(t.id),
            child: _browser.viewOf(t.id)?.buildView() ?? const SizedBox.shrink(),
          ),
      ],
    );
  }
}

/// 위쪽 한 줄: 뒤로 / 앞으로 / 새로고침·중지 + 주소창.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.address,
    required this.focus,
    required this.tab,
    required this.onSubmit,
    required this.onBack,
    required this.onForward,
    required this.onReloadOrStop,
  });

  final TextEditingController address;
  final FocusNode focus;
  final BrowserTab? tab;
  final VoidCallback onSubmit;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReloadOrStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final loading = tab?.isLoading ?? false;
    final hasTab = tab != null;
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 18),
            tooltip: l.browserBack,
            visualDensity: VisualDensity.compact,
            onPressed: (tab?.canGoBack ?? false) ? onBack : null,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward, size: 18),
            tooltip: l.browserForward,
            visualDensity: VisualDensity.compact,
            onPressed: (tab?.canGoForward ?? false) ? onForward : null,
          ),
          IconButton(
            icon: Icon(loading ? Icons.close : Icons.refresh, size: 18),
            tooltip: loading ? l.browserStop : l.browserReload,
            visualDensity: VisualDensity.compact,
            onPressed: hasTab ? onReloadOrStop : null,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: address,
                focusNode: focus,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => onSubmit(),
                style: theme.textTheme.bodySmall,
                decoration: InputDecoration(
                  hintText: l.browserAddressHint,
                  isDense: true,
                  filled: true,
                  fillColor: theme.colorScheme.surface,
                  prefixIcon: const Icon(Icons.search, size: 16),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: theme.dividerColor),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }
}

/// 주소창 아래 탭 줄. 사용자 탭과 에이전트 탭이 **한 줄에 섞여 있다** —
/// 나누지 않기로 했고, 에이전트가 연 탭은 작은 점으로만 구분한다.
class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
    required this.onCloseAll,
    required this.onCloseAgent,
  });

  final List<BrowserTab> tabs;
  final String activeId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final VoidCallback onNew;
  final VoidCallback onCloseAll;
  final VoidCallback onCloseAgent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final agentTabs = tabs.where((t) => t.owner == TabOwner.agent).length;
    return Container(
      height: 34,
      color: theme.colorScheme.surfaceContainerHigh,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final t in tabs)
                  _TabChip(
                    tab: t,
                    selected: t.id == activeId,
                    onTap: () => onSelect(t.id),
                    onClose: () => onClose(t.id),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            tooltip: l.browserNewTab,
            visualDensity: VisualDensity.compact,
            onPressed: tabs.length >= BrowserController.maxTabs ? null : onNew,
          ),
          // 에이전트 탭만 치우는 쪽을 먼저 둔다 — 조사 몇 번이면 에이전트 탭이
          // 쌓여 보던 탭이 묻히는데, 그때 필요한 게 대개 이쪽이다.
          // 지울 게 없으면 꺼 둔다(누를 수 있는데 아무 일도 안 나는 편이 더 나쁘다).
          IconButton(
            icon: const Icon(Icons.smart_toy_outlined, size: 17),
            tooltip: l.browserCloseAgentTabs,
            visualDensity: VisualDensity.compact,
            onPressed: agentTabs == 0 ? null : onCloseAgent,
          ),
          IconButton(
            icon: const Icon(Icons.clear_all, size: 18),
            tooltip: l.browserCloseAll,
            visualDensity: VisualDensity.compact,
            onPressed: tabs.isEmpty ? null : onCloseAll,
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final BrowserTab tab;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final label = tab.label.isEmpty ? l.browserNewTab : tab.label;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.only(left: 10, right: 2),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.surface : null,
          border: Border(
            bottom: BorderSide(
              width: 2,
              color:
                  selected ? theme.colorScheme.primary : Colors.transparent,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tab.isLoading)
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            else if (tab.load == TabLoad.failed)
              Icon(Icons.error_outline,
                  size: 12, color: theme.colorScheme.error)
            else if (tab.owner == TabOwner.agent)
              // 에이전트가 연 탭임을 알리는 점. 권한 표시가 아니라 꼬리표다.
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              )
            else
              const SizedBox(width: 7),
            const SizedBox(width: 6),
            Flexible(
              child: Tooltip(
                message: tab.url.isEmpty ? label : '$label\n${tab.url}',
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 13),
              tooltip: l.browserCloseTab,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// 탭이 없거나 플랫폼이 지원되지 않을 때의 가운데 안내.
class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
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
          Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(text,
              textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add, size: 18),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
