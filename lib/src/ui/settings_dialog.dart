import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../app/workspace_controller.dart';
import '../llm/llm_config.dart';
import '../llm/openai_client.dart';
import '../llm/system_prompt.dart';
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
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 540),
        child: DefaultTabController(
          length: 4,
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
                ],
              ),
              Flexible(
                child: TabBarView(
                  children: [
                    _ModelTab(workspace: workspace),
                    _PromptTab(workspace: workspace),
                    _ToolsTab(workspace: workspace),
                    _AppearanceTab(workspace: workspace),
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

/// 모델 탭: 연결방식 / URL / KEY / 모델 + 연결 상태 확인.
class _ModelTab extends StatefulWidget {
  const _ModelTab({super.key, required this.workspace});
  final WorkspaceController workspace;

  @override
  State<_ModelTab> createState() => _ModelTabState();
}

class _ModelTabState extends State<_ModelTab> {
  late LlmConnection _connection;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  final OpenAiClient _client = OpenAiClient();

  bool _testing = false;
  LlmTestResult? _result;

  @override
  void initState() {
    super.initState();
    final cfg = widget.workspace.llmConfig;
    _connection = cfg.connection;
    _baseUrl = TextEditingController(text: cfg.baseUrl);
    _apiKey = TextEditingController(text: cfg.apiKey);
    _model = TextEditingController(text: cfg.model);
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _client.dispose();
    super.dispose();
  }

  LlmConfig get _current => LlmConfig(
        connection: _connection,
        baseUrl: _baseUrl.text.trim(),
        apiKey: _apiKey.text.trim(),
        model: _model.text.trim(),
      );

  /// 변경 즉시 자동 저장한다(별도 저장 버튼 없이 입력에 따라 적용).
  Future<void> _persist() => widget.workspace.setLlmConfig(_current);

  /// 초기 설정 마법사에서 "다음" 시 마지막 입력까지 확실히 저장하기 위한 flush.
  Future<void> commit() => _persist();

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final r = await _client.test(_current);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = r;
    });
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
          DropdownButtonFormField<LlmConnection>(
            initialValue: _connection,
            decoration: InputDecoration(
                labelText: l.connectionMethod, border: const OutlineInputBorder()),
            items: [
              DropdownMenuItem(
                  value: LlmConnection.openai, child: Text(l.openaiCompatible)),
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
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Key',
              border: OutlineInputBorder(),
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
          const SizedBox(height: 16),
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
    final interp = workspace.pythonInterpreter;
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
                ],
              ),
            ),
          ],
        );
      },
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
    final interp = workspace.pythonInterpreter;
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
class _PythonSettingsDialog extends StatelessWidget {
  const _PythonSettingsDialog({required this.workspace});
  final WorkspaceController workspace;

  static final Uri _downloadUrl = Uri.parse('https://www.python.org/downloads/');

  Future<void> _pick(String allFilesLabel) async {
    // Windows 는 python.exe, 그 외는 확장자 없는 실행 파일.
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'Python', extensions: ['exe']),
      XTypeGroup(label: allFilesLabel),
    ]);
    if (file != null) await workspace.setPythonInterpreter(file.path);
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
          listenable: workspace,
          builder: (context, _) {
            final path = workspace.pythonInterpreter;
            final installed = workspace.pythonInstalled;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.selectPythonPrompt),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        path ?? l.notSelected,
                        style: TextStyle(
                          fontSize: 12,
                          color: path == null
                              ? theme.colorScheme.onSurfaceVariant
                              : null,
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
          onPressed: () => Navigator.of(context).pop(),
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
