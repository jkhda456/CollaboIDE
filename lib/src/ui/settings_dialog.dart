import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:afm_bridge/afm_bridge.dart' show AfmStatus;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../app/workspace_controller.dart';
import '../llm/apple_foundation_client.dart' show appleFoundationStatus, appleFoundationSupported;
import '../llm/context_fit.dart';
import '../llm/llm_config.dart';
import '../llm/llm_preset.dart';
import '../llm/openai_client.dart';
import '../llm/system_prompt.dart';
import '../platform/platform_features.dart';
import '../sandbox/project_sandbox.dart' show SandboxState, SandboxToolExecutor;
import '../tools/tool_executor.dart';
import '../tools/tool_module.dart';
import '../tools/tool_runner.dart';
import '../tools/tool_source.dart';
import '../viewers/viewer_assets.dart';
import '../viewers/viewer_rule.dart';
import '../viewers/viewer_source.dart';
import 'adaptive.dart';
import 'folder_picker_dialog.dart';

/// 설정 창을 띄운다(탭: 모델 / 프롬프트 / 도구 / 모양 / 정보).
/// [initialTab] 으로 처음 보일 탭을 고른다([settingsTabIndexFor] 참고).
Future<void> showSettingsDialog(
  BuildContext context,
  WorkspaceController workspace, {
  int initialTab = 0,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _SettingsDialog(workspace: workspace, initialTab: initialTab),
  );
}

/// 섹션 이름 → 설정 탭 인덱스. 웹(대화 헤더의 설정 안내 버튼)이 넘기는 이름을
/// 여기서 해석한다. 탭 순서가 바뀌면 [_SettingsDialog] 와 함께 이 표도 고칠 것.
int settingsTabIndexFor(String section) => switch (section) {
      'model' => 0,
      'prompt' => 1,
      'tools' => 2,
      'viewers' => 3,
      'web' => 4,
      'appearance' => 5,
      'about' => 6,
      _ => 0,
    };

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
  const _SettingsDialog({required this.workspace, this.initialTab = 0});

  final WorkspaceController workspace;

  /// 처음 보일 탭 인덱스(0=모델 … 6=정보). [_tabCount] 와 [settingsTabIndexFor] 참고.
  final int initialTab;

  /// 탭 개수. TabBar/TabBarView 항목 수와 반드시 같아야 한다.
  static const int _tabCount = 7;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // 휴대폰에서는 화면 전체를 쓴다(닫기 버튼을 머리에 단다 — 바깥을 누를 자리가 없다).
    final compact = isCompactScreen(context);
    return Dialog(
      insetPadding: compact ? EdgeInsets.zero : null,
      shape: compact ? const RoundedRectangleBorder() : null,
      child: ConstrainedBox(
        constraints: compact
            ? const BoxConstraints.expand()
            : const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: DefaultTabController(
          length: _tabCount,
          // 범위를 벗어난 값이 들어와도 첫 탭으로 (num 을 돌려주는 clamp 대신 명시적으로).
          initialIndex:
              (initialTab >= 0 && initialTab < _tabCount) ? initialTab : 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    Text(l.settingsTitle,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    if (compact) ...[
                      const Spacer(),
                      IconButton(
                        tooltip: l.close,
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ],
                ),
              ),
              TabBar(
                isScrollable: true,
                tabs: [
                  Tab(text: l.tabModel),
                  Tab(text: l.tabPrompt),
                  Tab(text: l.tabTools),
                  Tab(text: l.tabViewers),
                  Tab(text: l.tabWeb),
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
                    _ViewersTab(workspace: workspace),
                    _WebTab(workspace: workspace),
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
      'intl · package_info_plus · xterm.dart (MIT) · collaboCore · '
      'Bootstrap (MIT) · marked (MIT)';

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
  late final TextEditingController _firstTimeout; // 첫 응답(프리필) 대기 시간(초)
  late final TextEditingController _tokenBudget; // 응답 하나의 토큰 예산
  late final TextEditingController _speed; // 처리 속도(tok/s, 비우면 실측)

  late final TextEditingController _afmConcurrent; // Apple: 동시 요청 수(0=기본)
  late final TextEditingController _ctxWindow; // 컨텍스트 창(토큰, 빈칸=모름). Apple 은 기기에서 읽어 채운다
  bool _autoFit = true; // 작은 컨텍스트에 자동으로 맞추기
  AfmStatus? _afmStatus; // Apple: 기기 모델 상태(세대·변형·창 크기) — 연결 목록·모델 탭에 표시

  bool _testing = false;
  bool _showKey = false; // API 키 마스크 해제 여부
  bool _multimodal = false; // 멀티모달(이미지 입력) 지원
  bool _parseTextToolCalls = false; // 본문 텍스트 도구호출 파싱(openai 폴백)
  bool _afmPromptedTools = false; // Apple: 도구를 프롬프트로 주입
  bool _afmPermissive = true; // Apple: 느슨한 가드레일
  bool _afmPrewarm = true; // Apple: 미리 올리기
  bool _afmTrimHistory = true; // Apple: 컨텍스트 넘치면 앞 대화 자르기
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
    _firstTimeout = TextEditingController();
    _tokenBudget = TextEditingController();
    _speed = TextEditingController();
    _afmConcurrent = TextEditingController();
    _ctxWindow = TextEditingController();
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
    _afmPromptedTools = cfg.afmPromptedTools;
    _afmPermissive = cfg.afmPermissiveGuardrails;
    _afmPrewarm = cfg.afmPrewarm;
    _afmTrimHistory = cfg.afmTrimHistory;
    _afmConcurrent.text = cfg.afmMaxConcurrent > 0 ? '${cfg.afmMaxConcurrent}' : '';
    _ctxWindow.text = cfg.contextWindow > 0 ? '${cfg.contextWindow}' : '';
    _autoFit = cfg.autoFitContext;
    if (cfg.connection == LlmConnection.appleFoundation) unawaited(_detectAppleWindow());
    _reasoningEffort =
        _reasoningOptions.contains(cfg.reasoningEffort) ? cfg.reasoningEffort : '';
    _firstTimeout.text = cfg.firstResponseTimeoutSec.toString();
    _tokenBudget.text = cfg.responseTokenBudget.toString();
    // 미지정(0)이면 빈칸으로 둔다 — 0 을 보여 주면 "0 tok/s" 로 읽힌다.
    _speed.text = cfg.speedTps > 0 ? _trimNum(cfg.speedTps) : '';
    _result = null;
  }

  static String _trimNum(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  /// 입력창의 첫 응답 대기 시간(초). 입력 도중의 어중간한 상태를 저장이 망치지
  /// 않도록 관대하게 읽는다 — 비우면 기본값, 숫자가 아니면 **지금 저장된 값** 유지.
  /// 음수는 0(제한 없음)으로 본다.
  int get _firstTimeoutSec {
    final t = _firstTimeout.text.trim();
    if (t.isEmpty) return LlmConfig.defaultFirstResponseTimeoutSec;
    final n = int.tryParse(t);
    if (n == null) {
      return _selectedPreset?.config.firstResponseTimeoutSec ??
          LlmConfig.defaultFirstResponseTimeoutSec;
    }
    return n < 0 ? 0 : n;
  }

  /// 토큰 예산. 비우면 기본값, 숫자가 아니면 지금 저장된 값 유지(위와 같은 규칙).
  int get _tokenBudgetValue {
    final t = _tokenBudget.text.trim();
    if (t.isEmpty) return LlmConfig.defaultResponseTokenBudget;
    final n = int.tryParse(t.replaceAll(',', ''));
    if (n == null) {
      return _selectedPreset?.config.responseTokenBudget ??
          LlmConfig.defaultResponseTokenBudget;
    }
    return n < 0 ? 0 : n;
  }

  /// 사용자가 지정한 속도. **비우면 0(미지정)** — 앱이 실측해서 쓴다.
  double get _speedValue {
    final t = _speed.text.trim();
    if (t.isEmpty) return 0;
    final v = double.tryParse(t);
    if (v == null) return _selectedPreset?.config.speedTps ?? 0;
    return v > 0 ? v : 0;
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _firstTimeout.dispose();
    _tokenBudget.dispose();
    _speed.dispose();
    _afmConcurrent.dispose();
    _ctxWindow.dispose();
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
        firstResponseTimeoutSec: _firstTimeoutSec,
        responseTokenBudget: _tokenBudgetValue,
        speedTps: _speedValue,
        // 실측치는 앱이 관리한다 — 편집 폼이 덮지 않도록 그대로 가져간다.
        measuredTps: _selectedPreset?.config.measuredTps ?? 0,
        afmPromptedTools: _afmPromptedTools,
        afmPermissiveGuardrails: _afmPermissive,
        afmPrewarm: _afmPrewarm,
        afmMaxConcurrent: int.tryParse(_afmConcurrent.text.trim()) ?? 0,
        afmTrimHistory: _afmTrimHistory,
        contextWindow: int.tryParse(_ctxWindow.text.trim()) ?? 0,
        autoFitContext: _autoFit,
      );

  /// Apple 온디바이스: 기기 모델의 컨텍스트 창을 읽어 채운다(바뀌었을 때만 저장).
  Future<void> _detectAppleWindow() async {
    final status = await appleFoundationStatus();
    if (!mounted) return;
    if (status != null) setState(() => _afmStatus = status);
    final size = status?.contextSize;
    if (size == null || size <= 0) return;
    if (_connection != LlmConnection.appleFoundation || _ctxWindow.text == '$size') return;
    setState(() => _ctxWindow.text = '$size');
    await _persist();
  }

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
  /// 다이얼로그 컨트롤러는 [_RenamePresetDialog] 가 자체 소유/정리한다.
  /// (여기서 `await showDialog` 직후 컨트롤러를 dispose 하면, 닫히는 애니메이션
  ///  동안 TextField 가 이미 정리된 컨트롤러를 참조해 크래시가 났다.)
  Future<void> _renamePreset() async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => _RenamePresetDialog(initial: _name.text),
    );
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
    if (_connection == LlmConnection.appleFoundation) await _detectAppleWindow();
  }

  /// 컨텍스트 창 + 작은 창 자동 맞춤(`ContextFit`) + 더 큰 모델 권고.
  ///
  /// Apple 온디바이스는 창을 기기에서 읽어 보여 주기만 하고(편집 없음), 네트워크 연결은
  /// 사용자가 적는다(모르면 비움 = 맞추지 않음). 창이 16K 이하이고 자동 맞춤이 켜져 있으면
  /// 무엇이 어떻게 줄어드는지와, 쓸 수 있는 더 큰 프리셋을 함께 보여 준다.
  Widget _buildContextSection(AppLocalizations l, ThemeData theme) {
    final small = theme.textTheme.bodySmall;
    final cfg = _current;
    final fit = ContextFit.of(cfg);
    final isApple = _connection == LlmConnection.appleFoundation;
    final userPrompt = widget.workspace.systemPrompt.trim();
    final isDefaultPrompt = widget.workspace.usesDefaultPrompt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        if (isApple && _afmStatus?.modelLabel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                const Icon(Icons.memory, size: 18),
                const SizedBox(width: 6),
                Text('${l.afmModelVersion}: ', style: theme.textTheme.bodyMedium),
                Expanded(
                  child: Text(
                    [
                      _afmStatus!.modelLabel!,
                      if (_afmStatus!.modelName != null && _afmStatus!.modelName != _afmStatus!.modelLabel)
                        '(${_afmStatus!.modelName})',
                    ].join(' '),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        if (isApple)
          Row(
            children: [
              const Icon(Icons.data_usage, size: 18),
              const SizedBox(width: 6),
              Text('${l.contextWindowLabel}: ', style: theme.textTheme.bodyMedium),
              Expanded(
                child: Text(
                  cfg.contextWindow > 0 ? l.contextWindowDetected(cfg.contextWindow) : l.contextWindowAssumed,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          )
        else
          TextField(
            controller: _ctxWindow,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l.contextWindowLabel,
              helperText: l.contextWindowHelp,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              setState(() {});
              _persist();
            },
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(l.autoFitContext),
          subtitle: Text(l.autoFitContextDesc, style: small),
          value: _autoFit,
          onChanged: (v) {
            setState(() => _autoFit = v);
            _persist();
          },
        ),
        // 두 상자는 글자 길이가 아니라 설정 폭에 맞춘다(Column 은 자식을 내용 폭으로 그린다).
        if (fit.active) ...[
          SizedBox(
            width: double.infinity,
            child: Card(
              margin: const EdgeInsets.only(top: 4),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.fitBudget(fit.outputReserve, fit.inputBudget),
                        style: small),
                    const SizedBox(height: 6),
                    Text(isDefaultPrompt ? l.fitPromptCompact : l.fitPromptCustom, style: small),
                    if (!isDefaultPrompt && fit.promptTooLong(userPrompt))
                      Text(l.fitPromptTooLong, style: small?.copyWith(color: theme.colorScheme.error)),
                    const SizedBox(height: 4),
                    Text(l.fitTools, style: small),
                    const SizedBox(height: 4),
                    Text(l.fitDisabled, style: small),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: Card(
              margin: const EdgeInsets.only(top: 8),
              color: theme.colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.tips_and_updates_outlined,
                            size: 18, color: theme.colorScheme.onSecondaryContainer),
                        const SizedBox(width: 6),
                        Text(l.fitRecommendTitle,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(l.fitRecommendBody, style: small),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Apple Foundation Models 전용 설정.
  ///
  /// 주소·키·모델 이름이 없는 대신 **엔진 설정**이 있다(플러그인 `configure`):
  /// 가드레일·동시 요청 수·컨텍스트 자르기. 지시문은 프롬프트 설정(시스템 프롬프트)을 쓴다. 도구 호출은 기본이 네이티브이고,
  /// 모델이 무시하면 프롬프트 주입으로 바꾼다. 실제 사용 가능 여부는 아래 "연결 확인" 이
  /// 알려 준다(기기 지원·Apple Intelligence 켜짐·OS 버전).
  Widget _buildAppleSection(AppLocalizations l, ThemeData theme) {
    final small = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(Icons.memory, size: 18),
            const SizedBox(width: 6),
            Expanded(child: Text(l.appleFoundationDesc, style: small)),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(l.afmPermissive),
          subtitle: Text(l.afmPermissiveDesc, style: small),
          value: _afmPermissive,
          onChanged: (v) {
            setState(() => _afmPermissive = v);
            _persist();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(l.afmPromptedTools),
          subtitle: Text(l.afmPromptedToolsDesc, style: small),
          value: _afmPromptedTools,
          onChanged: (v) {
            setState(() => _afmPromptedTools = v);
            _persist();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(l.afmPrewarm),
          subtitle: Text(l.afmPrewarmDesc, style: small),
          value: _afmPrewarm,
          onChanged: (v) {
            setState(() => _afmPrewarm = v);
            _persist();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(l.afmTrimHistory),
          subtitle: Text(l.afmTrimHistoryDesc, style: small),
          value: _afmTrimHistory,
          onChanged: (v) {
            setState(() => _afmTrimHistory = v);
            _persist();
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _afmConcurrent,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: l.afmConcurrent,
            helperText: l.afmConcurrentDesc,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => _persist(),
        ),
      ],
    );
  }

  /// 프로필 아바타 + 팝업 메뉴(프리셋 선택/추가/이름변경/기본설정/삭제)를 한 곳에서.
  Widget _buildPresetSwitcher(
      BuildContext context, AppLocalizations l, ThemeData theme) {
    final presets = widget.workspace.llmPresets;
    final defaultId = widget.workspace.defaultPresetId;
    final current = _selectedPreset;
    final currentModel = current?.config.effectiveModel.trim() ?? '';
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
            // 좁은 화면에서 긴 항목 이름이 넘치지 않게 폭을 채우고 말줄임.
            isExpanded: true,
            initialValue: _connection,
            decoration: InputDecoration(
                labelText: l.connectionMethod, border: const OutlineInputBorder()),
            items: [
              DropdownMenuItem(
                  value: LlmConnection.openai, child: Text(l.openaiCompatible)),
              DropdownMenuItem(
                  value: LlmConnection.openaiPrompted,
                  child: Text(l.openaiPrompted)),
              // 기기 안에서 도는 모델 — mac/iOS 에서만 고를 수 있다.
              if (appleFoundationSupported)
                DropdownMenuItem(
                    value: LlmConnection.appleFoundation,
                    // 기기 모델 세대·변형을 함께 보여 준다(예: "… · AFM 2", 27 은 "… · AFM 3 Core Advanced").
                    child: Text(_afmStatus?.modelLabel == null
                        ? l.appleFoundation
                        : '${l.appleFoundation} · ${_afmStatus!.modelLabel}')),
            ],
            onChanged: (v) {
              setState(() => _connection = v ?? _connection);
              _persist();
              if (_connection == LlmConnection.appleFoundation) unawaited(_detectAppleWindow());
            },
          ),
          // 기기 안의 모델에는 주소도 키도 모델 이름도 없다 — 그 줄들을 아예 감춘다.
          if (connectionUsesNetwork(_connection)) ...[
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
          ] else
            _buildAppleSection(l, theme),
          _buildContextSection(l, theme),
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
          // ── 시간 상한 ──────────────────────────────────────────────
          // 응답 상한은 시계가 아니라 **토큰 예산 ÷ 처리 속도**로 정해진다.
          // 느린 모델일수록 자동으로 더 오래 기다려 준다(§stream_budget.dart).
          TextField(
            controller: _tokenBudget,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l.responseTokenBudget,
              helperText: l.responseTokenBudgetDesc,
              helperMaxLines: 4,
              suffixText: l.tokensUnit,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => _persist(),
          ),
          const SizedBox(height: 12),
          // 속도: 비워 두면 앱이 실제 응답에서 재서 채운다.
          ListenableBuilder(
            listenable: widget.workspace,
            builder: (context, _) {
              final measured = _selectedPreset?.config.measuredTps ?? 0;
              final limit = widget.workspace.streamingLimitFor(_selectedId);
              final derived = limit == null
                  ? l.noLimit
                  : '${limit.inSeconds}${l.secondsUnit}';
              return TextField(
                controller: _speed,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l.tokPerSec,
                  hintText: measured > 0
                      ? l.tokPerSecMeasured(_trimNum(measured))
                      : l.tokPerSecAuto,
                  helperText: '${l.tokPerSecDesc}  →  $derived',
                  helperMaxLines: 4,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => _persist(),
              );
            },
          ),
          const SizedBox(height: 12),
          // 프리필은 별개다 — 그 구간에는 아무것도 안 오므로 속도로 잴 수 없다.
          TextField(
            controller: _firstTimeout,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l.firstResponseTimeout,
              helperText: l.firstResponseTimeoutDesc,
              helperMaxLines: 4,
              suffixText: l.secondsUnit,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => _persist(),
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
          ListenableBuilder(
            listenable: widget.workspace,
            builder: (context, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l.useProjectState),
              subtitle:
                  Text(l.useProjectStateDesc, style: theme.textTheme.bodySmall),
              value: widget.workspace.projectState,
              onChanged: widget.workspace.setProjectState,
            ),
          ),
          ListenableBuilder(
            listenable: widget.workspace,
            builder: (context, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l.usePlanMemory),
              subtitle:
                  Text(l.usePlanMemoryDesc, style: theme.textTheme.bodySmall),
              value: widget.workspace.planMemory,
              onChanged: widget.workspace.setPlanMemory,
            ),
          ),
          ListenableBuilder(
            listenable: widget.workspace,
            builder: (context, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l.useSupervisor),
              subtitle:
                  Text(l.useSupervisorDesc, style: theme.textTheme.bodySmall),
              value: widget.workspace.supervisor,
              onChanged: widget.workspace.setSupervisor,
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

/// 읽기 전용 텍스트(도구 JSON, 뷰어 소스 등)를 스크롤 가능한 다이얼로그로 보여 준다.
Future<void> _showTextDialog(BuildContext context, String title, String body) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: SelectableText(body,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
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

/// 웹 검색 탭 — 검색엔진과 브라우저 User-Agent.
///
/// 처음에는 도구 탭 안에 끼워 넣었는데 도구 목록을 밀어내며 자리를 너무 잡았다
/// (2026-09-13). 웹 검색이 좌측 메뉴의 독립 화면이 된 뒤로는 설정도 자기 탭을
/// 갖는 편이 맞다.
///
/// **엔진 목록을 여기서 고정하지 않는다.** 드롭다운에는 기본 둘만 올리고, 사용자가
/// `web_engines/` 에 넣은 엔진 이름이 저장돼 있으면 그것도 항목으로 살려 둔다.
/// 유효성 판정은 파이썬이 한다(모르는 이름이면 기본값으로 되돌린다).
class _WebTab extends StatelessWidget {
  const _WebTab({required this.workspace});

  final WorkspaceController workspace;

  /// 드롭다운에 올리는 **기본 제공** 엔진. `collabo_web.py` 의 ENGINES 와 같은
  /// 이름이어야 한다(노트 §13 "두 곳을 같이 고쳐야 하는 지점" 에 등록).
  static const List<String> _builtIn = ['google', 'duckduckgo'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: workspace,
      builder: (context, _) {
        final current = workspace.searchEngine;
        final items = [
          ..._builtIn,
          if (!_builtIn.contains(current)) current,
        ];
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          children: [
            Text(l.searchEngine, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            SizedBox(
              width: 240,
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: current,
                isDense: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                items: [
                  for (final e in items)
                    DropdownMenuItem(value: e, child: Text(e)),
                ],
                onChanged: (v) {
                  if (v != null) workspace.setSearchEngine(v);
                },
              ),
            ),
            const SizedBox(height: 6),
            Text(l.searchEngineDesc, style: theme.textTheme.bodySmall),
            const SizedBox(height: 24),
            Text(l.browserUserAgent, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            _UserAgentField(workspace: workspace),
            const SizedBox(height: 6),
            Text(l.browserUserAgentDesc, style: theme.textTheme.bodySmall),
          ],
        );
      },
    );
  }
}

/// User-Agent 입력칸. 포커스를 잃을 때 저장한다(글자마다 DB 를 쓰지 않는다).
class _UserAgentField extends StatefulWidget {
  const _UserAgentField({required this.workspace});

  final WorkspaceController workspace;

  @override
  State<_UserAgentField> createState() => _UserAgentFieldState();
}

class _UserAgentFieldState extends State<_UserAgentField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.workspace.browserUserAgent);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.workspace.setBrowserUserAgent(_ctrl.text);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return TextField(
      controller: _ctrl,
      focusNode: _focus,
      style: Theme.of(context).textTheme.bodySmall,
      onSubmitted: widget.workspace.setBrowserUserAgent,
      decoration: InputDecoration(
        hintText: l.browserUserAgentHint,
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
    );
  }
}

/// 도구 탭: function calling 으로 확장되는 도구 목록.
///
/// **목록 하나에 전부 담는다** — 네이티브 위임 도구(모델 선택), 기본 모듈,
/// 사용자가 추가한 CLI/MCP 소스. 예전에는 모듈 목록 아래에 도구별 모델 목록이
/// 따로 있었는데, 그 드롭다운은 사실 위임·검증 **두 도구의 옵션**이라 그 줄에
/// 붙는 편이 맞다.
///
/// 도구는 개별로 끌 수 있다(체크박스). 끄면 소스는 그대로 두고 레지스트리가
/// 등록에서 뺀다 — 모델에게 목록으로도 가지 않는다([WorkspaceController.disabledTools]).
class _ToolsTab extends StatefulWidget {
  const _ToolsTab({required this.workspace});
  final WorkspaceController workspace;

  @override
  State<_ToolsTab> createState() => _ToolsTabState();
}

class _ToolsTabState extends State<_ToolsTab> {
  WorkspaceController get workspace => widget.workspace;

  /// 소스 id → describe 결과(null 이면 실패). 개별 도구를 줄로 그리려면
  /// 이름을 알아야 하므로 탭을 열 때 한 번 모아 온다.
  Map<String, ToolModule?> _modules = const {};

  /// 마지막으로 describe 를 돈 구성의 지문. 컨트롤러 알림은 프로세스가 돌 때마다
  /// 자주 오므로, 구성이 실제로 바뀌었을 때만 다시 돈다(§되풀이되는 규칙).
  String _signature = '';
  bool _loading = false;

  /// 펼쳐 둔 모듈(소스 id).
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    workspace.addListener(_onWorkspaceChanged);
    _loadModules();
  }

  @override
  void dispose() {
    workspace.removeListener(_onWorkspaceChanged);
    // 시스템 머신은 앱에 하나 고정이라 여기서 내리지 않는다(샌드박스 화면에서 끌 수 있다).
    super.dispose();
  }

  void _onWorkspaceChanged() => _loadModules();

  String _configSignature() => [
        workspace.projectPath ?? '',
        ...workspace.baseToolModulePaths,
        ...workspace.toolSources.map((s) => s.id),
      ].join('|');

  /// 기본 모듈 + 사용자 소스를 describe 해 도구 이름 목록을 채운다.
  Future<void> _loadModules() async {
    final sig = _configSignature();
    if (sig == _signature) return;
    _signature = sig;

    // 실제 도구를 돌리는 **같은 실행기**로 물어야 목록이 실제와 같다 — **시스템 머신**
    // (앱에 하나 고정)에게 묻는다. 프로젝트 머신은 그 프로젝트의 작업에만 쓴다(예전에는
    // 설정을 여는 것만으로 활성 프로젝트의 머신이 임의로 켜졌다).
    final dir = workspace.toolAdaptersDir;
    final box = workspace.systemSandbox();
    final ToolExecutor? executor = box == null ? null : SandboxToolExecutor(box);
    if (executor == null || dir == null) {
      if (mounted) {
        setState(() {
          _modules = const {};
          _loading = false; // 읽던 도중 인터프리터가 풀렸을 수 있다
        });
      }
      return;
    }
    setState(() => _loading = true);

    final runner = ToolRunner.withExecutor(executor, baseEnv: workspace.toolEnv);
    final out = <String, ToolModule?>{};
    for (final script in workspace.baseToolModulePaths) {
      out[baseSourceId(script)] = await runner.describe(script,
          isBase: true, workingDirectory: workspace.projectPath);
    }
    for (final s in workspace.toolSources) {
      out[s.id] = await runner.describeSource(s, dir,
          workingDirectory: workspace.projectPath);
    }
    // 늦게 도착한 결과는 버린다 — 도중에 소스가 바뀌었으면 다음 호출이 채운다.
    if (!mounted || sig != _signature) return;
    setState(() {
      _modules = out;
      _loading = false;
    });
  }

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

  /// 그 모듈의 도구가 만들어 내는 function-calling JSON 을 보여준다.
  /// 목록을 그릴 때 이미 describe 했으므로 캐시를 그대로 쓴다(재실행 없음).
  Future<void> _preview(BuildContext context, String sourceId) async {
    final l = AppLocalizations.of(context);
    final module = _modules[sourceId];
    if (module == null) {
      await _showTextDialog(
        context,
        l.toolInspect,
        _modules.containsKey(sourceId) ? l.toolInfoFailed : l.sandboxNotReadyInspect,
      );
      return;
    }
    const enc = JsonEncoder.withIndent('  ');
    final body = module.tools
        .map((t) => '• ${t.name}\n${enc.convert(t.raw)}')
        .join('\n\n');
    if (context.mounted) {
      await _showTextDialog(
          context, l.toolsCount(module.name, module.tools.length), body);
    }
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
            // 평소엔 아무것도 그리지 않는다(문제가 있을 때만) — 그만큼 목록이 위로 온다.
            _RuntimeBar(workspace: workspace),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(l.toolsDescription,
                            style: theme.textTheme.bodySmall),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: () => _add(context),
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(l.addTool),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(l.toolToggleDesc, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            Expanded(
              // **목록은 하나다.** 소제목도 구분선도 두지 않는다 — 줄의 종류는
              // 체크박스 자리에 무엇이 오는가로 구분한다(체크박스 / 아이콘).
              child: ListView(
                children: [
                  // 네이티브 위임 도구: 파이썬이 아니라 앱이 직접 실행한다.
                  // 끌 수 없고(오케스트레이션의 뼈대) 대신 모델을 고른다.
                  _nativeToolTile(context, 'run_subagent', l.toolSubagentLabel),
                  _nativeToolTile(context, 'verify_work', l.toolVerifyLabel),
                  // 이어서 파이썬 도구 모듈 — 기본(고정) + 사용자가 추가한 소스.
                  if (_loading)
                    ListTile(
                      leading: const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      title: Text(l.toolListLoading),
                      dense: true,
                    ),
                  if (workspace.baseToolModulePaths.isEmpty)
                    ListTile(
                      leading: const Icon(Icons.lock_outline),
                      title: Text(l.extractPending),
                      dense: true,
                    ),
                  for (final script in workspace.baseToolModulePaths)
                    ..._moduleRows(
                      context,
                      sourceId: baseSourceId(script),
                      icon: Icons.lock_outline,
                      title: '${p.basename(script)}  (${l.defaultBadge})',
                      path: script,
                    ),
                  for (final s in workspace.toolSources)
                    ..._moduleRows(
                      context,
                      sourceId: s.id,
                      icon: s.kind == ToolSourceKind.mcp
                          ? Icons.hub_outlined
                          : Icons.terminal,
                      title: s.displayName,
                      path: s.kind == ToolSourceKind.mcp
                          ? '${s.command} ${s.args.join(' ')}'
                          : s.script,
                      onRemove: () => workspace.removeToolSource(s),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // 한 목록으로 보이려면 **모든 줄의 좌우 자리가 같은 폭**이어야 한다. 체크박스와
  // 아이콘은 자연 크기가 달라(40 vs 24) 그대로 두면 제목·설명의 들여쓰기가 줄마다
  // 어긋난다. 삭제 버튼도 있는 줄과 없는 줄이 갈린다 → 양쪽 다 고정 폭 자리에 담는다.
  static const double _leadWidth = 40; // ListTile 의 minLeadingWidth 와 같은 값
  static const double _iconSlot = 48; // IconButton 하나 자리(비어도 폭을 유지)
  static const double _trailWidth = 248; // 드롭다운 200 + 삭제 자리 48

  /// 줄 맨 앞 자리(체크박스 또는 아이콘) — 무엇이 들어와도 폭과 중심이 같다.
  Widget _leadSlot(Widget child) => SizedBox(
        width: _leadWidth,
        height: _leadWidth,
        child: Center(child: child),
      );

  /// 네이티브 위임 도구 한 줄: 체크박스 자리에 아이콘(끌 수 없다는 표시)이 오고,
  /// 오른쪽에는 모델 프리셋 드롭다운이 온다('' = 기본 프리셋).
  Widget _nativeToolTile(BuildContext context, String tool, String title) {
    final l = AppLocalizations.of(context);
    final presets = workspace.llmPresets;
    final current = workspace.presetIdForTool(tool);
    final value = presets.any((p) => p.id == current) ? current : '';
    return ListTile(
      leading: _leadSlot(const Icon(Icons.alt_route)),
      title: Text(title),
      subtitle: Text(l.toolNativeFixed),
      trailing: SizedBox(
        width: _trailWidth,
        child: Row(
          children: [
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
            // 모듈 줄의 삭제 버튼 자리 — 비워 두어야 오른쪽 끝이 맞는다.
            const SizedBox(width: _iconSlot),
          ],
        ),
      ),
      dense: true,
    );
  }

  /// 모듈 한 줄 + (펼쳤으면) 그 모듈의 도구 줄들.
  ///
  /// 모듈 줄의 체크박스는 **세 갈래**다 — 전부 켜짐/전부 꺼짐/일부. 누르면
  /// 그 모듈 도구 전체를 한 번에 켜거나 끈다.
  List<Widget> _moduleRows(
    BuildContext context, {
    required String sourceId,
    required IconData icon,
    required String title,
    required String path,
    VoidCallback? onRemove,
  }) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final module = _modules[sourceId];
    final tools = module?.tools ?? const <ToolDef>[];
    final on = tools.where((t) => workspace.isToolEnabled(sourceId, t.name)).length;
    final expanded = _expanded.contains(sourceId);
    // describe 가 실패했거나 아직 안 왔으면 개수를 모른다 → 체크박스를 안 준다.
    final known = module != null && tools.isNotEmpty;

    return [
      ListTile(
        leading: _leadSlot(
          known
              ? Checkbox(
                  tristate: true,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  value: on == tools.length
                      ? true
                      : on == 0
                          ? false
                          : null,
                  onChanged: (_) => workspace.setToolsEnabled(
                      sourceId, tools.map((t) => t.name), on != tools.length),
                )
              : Icon(icon),
        ),
        title: Text(known ? '$title  ($on/${tools.length})' : title),
        subtitle: Text(
          module == null && _modules.containsKey(sourceId)
              ? l.toolInfoFailed
              : path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: known
            ? () => setState(() =>
                expanded ? _expanded.remove(sourceId) : _expanded.add(sourceId))
            : null,
        trailing: SizedBox(
          width: _trailWidth,
          child: Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (known)
                      Icon(expanded ? Icons.expand_less : Icons.expand_more,
                          size: 20),
                    TextButton(
                      onPressed: () => _preview(context, sourceId),
                      child: Text(l.viewTools),
                    ),
                  ],
                ),
              ),
              // 지울 수 없는 기본 모듈도 같은 폭을 차지해야 줄이 맞는다.
              SizedBox(
                width: _iconSlot,
                child: onRemove == null
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: l.remove,
                        onPressed: onRemove,
                      ),
              ),
            ],
          ),
        ),
        dense: true,
      ),
      // 하위 도구 줄: 모듈 줄과 같은 자리 구조에 한 칸(_leadWidth)만 더 들여쓴다.
      if (expanded)
        for (final t in tools)
          ListTile(
            contentPadding: const EdgeInsets.only(left: 16 + _leadWidth, right: 16),
            leading: _leadSlot(Checkbox(
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              value: workspace.isToolEnabled(sourceId, t.name),
              onChanged: (v) =>
                  workspace.setToolsEnabled(sourceId, [t.name], v ?? false),
            )),
            title: Text(t.name, style: theme.textTheme.bodyMedium),
            subtitle: t.description.isEmpty
                ? null
                : Text(t.description,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => workspace.setToolsEnabled(
                sourceId, [t.name], !workspace.isToolEnabled(sourceId, t.name)),
            dense: true,
          ),
    ];
  }
}

/// 뷰어 탭: 우측 하단 파일 뷰어를 JS 플러그인으로 확장하고, 각 뷰어가 담당할
/// 확장자를 정한다.
///
/// 뷰어의 **정체와 기본값은 웹(레지스트리)에 있다** — 그래서 목록은 웹이 보고한
/// [WorkspaceController.registeredViewers] 를 쓰고, 사용자가 덮어쓴 값만
/// (`ViewerRule`) 메인 DB 에 저장한다. 번들 뷰어도 끌 수 있다.
class _ViewersTab extends StatelessWidget {
  const _ViewersTab({required this.workspace});
  final WorkspaceController workspace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: workspace,
      builder: (context, _) {
        final sources = workspace.viewerSources;
        // 표시 순서 = 실제 선택 순서. 끌어서 바꾼다.
        final viewers = workspace.orderedViewers;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(l.viewersDesc, style: theme.textTheme.bodySmall),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _addViewer(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(l.addViewer),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 스크롤 영역 전체를 ReorderableListView 하나로 둔다 —
            // ListView 안에 또 스크롤 목록을 넣으면 드래그가 꼬인다.
            Expanded(
              child: ReorderableListView(
                // 행에 입력창이 있어 아무 데나 눌러 끌면 텍스트 선택과 충돌한다.
                // 전용 손잡이로만 끌게 한다.
                buildDefaultDragHandles: false,
                onReorder: (oldIndex, newIndex) =>
                    _reorder(viewers, oldIndex, newIndex),
                header: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _rulesHeader(context),
                    // 목록은 웹이 보고한다. 웹뷰는 프로젝트가 열려 있을 때만 있으므로
                    // (AppLayout), 캐시도 없는 첫 실행에서는 그 사실을 알려 준다.
                    if (viewers.isEmpty)
                      _hint(
                          context,
                          workspace.hasProject
                              ? l.viewersWaiting
                              : l.viewersNeedProject),
                  ],
                ),
                footer: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Divider(height: 16),
                    _sectionHeader(context, l.viewerUserFilesTitle, null),
                    if (sources.isEmpty) _hint(context, l.viewersEmpty),
                    for (final v in sources) _viewerTile(context, v),
                    // 앱에 담긴 예제(마크다운 편집기 등) — 아직 안 얹었으면 권한다.
                    for (final e in workspace.availableViewerExamples)
                      _exampleTile(context, e),
                  ],
                ),
                children: [
                  for (var i = 0; i < viewers.length; i++)
                    _ViewerRuleTile(
                      key: ValueKey(viewers[i].id),
                      workspace: workspace,
                      info: viewers[i],
                      index: i,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  void _reorder(List<ViewerInfo> viewers, int oldIndex, int newIndex) {
    final ids = [for (final v in viewers) v.id];
    // ReorderableListView 는 "빼기 전" 기준 위치를 준다.
    if (newIndex > oldIndex) newIndex -= 1;
    ids.insert(newIndex, ids.removeAt(oldIndex));
    workspace.setViewerOrder(ids);
  }

  /// 확장자 연결 섹션 머리말 + (순서를 바꿨을 때만) 순서 초기화.
  Widget _rulesHeader(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.viewerRulesTitle, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(l.viewerRulesDesc, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (workspace.viewerOrder.isNotEmpty)
            TextButton(
              onPressed: workspace.resetViewerOrder,
              child: Text(l.viewerOrderReset),
            ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title, String? desc) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          if (desc != null) ...[
            const SizedBox(height: 2),
            Text(desc, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _hint(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(text,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }

  /// 앱에 담긴 예제 뷰어 한 줄. 추가하면 사용자 뷰어와 똑같이 취급된다.
  Widget _exampleTile(BuildContext context, ViewerExample e) {
    final l = AppLocalizations.of(context);
    return ListTile(
      leading: const Icon(Icons.auto_awesome_outlined),
      title: Text(e.fileName),
      subtitle: Text(l.viewerExampleDesc,
          maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: OutlinedButton(
        onPressed: () => workspace.addViewerExample(e),
        child: Text(l.add),
      ),
      dense: true,
    );
  }

  Widget _viewerTile(BuildContext context, ViewerSource v) {
    final l = AppLocalizations.of(context);
    // 원본이 이동·삭제되면 조용히 로드되지 않으므로 경고를 보여 준다.
    // (설정 창의 몇 줄짜리 목록이라 동기 확인으로 충분하다.)
    // 폴더 뷰어도 있으므로 파일/폴더 둘 다 없을 때만 경고다.
    final isDir = Directory(v.path).existsSync();
    final missing = !isDir && !File(v.path).existsSync();
    return ListTile(
      leading: Icon(missing
          ? Icons.warning_amber
          : (isDir ? Icons.folder_zip_outlined : Icons.extension_outlined)),
      title: Text(v.displayName),
      subtitle: Text(
        missing ? '${l.viewerFileMissing} — ${v.path}' : v.path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => _showViewerSource(context, v),
            child: Text(l.viewSource),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l.remove,
            onPressed: () => workspace.removeViewerSource(v),
          ),
        ],
      ),
      dense: true,
    );
  }

  /// 뷰어 추가: 파일 하나(.js) 또는 **폴더**(여러 파일 + `viewer.json`, WASM 포함).
  Future<void> _addViewer(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final folder = await showDialog<bool>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l.addViewer),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, false),
            child: ListTile(
              leading: const Icon(Icons.javascript),
              title: Text(l.addViewerFile),
              subtitle: Text(l.addViewerFileDesc),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, true),
            child: ListTile(
              leading: const Icon(Icons.folder_zip_outlined),
              title: Text(l.addViewerFolder),
              subtitle: Text(l.addViewerFolderDesc),
            ),
          ),
        ],
      ),
    );
    if (folder == null || !context.mounted) return;

    String? path;
    if (folder) {
      path = await pickDirectory(context, confirmButtonText: l.selectButton);
    } else {
      const typeGroup = XTypeGroup(label: 'JavaScript', extensions: ['js']);
      path = (await openFile(acceptedTypeGroups: [typeGroup]))?.path;
    }
    if (path == null) return;
    await workspace.addViewerSource(ViewerSource(path: path));
  }

  /// 추가한 JS 를 그대로 보여 준다(무엇을 얹었는지 확인용).
  /// 폴더 뷰어면 매니페스트(`viewer.json`)를 보여 준다 — 그게 무엇이 로드되는지다.
  Future<void> _showViewerSource(BuildContext context, ViewerSource v) async {
    final l = AppLocalizations.of(context);
    String body;
    try {
      final target = Directory(v.path).existsSync()
          ? File(p.join(v.path, ViewerAssets.manifestName))
          : File(v.path);
      body = await target.readAsString();
      // 다이얼로그가 감당할 만큼만. 확인용이지 편집기가 아니다.
      if (body.length > 20000) body = '${body.substring(0, 20000)}\n…';
    } catch (e) {
      body = '${l.viewerReadFailed}\n$e';
    }
    if (context.mounted) await _showTextDialog(context, v.displayName, body);
  }
}

/// 뷰어 한 줄: 사용 여부 + 담당 확장자.
///
/// 확장자 입력은 자유 텍스트라 **입력 중에는 저장하지 않는다** — 매 글자마다
/// 저장하면 웹으로 규칙이 다시 밀려 뷰어가 재선택된다. 포커스가 빠지거나
/// Enter 를 칠 때 커밋한다.
class _ViewerRuleTile extends StatefulWidget {
  const _ViewerRuleTile({
    super.key,
    required this.workspace,
    required this.info,
    required this.index,
  });

  final WorkspaceController workspace;
  final ViewerInfo info;

  /// 목록에서의 위치(드래그 손잡이가 필요로 한다).
  final int index;

  @override
  State<_ViewerRuleTile> createState() => _ViewerRuleTileState();
}

class _ViewerRuleTileState extends State<_ViewerRuleTile> {
  late final TextEditingController _ext;
  late final FocusNode _focus;

  ViewerRule get _rule => widget.workspace.viewerRuleFor(widget.info.id);

  @override
  void initState() {
    super.initState();
    _ext = TextEditingController(
        text: ViewerRule.formatExtensions(
            widget.workspace.effectiveExtensionsFor(widget.info)));
    _focus = FocusNode();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _ext.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final parsed = ViewerRule.parseExtensions(_ext.text);
    // 보기 좋게 정규화된 형태로 되돌려 준다(`MD` → `.md`).
    final text = ViewerRule.formatExtensions(parsed);
    if (_ext.text != text) _ext.text = text;
    // 선언값과 같아지면 override 를 지운다(플러그인이 기본값을 바꾸면 따라가도록).
    final sameAsDefault =
        parsed.join(',') == widget.info.defaultExtensions.join(',');
    widget.workspace.setViewerRule(
      widget.info.id,
      sameAsDefault
          ? _rule.copyWith(clearExtensions: true)
          : _rule.copyWith(extensions: parsed),
    );
  }

  void _reset() {
    widget.workspace.resetViewerRule(widget.info.id);
    _ext.text = ViewerRule.formatExtensions(widget.info.defaultExtensions);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final rule = _rule;
    // 입력창 값은 여기서 컨트롤러와 다시 맞추지 않는다 — build 중에
    // TextEditingController.text 를 건드리면 TextField 가 build 중에 setState 를
    // 부르게 된다. 값을 바꾸는 경로는 커밋(_commit)과 되돌리기(_reset) 둘뿐이고,
    // 둘 다 자기가 입력창을 갱신한다.
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 같은 확장자를 여러 뷰어가 담당할 때는 위에 있는 쪽이 이긴다 → 순서 변경.
          ReorderableDragStartListener(
            index: widget.index,
            child: Tooltip(
              message: l.viewerReorderTooltip,
              child: Icon(Icons.drag_indicator,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Checkbox(
            value: rule.enabled,
            onChanged: (v) => widget.workspace
                .setViewerRule(widget.info.id, rule.copyWith(enabled: v ?? true)),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.info.label,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  '${widget.info.dataMode} · '
                  '${widget.info.user ? l.viewerUserBadge : l.viewerBuiltinBadge}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: TextField(
              controller: _ext,
              focusNode: _focus,
              enabled: rule.enabled,
              style: theme.textTheme.bodySmall,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: '.md, .txt',
              ),
              onSubmitted: (_) => _commit(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt, size: 18),
            tooltip: l.resetDefault,
            onPressed: rule.isDefault ? null : _reset,
          ),
        ],
      ),
    );
  }
}

/// 도구 탭 상단: **평소에는 아무것도 그리지 않는다.**
///
/// 고를 것이 없다 — 도구는 언제나 collaboCore 샌드박스(게스트 CPython)에서 돈다(2026-09-23).
/// "샌드박스에서 돕니다" 를 늘 띄워 둘 이유가 없어서, **그렇지 않을 때만** 말한다:
///  - 이 플랫폼용 런타임이 앱에 없다 → 도구를 아예 쓸 수 없다.
///  - 시스템 머신이 부팅에 실패했다 → 이 화면의 도구 목록도 그 머신이 답하므로 여기서 알린다.
///
/// 머신의 평상시 상태(멈춤·시작 중·실행 중)는 샌드박스 화면에서 본다.
class _RuntimeBar extends StatelessWidget {
  const _RuntimeBar({required this.workspace});
  final WorkspaceController workspace;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final box = workspace.systemSandboxOrNull;
    final String status;
    if (!workspace.sandboxAvailable) {
      status = PlatformFeatures.isIOS ? l.sandboxUnavailableIOS : l.sandboxUnavailable;
    } else if (box?.state == SandboxState.failed) {
      status = l.sandboxFailed(box?.error ?? '');
    } else {
      return const SizedBox.shrink(); // 잘 도는 중 — 자리를 차지하지 않는다
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              status,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
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
              isExpanded: true,
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

/// 프리셋 이름 변경 다이얼로그. 텍스트 컨트롤러를 **자체 State 가 소유**하고
/// dispose 에서 정리하므로, 라우트가 완전히 사라진 뒤 안전하게 해제된다.
/// (호출부에서 `await showDialog` 직후 컨트롤러를 dispose 하면, 닫히는 애니메이션
///  동안 TextField 가 정리된 컨트롤러를 참조해 "used after being disposed" 크래시.)
class _RenamePresetDialog extends StatefulWidget {
  const _RenamePresetDialog({required this.initial});

  final String initial;

  @override
  State<_RenamePresetDialog> createState() => _RenamePresetDialogState();
}

class _RenamePresetDialogState extends State<_RenamePresetDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.renamePreset),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: InputDecoration(
          labelText: l.presetNameLabel,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(context, _ctrl.text),
            child: Text(l.save)),
      ],
    );
  }
}
