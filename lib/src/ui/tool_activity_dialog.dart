import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../tools/tool_call_log.dart';
import 'adaptive.dart';

/// 도구 호출 내역 창을 연다(대화의 "호출 내역" 링크 → 이 다이얼로그).
/// [initialId] 가 있으면 그 호출을 선택한 상태로 연다.
Future<void> showToolActivity(
  BuildContext context,
  ToolCallLog log, {
  String initialId = '',
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ToolActivityDialog(log: log, initialId: initialId),
  );
}

/// 도구 호출 목록 + 선택한 호출의 **인자/결과 원문**.
///
/// 결과는 수십 KB 가 되기도 해서 대화 버블에는 요약만 남기고, 원문은 여기서 본다
/// (프로세스 뷰어와 같은 구성: 왼쪽 목록 / 오른쪽 내용).
class ToolActivityDialog extends StatefulWidget {
  const ToolActivityDialog({super.key, required this.log, this.initialId = ''});

  final ToolCallLog log;
  final String initialId;

  @override
  State<ToolActivityDialog> createState() => _ToolActivityDialogState();
}

class _ToolActivityDialogState extends State<ToolActivityDialog> {
  String? _selectedId;

  /// 좁은 화면에서 상세를 보고 있는가. 특정 기록을 열라고 왔으면 상세부터 보여 준다.
  late bool _showDetail = widget.initialId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final records = widget.log.records;
    _selectedId = widget.initialId.isNotEmpty
        ? widget.initialId
        : (records.isNotEmpty ? records.first.id : null);
    // 도구가 계속 돌면서 기록이 늘어나므로 실시간으로 따라간다.
    widget.log.addListener(_onLog);
  }

  @override
  void dispose() {
    widget.log.removeListener(_onLog);
    super.dispose();
  }

  void _onLog() {
    if (mounted) setState(() {});
  }

  ToolCallRecord? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final r in widget.log.records) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// JSON 이면 보기 좋게 들여쓰고, 아니면 원문 그대로.
  String _pretty(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    if (!text.startsWith('{') && !text.startsWith('[')) return raw;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } catch (_) {
      return raw; // 잘린 JSON 등 — 원문이 더 유용하다
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final records = widget.log.records;
    // 휴대폰에서는 화면 전체를 쓴다(작은 창에 목록·상세를 끼우면 둘 다 못 읽는다).
    final compact = isCompactScreen(context);
    return Dialog(
      insetPadding: compact ? EdgeInsets.zero : null,
      shape: compact ? const RoundedRectangleBorder() : null,
      child: ConstrainedBox(
        constraints: compact
            ? const BoxConstraints.expand()
            : const BoxConstraints(maxWidth: 900, maxHeight: 640),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  Text(l.activityTitleNative,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 10),
                  Text('${records.length}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const Spacer(),
                  TextButton(
                    onPressed: records.isEmpty
                        ? null
                        : () {
                            widget.log.clear();
                            setState(() => _selectedId = null);
                          },
                    child: Text(l.activityClear),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: records.isEmpty
                  ? Center(
                      child: Text(l.activityEmptyNative,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    )
                  : MasterDetail(
                      master: ListView.builder(
                        itemCount: records.length,
                        itemBuilder: (context, i) => _row(context, records[i]),
                      ),
                      detail: _detail(context),
                      showDetail: _showDetail && _selected != null,
                      detailTitle: _selected?.name,
                      onBack: () => setState(() => _showDetail = false),
                    ),
            ),
            const Divider(height: 1),
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
    );
  }

  Widget _row(BuildContext context, ToolCallRecord r) {
    final theme = Theme.of(context);
    final selected = r.id == _selectedId;
    final color = r.running
        ? theme.colorScheme.onSurfaceVariant
        : (r.ok == true ? Colors.green : theme.colorScheme.error);
    return ListTile(
      dense: true,
      selected: selected,
      leading: Icon(
        r.running
            ? Icons.hourglass_empty
            : (r.ok == true ? Icons.check_circle_outline : Icons.error_outline),
        size: 18,
        color: color,
      ),
      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_scopeLabel(context, r.scope)} · ${_elapsed(r)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      onTap: () => setState(() {
        _selectedId = r.id;
        _showDetail = true;
      }),
    );
  }

  String _scopeLabel(BuildContext context, String scope) {
    final l = AppLocalizations.of(context);
    return switch (scope) {
      'subagent' => l.activityScopeSub,
      'verify' => l.activityScopeVerify,
      'delegate' => l.activityScopeDelegate,
      _ => l.activityScopeMain,
    };
  }

  String _elapsed(ToolCallRecord r) {
    final ms = r.elapsed.inMilliseconds;
    if (r.running) return '…';
    return ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(1)}s';
  }

  Widget _detail(BuildContext context) {
    final l = AppLocalizations.of(context);
    final r = _selected;
    if (r == null) {
      return Center(
        child: Text(l.activitySelectHint,
            style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
          child: Row(
            children: [
              Expanded(
                child: Text('${r.name}  ·  ${_scopeLabel(context, r.scope)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                tooltip: l.copy,
                icon: const Icon(Icons.copy_all, size: 18),
                onPressed: () => Clipboard.setData(ClipboardData(
                    text: '# ${r.name}\n'
                        '## args\n${_pretty(r.args)}\n'
                        '## result\n${_pretty(r.result)}')),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              _section(context, l.activityArgs, _pretty(r.args)),
              const SizedBox(height: 12),
              _section(
                context,
                l.activityResult,
                r.running ? '…' : _pretty(r.result),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _section(BuildContext context, String title, String body) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            body.isEmpty ? '—' : body,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}
