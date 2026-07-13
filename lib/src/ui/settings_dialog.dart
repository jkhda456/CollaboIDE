import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../app/workspace_controller.dart';
import '../llm/llm_config.dart';
import '../llm/llm_preset.dart';
import '../llm/openai_client.dart';
import '../llm/system_prompt.dart';
import '../platform/mac_file_picker.dart';
import '../tools/tool_module.dart';
import '../tools/tool_runner.dart';
import '../tools/tool_source.dart';
import 'console_dialog.dart';

/// 설정 창을 띄운다(탭: 모델 / 모양).
Future<void> showSettingsDialog(
  BuildContext context,
  WorkspaceController workspace,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SettingsDialog(workspace: workspace),
  );
}

/// 첫 실행 초기 설정 마법사를 띄운다.
///
/// 별도 페이지를 만들지 않고 설정 탭 위젯(_AppearanceTab/_ModelTab/_ToolsTab)을
/// **모양 → 모델 → 도구** 순서로 재사용한다. "다음" 을 누르면 순차 진행하며,
/// 모델 단계에서는 입력한 연결 설정이 적용(저장)된다.
Future<void> showFirstRunWizard(
  BuildContext context,
  WorkspaceController workspace,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SetupWizard(workspace: workspace),
  );
}

class _SetupWizard extends StatefulWidget {
  const _SetupWizard({required this.workspace});
  final WorkspaceController workspace;

  @override
  State<_SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<_SetupWizard> {
  static const int _stepCount = 3;
  int _step = 0;
  final GlobalKey<_ModelTabState> _modelKey = GlobalKey<_ModelTabState>();

  WorkspaceController get _ws => widget.workspace;

  String _stepTitle(AppLocalizations l) => switch (_step) {
        0 => l.tabAppearance,
        1 => l.tabModel,
        _ => l.tabTools,
      };

  Widget _stepBody() => switch (_step) {
        0 => _AppearanceTab(workspace: _ws),
        1 => _ModelTab(key: _modelKey, workspace: _ws),
        _ => _ToolsTab(workspace: _ws),
      };

  Future<void> _finish() async {
    await _ws.markSetupComplete();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _next() async {
    // 모델 단계에서는 입력한 연결 설정을 적용(저장)하고 넘어간다.
    if (_step == 1) await _modelKey.currentState?.commit();
    if (_step < _stepCount - 1) {
      setState(() => _step++);
    } else {
      await _finish();
    }
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isLast = _step == _stepCount - 1;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(l.wizardTitle,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text(l.wizardStep(_step + 1, _stepCount),
                          style: theme.textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(l.wizardIntro, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (var i = 0; i < _stepCount; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        Expanded(
                          child: Container(
                            height: 4,
                            decoration: BoxDecoration(
                              color: i <= _step
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(_stepTitle(l), style: theme.textTheme.titleSmall),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _stepBody()),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  TextButton(onPressed: _finish, child: Text(l.skipSetup)),
                  const Spacer(),
                  if (_step > 0)
                    TextButton(onPressed: _back, child: Text(l.back)),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _next,
                    child: Text(isLast ? l.finish : l.next),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsDialog extends StatelessWidget {
  const _SettingsDialog({required this.workspace});

  final WorkspaceController workspace;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: DefaultTabController(
          length: 5,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    Text(l.settingsTitle,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              TabBar(
                isScrollable: true,
                tabs: [
                  Tab(text: l.tabModel),
                  Tab(text: l.tabPrompt),
                  Tab(text: l.tabTools),
                  Tab(text: l.tabAppearance),
                  Tab(text: l.tabAbout),
                ],
              ),
              Flexible(
                child: TabBarView(
                  children: [
                    _ModelTab(workspace: workspace),
                    _PromptTab(workspace: workspace),
                    _ToolsTab(workspace: workspace),
                    _AppearanceTab(workspace: workspace),
                    const _AboutTab(),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l.close),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 정보 탭: 프로그램명 / 버전·빌드 / GitHub 링크 / 오픈소스 안내.
class _AboutTab extends StatelessWidget {
  const _AboutTab();

  static final Uri _github = Uri.parse('https://github.com/jkhda456/CollaboIDE');

  static const String _openSourceList =
      'Flutter · webview_windows · webview_flutter · sqflite · sqlite3 · '
      'path · path_provider · http · url_launcher · file_selector · archive · '
      'intl · package_info_plus · Bootstrap (MIT) · marked (MIT)';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 마스코트 아이콘 + 제목/버전 (아이콘을 글씨 왼쪽에 배치)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Image.asset(
                'assets/images/icon.png',
                width: 56,
                height: 56,
                filterQuality: FilterQuality.medium,
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Collabo IDE',
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  // 버전 + 빌드 번호
                  FutureBuilder<PackageInfo>(
                    future: PackageInfo.fromPlatform(),
                    builder: (context, snap) {
                      final info = snap.data;
                      final text = info == null
                          ? '…'
                          : l.aboutVersion(info.version, info.buildNumber);
                      return Text(text,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant));
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          // GitHub 링크
          InkWell(
            onTap: () =>
                launchUrl(_github, mode: LaunchMode.externalApplication),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.open_in_new, size: 16),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _github.toString(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 오픈소스
          Text(l.openSourceTitle, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(l.openSourceIntro, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Text(_openSourceList,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () =>
                showLicensePage(context: context, applicationName: 'Collabo IDE'),
            icon: const Icon(Icons.description_outlined, size: 18),
            label: Text(l.viewLicenses),
          ),
        ],
      ),
    );
  }
}

/// 모델 탭: 연결방식 / URL / KEY / 모델 + 연결 상태 확인.
class _ModelTab extends StatefulWidget {
  const _ModelTab({super.key, required this.workspace});
  final WorkspaceController workspace;

  @override
  State<_ModelTab> createState() => _ModelTabState();
}

class _ModelTabState extends State<_ModelTab> {
  late String _selectedId; // 현재 편집 중인 프리셋 id
  final MenuController _presetMenuCtrl = MenuController();
  late LlmConnection _connection;
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;

  bool _testing = false;
  bool _showKey = false; // API 키 마스크 해제 여부
  bool _multimodal = false; // 멀티모달(이미지 입력) 지원
  bool _parseTextToolCalls = false; // 본문 텍스트 도구호출 파싱(openai 폴백)
  String _reasoningEffort = ''; // 추론 강도('' = 미전송 | none | low | high)
  LlmTestResult? _result;

  // 추론 강도 드롭다운 선택지.
  // ''      → "안 붙이기": reasoning_effort 를 요청에 아예 포함하지 않음.
  // 'none'  → reasoning_effort: "none" 전송(추론 끔).
  // 'low'/'high' → 해당 강도로 전송.
  static const List<String> _reasoningOptions = ['', 'none', 'low', 'high'];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _baseUrl = TextEditingController();
    _apiKey = TextEditingController();
    _model = TextEditingController();
    final presets = widget.workspace.llmPresets;
    _selectedId = widget.workspace.defaultPresetId.isNotEmpty
        ? widget.workspace.defaultPresetId
        : (presets.isNotEmpty ? presets.first.id : '');
    _loadSelected();
  }

  LlmPreset? get _selectedPreset {
    for (final p in widget.workspace.llmPresets) {
      if (p.id == _selectedId) return p;
    }
    return widget.workspace.llmPresets.isNotEmpty
        ? widget.workspace.llmPresets.first
        : null;
  }

  /// 선택된 프리셋의 값을 폼 컨트롤러/상태로 로드한다.
  void _loadSelected() {
    final p = _selectedPreset;
    final cfg = p?.config ?? const LlmConfig();
    if (p != null) _selectedId = p.id;
    _name.text = p?.name ?? '';
    _connection = cfg.connection;
    _baseUrl.text = cfg.baseUrl;
    _apiKey.text = cfg.apiKey;
    _model.text = cfg.model;
    _multimodal = cfg.multimodal;
    _parseTextToolCalls = cfg.parseTextToolCalls;
    _reasoningEffort =
        _reasoningOptions.contains(cfg.reasoningEffort) ? cfg.reasoningEffort : '';
    _result = null;
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  LlmConfig get _current => LlmConfig(
        connection: _connection,
        baseUrl: _baseUrl.text.trim(),
        apiKey: _apiKey.text.trim(),
        model: _model.text.trim(),
        multimodal: _multimodal,
        reasoningEffort: _reasoningEffort,
        parseTextToolCalls: _parseTextToolCalls,
      );

  /// 변경 즉시 선택된 프리셋에 자동 저장한다(이름 + 설정).
  Future<void> _persist() => widget.workspace
      .updatePreset(_selectedId, name: _name.text.trim(), config: _current);

  /// 초기 설정 마법사에서 "다음" 시 마지막 입력까지 확실히 저장하기 위한 flush.
  Future<void> commit() => _persist();

  Future<void> _selectPreset(String id) async {
    await _persist(); // 전환 전 현재 편집분 저장
    setState(() {
      _selectedId = id;
      _loadSelected();
    });
  }

  Future<void> _addPreset() async {
    final l = AppLocalizations.of(context);
    await _persist();
    final preset = await widget.workspace.addPreset(name: l.newPresetName);
    if (!mounted) return;
    setState(() {
      _selectedId = preset.id;
      _loadSelected();
    });
  }

  Future<void> _deletePreset() async {
    if (widget.workspace.llmPresets.length <= 1) return;
    await widget.workspace.removePreset(_selectedId);
    if (!mounted) return;
    setState(() {
      _selectedId = widget.workspace.defaultPresetId;
      _loadSelected();
    });
  }

  Future<void> _makeDefault([String? id]) async {
    await widget.workspace.setDefaultPreset(id ?? _selectedId);
    if (mounted) setState(() {});
  }

  /// 현재 프리셋 이름 변경(작은 다이얼로그). 프로필 메뉴에서 호출.
  Future<void> _renamePreset() async {
    final l = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: _name.text);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.renamePreset),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l.presetNameLabel,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(l.save)),
        ],
      ),
    );
    ctrl.dispose();
    if (newName == null) return;
    _name.text = newName.trim();
    await _persist();
    if (mounted) setState(() {});
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    // 선택한 연결 방식에 맞는 provider 로 연결을 확인하고 끝나면 정리한다.
    final provider = createLlmProvider(_current.connection);
    final LlmTestResult r;
    try {
      r = await provider.test(_current);
    } finally {
      provider.dispose();
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = r;
    });
  }

  /// 프로필 아바타 + 팝업 메뉴(프리셋 선택/추가/이름변경/기본설정/삭제)를 한 곳에서.
  Widget _buildPresetSwitcher(
      BuildContext context, AppLocalizations l, ThemeData theme) {
    final presets = widget.workspace.llmPresets;
    final defaultId = widget.workspace.defaultPresetId;
    final current = _selectedPreset;
    final currentModel = current?.config.model.trim() ?? '';
    return MenuAnchor(
      controller: _presetMenuCtrl,
      builder: (context, controller, _) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              _PresetAvatar(
                  seed: current?.id ?? '', label: current?.label ?? '?', size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(current?.label ?? '',
                              style: theme.textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (current != null && current.id == defaultId) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.star,
                              size: 14, color: theme.colorScheme.primary),
                        ],
                      ],
                    ),
                    Text(
                      currentModel.isEmpty ? l.presetLabel : currentModel,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.expand_more, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(l.selectPreset,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        for (final pr in presets)
          _presetMenuRow(context, l, theme, pr, defaultId),
        const Divider(height: 8),
        MenuItemButton(
          leadingIcon: const Icon(Icons.add, size: 18),
          onPressed: _addPreset,
          child: Text(l.addPreset),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.edit_outlined, size: 18),
          onPressed: _renamePreset,
          child: Text(l.renamePreset),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.delete_outline, size: 18),
          onPressed: presets.length <= 1 ? null : _deletePreset,
          child: Text(l.deletePreset),
        ),
      ],
    );
  }

  /// 메뉴 안의 프리셋 한 줄: 본문 탭 = 선택, 우측 별 = 기본으로 지정.
  Widget _presetMenuRow(BuildContext context, AppLocalizations l,
      ThemeData theme, LlmPreset pr, String defaultId) {
    final selected = pr.id == _selectedId;
    final isDef = pr.id == defaultId;
    return SizedBox(
      width: 320,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                _presetMenuCtrl.close();
                if (!selected) _selectPreset(pr.id);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    _PresetAvatar(seed: pr.id, label: pr.label, size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(pr.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.normal)),
                    ),
                    if (selected)
                      Icon(Icons.check,
                          size: 16, color: theme.colorScheme.primary),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            tooltip: isDef ? l.isDefaultPreset : l.setAsDefault,
            icon: Icon(isDef ? Icons.star : Icons.star_border,
                color: isDef ? theme.colorScheme.primary : null),
            onPressed: isDef ? null : () => _makeDefault(pr.id),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- 프리셋 프로필 스위처(아이콘 하나로 선택/추가/이름변경/기본/삭제) ---
          _buildPresetSwitcher(context, l, theme),
          const Divider(height: 24),
          DropdownButtonFormField<LlmConnection>(
            initialValue: _connection,
            decoration: InputDecoration(
                labelText: l.connectionMethod, border: const OutlineInputBorder()),
            items: [
              DropdownMenuItem(
                  value: LlmConnection.openai, child: Text(l.openaiCompatible)),
              DropdownMenuItem(
                  value: LlmConnection.openaiPrompted,
                  child: Text(l.openaiPrompted)),
            ],
            onChanged: (v) {
              setState(() => _connection = v ?? _connection);
              _persist();
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'https://api.openai.com/v1',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _persist(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            decoration: InputDecoration(
              labelText: 'API Key',
              border: const OutlineInputBorder(),
              // 오른쪽 아이콘으로 마스크 보기/숨기기 토글.
              suffixIcon: IconButton(
                icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility,
                    size: 18),
                tooltip: _showKey ? l.hideKey : l.showKey,
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
            onChanged: (_) => _persist(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            decoration: InputDecoration(
              labelText: l.modelLabel,
              hintText: 'gpt-4o-mini',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => _persist(),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(l.multimodalSupport),
            subtitle: Text(l.multimodalSupportDesc,
                style: theme.textTheme.bodySmall),
            value: _multimodal,
            onChanged: (v) {
              setState(() => _multimodal = v);
              _persist();
            },
          ),
          // 본문 텍스트 도구호출 파싱 폴백: openai 연결에서만 의미가 있다
          // (openaiPrompted 는 이 파싱이 본질이라 항상 동작).
          if (_connection == LlmConnection.openai)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l.parseTextToolCalls),
              subtitle: Text(l.parseTextToolCallsDesc,
                  style: theme.textTheme.bodySmall),
              value: _parseTextToolCalls,
              onChanged: (v) {
                setState(() => _parseTextToolCalls = v);
                _persist();
              },
            ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _reasoningEffort,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l.reasoningEffort,
              helperText: l.reasoningEffortDesc,
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final opt in _reasoningOptions)
                DropdownMenuItem(
                  value: opt,
                  child: Text(opt.isEmpty ? l.reasoningEffortOff : opt),
                ),
            ],
            onChanged: (v) {
              setState(() => _reasoningEffort = v ?? '');
              _persist();
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering, size: 18),
                label: Text(l.testConnection),
              ),
            ],
          ),
          if (_result != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  _result!.ok ? Icons.check_circle : Icons.error,
                  color: _result!.ok ? Colors.green : theme.colorScheme.error,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(_result!.message)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 프롬프트 탭: 실행 전략 시스템 프롬프트(영어 기본)를 사용자가 편집한다.
class _PromptTab extends StatefulWidget {
  const _PromptTab({required this.workspace});
  final WorkspaceController workspace;

  @override
  State<_PromptTab> createState() => _PromptTabState();
}

class _PromptTabState extends State<_PromptTab> {
  late final TextEditingController _ctrl;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.workspace.systemPromptRaw);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListenableBuilder(
            listenable: widget.workspace,
            builder: (context, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l.usePreAssessment),
              subtitle: Text(l.usePreAssessmentDesc, style: theme.textTheme.bodySmall),
              value: widget.workspace.preAssessment,
              onChanged: widget.workspace.setPreAssessment,
            ),
          ),
          const Divider(height: 16),
          Text(l.systemPromptDesc, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: _ctrl,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              decoration: const InputDecoration(border: OutlineInputBorder()),
              onChanged: (_) => setState(() => _saved = false),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                onPressed: () async {
                  await widget.workspace.setSystemPrompt(_ctrl.text);
                  if (context.mounted) setState(() => _saved = true);
                },
                child: Text(l.save),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  _ctrl.text = kDefaultSystemPrompt;
                  setState(() => _saved = false);
                },
                child: Text(l.resetDefault),
              ),
              const SizedBox(width: 12),
              if (_saved) Text(l.saved, style: TextStyle(color: theme.colorScheme.primary)),
            ],
          ),
        ],
      ),
    );
  }
}

/// 도구 탭: function calling 으로 확장되는 도구 목록.
/// 기본(고정) + 일반 Python 스크립트(--help 자동 파싱) + MCP 도구를 추가/제거한다.
class _ToolsTab extends StatelessWidget {
  const _ToolsTab({required this.workspace});
  final WorkspaceController workspace;

  Future<void> _add(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final kind = await showDialog<ToolSourceKind>(
      context: context,
      builder: (_) => SimpleDialog(
        title: Text(l.addTool),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ToolSourceKind.cli),
            child: ListTile(
              leading: const Icon(Icons.terminal),
              title: Text(l.addToolCli),
              subtitle: Text(l.addToolCliDesc),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ToolSourceKind.mcp),
            child: ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: Text(l.addToolMcp),
              subtitle: Text(l.addToolMcpDesc),
            ),
          ),
        ],
      ),
    );
    if (kind == null || !context.mounted) return;

    ToolSource? source;
    if (kind == ToolSourceKind.cli) {
      const typeGroup = XTypeGroup(label: 'Python', extensions: ['py']);
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file != null) source = ToolSource(kind: ToolSourceKind.cli, script: file.path);
    } else {
      if (context.mounted) source = await _showMcpDialog(context);
    }
    if (source != null) await workspace.addToolSource(source);
  }

  Future<ToolSource?> _showMcpDialog(BuildContext context) {
    final l = AppLocalizations.of(context);
    final command = TextEditingController();
    final args = TextEditingController();
    final label = TextEditingController();
    return showDialog<ToolSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.mcpAddTitle),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: command,
                decoration: InputDecoration(
                  labelText: l.mcpCommand,
                  hintText: l.mcpCommandHint,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: args,
                decoration: InputDecoration(
                  labelText: l.mcpArgs,
                  hintText: l.mcpArgsHint,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: label,
                decoration: InputDecoration(
                  labelText: l.nameOptional,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
          FilledButton(
            onPressed: () {
              if (command.text.trim().isEmpty) return;
              Navigator.pop(
                ctx,
                ToolSource(
                  kind: ToolSourceKind.mcp,
                  command: command.text.trim(),
                  args: args.text.trim().isEmpty
                      ? const []
                      : args.text.trim().split(RegExp(r'\s+')),
                  label: label.text.trim(),
                ),
              );
            },
            child: Text(l.add),
          ),
        ],
      ),
    );
  }

  /// 소스의 도구를 describe 해 생성된 function-calling JSON 을 보여준다.
  Future<void> _preview(BuildContext context, {ToolSource? source}) async {
    final l = AppLocalizations.of(context);
    // describe 도 런타임과 같은 실효 파이썬(venv 준비 시 venv)으로 실행한다.
    final interp = workspace.effectivePython;
    final dir = workspace.toolAdaptersDir;
    if (!workspace.pythonInstalled || interp == null || dir == null) {
      await _showText(context, l.toolInspect, l.pythonNotReadyInspect);
      return;
    }
    final runner = ToolRunner(interp);
    final ToolModule? module = source == null
        ? await runner.describe(workspace.baseToolModulePath!, isBase: true)
        : await runner.describeSource(source, dir);
    if (!context.mounted) return;
    if (module == null) {
      await _showText(context, l.toolInspect, l.toolInfoFailed);
      return;
    }
    const enc = JsonEncoder.withIndent('  ');
    final body = module.tools
        .map((t) => '• ${t.name}\n${enc.convert(t.raw)}')
        .join('\n\n');
    if (context.mounted) {
      await _showText(context, l.toolsCount(module.name, module.tools.length), body);
    }
  }

  Future<void> _showText(BuildContext context, String title, String body) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(body, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppLocalizations.of(ctx).close)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: workspace,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PythonStatusBar(workspace: workspace),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(l.toolsDescription, style: theme.textTheme.bodySmall),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _add(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(l.addTool),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: Text(l.baseModuleLabel),
                    subtitle: Text(workspace.baseToolModulePath ?? l.extractPending,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: TextButton(
                      onPressed: () => _preview(context),
                      child: Text(l.viewTools),
                    ),
                    dense: true,
                  ),
                  for (final s in workspace.toolSources)
                    ListTile(
                      leading: Icon(s.kind == ToolSourceKind.mcp
                          ? Icons.hub_outlined
                          : Icons.terminal),
                      title: Text(s.displayName),
                      subtitle: Text(
                        s.kind == ToolSourceKind.mcp
                            ? '${s.command} ${s.args.join(' ')}'
                            : s.script,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => _preview(context, source: s),
                            child: Text(l.viewTools),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: l.remove,
                            onPressed: () => workspace.removeToolSource(s),
                          ),
                        ],
                      ),
                      dense: true,
                    ),
                  const Divider(height: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.toolModelTitle,
                            style: theme.textTheme.titleSmall),
                        const SizedBox(height: 2),
                        Text(l.toolModelDesc, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  _toolModelTile(context, 'run_subagent', l.toolSubagentLabel),
                  _toolModelTile(context, 'verify_work', l.toolVerifyLabel),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 도구별 모델 프리셋 선택 타일('' = 기본 프리셋 사용).
  Widget _toolModelTile(BuildContext context, String tool, String title) {
    final l = AppLocalizations.of(context);
    final presets = workspace.llmPresets;
    final current = workspace.presetIdForTool(tool);
    final value = presets.any((p) => p.id == current) ? current : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          SizedBox(width: 140, child: Text(title)),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: value,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(value: '', child: Text(l.useDefaultModel)),
                for (final p in presets)
                  DropdownMenuItem(value: p.id, child: Text(p.label)),
              ],
              onChanged: (v) => workspace.setToolModel(tool, v ?? ''),
            ),
          ),
        ],
      ),
    );
  }
}

/// 도구 탭 상단: Python 환경 + 상태 확인(콘솔 점검) / Python 설정 버튼.
class _PythonStatusBar extends StatelessWidget {
  const _PythonStatusBar({required this.workspace});
  final WorkspaceController workspace;

  /// 상태 확인: 내장 점검 스크립트를 콘솔로 실행(실시간 출력 + 입력).
  Future<void> _check(BuildContext context) async {
    final l = AppLocalizations.of(context);
    // 실효 파이썬(venv 준비 시 venv) 으로 점검·설치해야 실제 도구와 같은 환경을 본다.
    // base 로 하면 Homebrew/시스템 파이썬의 PEP 668(externally-managed)로 pip 이 막힌다.
    final interp = workspace.effectivePython;
    final dir = workspace.toolAdaptersDir;
    if (interp == null || !workspace.pythonInstalled || dir == null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.pythonNotSetTitle),
          content: Text(l.pythonNotSetBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.close)),
          ],
        ),
      );
      return;
    }
    final lang = workspace.pythonLangFile;
    await showDialog<void>(
      context: context,
      builder: (_) => ConsoleDialog(
        interpreter: interp,
        scriptPath: p.join(dir, 'env_check.py'),
        title: l.pythonCheckTitle,
        environment: lang != null ? {'COLLABO_LANG': lang} : null,
      ),
    );
  }

  Future<void> _openSettings(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => _PythonSettingsDialog(workspace: workspace),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          const Icon(Icons.code, size: 18),
          const SizedBox(width: 6),
          Text(l.pythonEnv),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: () => _check(context),
            icon: const Icon(Icons.health_and_safety_outlined, size: 18),
            label: Text(l.statusCheck),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: () => _openSettings(context),
            icon: const Icon(Icons.settings, size: 18),
            label: Text(l.pythonSettings),
          ),
        ],
      ),
    );
  }
}

/// Python 설정: 사용자가 인터프리터를 직접 선택한다(자동 다운로드 없음).
///
/// 경로는 직접 입력(텍스트 필드)하거나 파일 선택으로 지정할 수 있고,
/// 입력을 멈춘 뒤 잠시 후 자동으로 검증되어 "확인됨" 표시가 갱신된다.
class _PythonSettingsDialog extends StatefulWidget {
  const _PythonSettingsDialog({required this.workspace});
  final WorkspaceController workspace;

  @override
  State<_PythonSettingsDialog> createState() => _PythonSettingsDialogState();
}

class _PythonSettingsDialogState extends State<_PythonSettingsDialog> {
  static final Uri _downloadUrl = Uri.parse('https://www.python.org/downloads/');

  /// 입력 후 자동 검증까지의 대기 시간.
  static const Duration _verifyDelay = Duration(milliseconds: 700);

  late final TextEditingController _controller;
  Timer? _debounce;

  WorkspaceController get _ws => widget.workspace;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _ws.pythonInterpreter ?? '');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 입력 중에는 디바운스로 기다렸다가, 멈추면 경로를 적용/저장한다.
  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_verifyDelay, () => _commit(value));
  }

  Future<void> _commit(String value) async {
    final path = value.trim();
    if (path == (_ws.pythonInterpreter ?? '')) return;
    await _ws.setPythonInterpreter(path);
  }

  /// venv 경로 + 준비 상태 + 재생성 버튼. 상태 변화 시 ListenableBuilder 로 갱신됨.
  Widget _venvStatusRow(AppLocalizations l, ThemeData theme) {
    final vp = _ws.venvPath;
    if (vp == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(l.venvNoProject, style: theme.textTheme.bodySmall),
      );
    }
    final status = _ws.venvStatus;
    final small = theme.textTheme.bodySmall;
    Widget indicator;
    switch (status) {
      case VenvStatus.creating:
        indicator = Row(children: [
          const SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Text(l.venvCreating, style: small),
        ]);
      case VenvStatus.ready:
        indicator = Row(children: [
          const Icon(Icons.check_circle, size: 16, color: Colors.green),
          const SizedBox(width: 6),
          Expanded(child: Text(l.venvReady, style: small)),
        ]);
      case VenvStatus.error:
        indicator = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error, size: 16, color: theme.colorScheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _ws.venvError.isEmpty ? l.venvFailed
                    : '${l.venvFailed}\n${_ws.venvError}',
                style: small?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ],
        );
      case VenvStatus.idle:
        indicator = Text(l.venvNotCreated, style: small);
    }
    final busy = status == VenvStatus.creating;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 2),
        Text(vp,
            style: small?.copyWith(fontFamily: 'monospace'),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        indicator,
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: busy ? null : () => _ws.recreateVenv(),
          icon: const Icon(Icons.refresh, size: 16),
          label: Text(status == VenvStatus.ready ? l.venvRecreate : l.venvCreate),
        ),
      ],
    );
  }

  Future<void> _pick(String allFilesLabel) async {
    final String? path;
    if (MacFilePicker.supported) {
      // macOS: venv 의 bin/python 심링크를 풀지 않고 고른 경로 그대로 받는다
      // (file_selector/기본 패널은 심링크를 base 로 해석해 venv 가 깨진다).
      path = await MacFilePicker.pickFile();
    } else {
      // Windows 는 python.exe, 그 외는 확장자 없는 실행 파일.
      final file = await openFile(acceptedTypeGroups: [
        const XTypeGroup(label: 'Python', extensions: ['exe']),
        XTypeGroup(label: allFilesLabel),
      ]);
      path = file?.path;
    }
    if (path == null) return;
    _debounce?.cancel();
    _controller.text = path;
    await _ws.setPythonInterpreter(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.pythonSettings),
      content: SizedBox(
        width: 480,
        child: ListenableBuilder(
          listenable: _ws,
          builder: (context, _) {
            final path = _ws.pythonInterpreter;
            final installed = _ws.pythonInstalled;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.selectPythonPrompt),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        onChanged: _onChanged,
                        style: const TextStyle(fontSize: 12),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: l.notSelected,
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _pick(l.allFiles),
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: Text(l.selectPython),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (path != null)
                  Row(
                    children: [
                      Icon(installed ? Icons.check_circle : Icons.error,
                          size: 16,
                          color: installed
                              ? Colors.green
                              : theme.colorScheme.error),
                      const SizedBox(width: 6),
                      Text(installed ? l.pythonVerified : l.pythonMissing),
                    ],
                  ),
                const Divider(height: 24),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(l.usePerProjectVenv),
                  subtitle: Text(l.usePerProjectVenvDesc,
                      style: theme.textTheme.bodySmall),
                  value: _ws.useVenv,
                  onChanged: (v) => _ws.setUseVenv(v),
                ),
                if (_ws.useVenv) _venvStatusRow(l, theme),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text(l.pythonMissingQuestion, style: theme.textTheme.bodySmall),
                    InkWell(
                      onTap: () => launchUrl(_downloadUrl,
                          mode: LaunchMode.externalApplication),
                      child: Text(
                        l.downloadFromPythonOrg,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            // 닫기 전에 디바운스 중인 입력을 즉시 반영한다.
            _debounce?.cancel();
            await _commit(_controller.text);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(l.close),
        ),
      ],
    );
  }
}

/// 모양 탭: 테마(라이트/다크/시스템). 기본 라이트.
class _AppearanceTab extends StatelessWidget {
  const _AppearanceTab({required this.workspace});
  final WorkspaceController workspace;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: workspace,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l.theme),
            RadioGroup<ThemeMode>(
              groupValue: workspace.themeMode,
              onChanged: (m) {
                if (m != null) workspace.setThemeMode(m);
              },
              child: Column(
                children: [
                  RadioListTile(value: ThemeMode.light, title: Text(l.themeLight)),
                  RadioListTile(value: ThemeMode.dark, title: Text(l.themeDark)),
                  RadioListTile(value: ThemeMode.system, title: Text(l.themeSystem)),
                ],
              ),
            ),
            const Divider(),
            const SizedBox(height: 8),
            Text(l.language),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: workspace.localeCode,
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              items: [
                DropdownMenuItem(value: 'system', child: Text(l.languageSystem)),
                const DropdownMenuItem(value: 'ko', child: Text('한국어')),
                const DropdownMenuItem(value: 'en', child: Text('English')),
              ],
              onChanged: (code) {
                if (code != null) workspace.setLocaleCode(code);
              },
            ),
          ],
        );
      },
    );
  }
}

/// 프리셋 프로필 아바타: 이름 첫 글자를 담은 원형(식별자 기반 안정 컬러).
class _PresetAvatar extends StatelessWidget {
  const _PresetAvatar({required this.seed, required this.label, this.size = 32});

  /// 색을 정하는 안정적 시드(프리셋 id). 비어 있으면 [label] 로 대체.
  final String seed;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final trimmed = label.trim();
    final letter = trimmed.isEmpty ? '?' : trimmed.substring(0, 1).toUpperCase();
    final color = _colorForSeed(seed.isEmpty ? trimmed : seed);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }

  /// 시드 문자열을 해시해 재시작에도 동일한 색을 만든다(최근 프로젝트 모노그램과 동일 방식).
  static Color _colorForSeed(String s) {
    var hash = 0;
    for (final code in s.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.55, 0.45).toColor();
  }
}
