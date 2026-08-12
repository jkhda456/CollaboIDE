import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app/workspace_controller.dart';
import '../process/background_process_registry.dart';

/// 백그라운드 프로세스 뷰어를 연다(좌측 활동 아이콘 클릭 → 이 다이얼로그).
Future<void> showProcessMonitor(BuildContext context, WorkspaceController ws) {
  return showDialog<void>(
    context: context,
    builder: (_) => ProcessMonitorDialog(workspace: ws),
  );
}

/// 실행 중/완료 백그라운드 프로세스를 목록화하고, 선택 시 stdout/stderr 를 실시간
/// tail 로 보여주며, 표준입력 전달 + 종료(트리 kill)를 제공한다.
class ProcessMonitorDialog extends StatefulWidget {
  const ProcessMonitorDialog({super.key, required this.workspace});

  final WorkspaceController workspace;

  @override
  State<ProcessMonitorDialog> createState() => _ProcessMonitorDialogState();
}

class _ProcessMonitorDialogState extends State<ProcessMonitorDialog> {
  BackgroundProcessRegistry get _reg => widget.workspace.backgroundProcesses;

  String? _selectedId;
  String _stdout = '';
  String _stderr = '';
  Timer? _timer;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _reg.refresh();
    _reg.addListener(_onReg);
    final procs = _reg.processes;
    if (procs.isNotEmpty) _selectedId = procs.first.id;
    _timer = Timer.periodic(const Duration(milliseconds: 600), (_) => _pump());
    _pump();
  }

  void _onReg() {
    if (mounted) setState(() {});
  }

  BackgroundProcess? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final proc in _reg.processes) {
      if (proc.id == id) return proc;
    }
    return null;
  }

  Future<void> _pump() async {
    final sel = _selected;
    if (sel == null) return;
    final out = await _tail(sel.stdoutPath);
    final err = await _tail(sel.stderrPath);
    if (!mounted || (out == _stdout && err == _stderr)) return;
    setState(() {
      _stdout = out;
      _stderr = err;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// 로그 파일의 말미 최대 [max] 바이트를 읽는다.
  static Future<String> _tail(String path, {int max = 64 * 1024}) async {
    try {
      final f = File(path);
      if (!await f.exists()) return '';
      final len = await f.length();
      final raf = await f.open();
      final start = len > max ? len - max : 0;
      if (start > 0) await raf.setPosition(start);
      final bytes = await raf.read(len - start);
      await raf.close();
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  void _select(String id) {
    setState(() {
      _selectedId = id;
      _stdout = '';
      _stderr = '';
    });
    _pump();
  }

  Future<void> _send() async {
    final sel = _selected;
    if (sel == null || _input.text.isEmpty) return;
    await _reg.sendInput(sel.id, _input.text);
    _input.clear();
  }

  String _statusLabel(AppLocalizations l, BackgroundProcess proc) {
    switch (proc.status) {
      case BackgroundStatus.running:
      case BackgroundStatus.unknown:
        return l.procStatusRunning;
      case BackgroundStatus.exited:
        return l.procStatusExited(proc.exitCode ?? 0);
      case BackgroundStatus.killed:
        return l.procStatusKilled;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _reg.removeListener(_onReg);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final procs = _reg.processes;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 헤더
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Icon(Icons.sync, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(l.procTitle, style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: l.close,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: procs.isEmpty
                  ? Center(
                      child: Text(l.procEmpty,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)))
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 280, child: _buildList(l, theme, procs)),
                        const VerticalDivider(width: 1),
                        Expanded(child: _buildDetail(l, theme)),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
      AppLocalizations l, ThemeData theme, List<BackgroundProcess> procs) {
    return ListView.separated(
      itemCount: procs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final proc = procs[i];
        final selected = proc.id == _selectedId;
        return ListTile(
          dense: true,
          selected: selected,
          leading: Icon(
            proc.isRunning ? Icons.play_circle : Icons.check_circle_outline,
            size: 18,
            color: proc.isRunning
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          title: Text(proc.command,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${_statusLabel(l, proc)}'
            '${proc.pid != null ? '  ·  PID ${proc.pid}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _select(proc.id),
        );
      },
    );
  }

  Widget _buildDetail(AppLocalizations l, ThemeData theme) {
    final sel = _selected;
    if (sel == null) {
      return Center(
        child: Text(l.procSelectHint,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      height: 1.35,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 상세 헤더: 명령 + 종료 버튼
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(sel.command,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium),
              ),
              if (sel.isRunning)
                TextButton.icon(
                  icon: const Icon(Icons.stop_circle, size: 18),
                  label: Text(l.procStop),
                  style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error),
                  onPressed: () => _reg.kill(sel.id),
                ),
            ],
          ),
        ),
        // 출력(stdout + stderr)
        Expanded(
          child: Container(
            width: double.infinity,
            color: theme.colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.all(10),
            child: SingleChildScrollView(
              controller: _scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SelectableText(_stdout, style: mono),
                  if (_stderr.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(l.procStderr,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.error)),
                    SelectableText(
                      _stderr,
                      style: mono?.copyWith(color: theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        // 표준입력 전송(실행 중일 때만)
        if (sel.isRunning)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      hintText: l.procInputHint,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _send, child: Text(l.procSend)),
              ],
            ),
          ),
      ],
    );
  }
}
