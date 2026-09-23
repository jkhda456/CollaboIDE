import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../agent/agent_loop.dart';
import 'adaptive.dart';

/// 대화 시작점 창 — 지금까지의 대화를 접고 새로 시작한다.
///
/// 예전에는 웹 모달이었다(2026-09-23 에 앱 창으로 옮겼다 — 다른 창과 같은 모양·동작).
/// 두 가지 모드가 한 창에 있다:
///  - **시작점 만들기**: 이후 AI 는 시작점 뒤만 본다. 계획(PLAYBOOK)도 함께 비운다.
///    "압축해서 보관" 을 켜면 이전 내용을 LLM 이 요약해 시작점에 남긴다 — 미리보기를
///    만들어 **사용자가 고친 뒤** 저장한다.
///  - **계획만 초기화**: 대화는 그대로 두고 계획만 비운다.
Future<void> showCheckpointDialog(BuildContext context, AgentLoop loop) =>
    showDialog<void>(context: context, builder: (_) => _CheckpointDialog(loop: loop));

class _CheckpointDialog extends StatefulWidget {
  const _CheckpointDialog({required this.loop});
  final AgentLoop loop;

  @override
  State<_CheckpointDialog> createState() => _CheckpointDialogState();
}

class _CheckpointDialogState extends State<_CheckpointDialog> {
  /// 계획만 초기화(시작점을 만들지 않는다).
  bool _planOnly = false;
  bool _compress = false;

  /// 압축 목표 크기(토큰). 웹 창과 같은 범위·기본값.
  double _size = 1000;
  bool _previewing = false;
  final TextEditingController _preview = TextEditingController();

  /// 시작 전 컨텍스트 점유량(대화 헤더에 보이는 것과 같은 값).
  int _contextTokens = 0;

  @override
  void initState() {
    super.initState();
    widget.loop.currentContextTokens().then((v) {
      if (mounted) setState(() => _contextTokens = v);
    });
  }

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  /// 압축을 켰으면 미리보기를 만들어 본 뒤에만 만들 수 있다(빈 요약을 저장하지 않게).
  bool get _canCreate => _planOnly || !_compress || _preview.text.trim().isNotEmpty;

  Future<void> _makePreview() async {
    setState(() => _previewing = true);
    final text = await widget.loop.checkpointPreview(_size.round());
    if (!mounted) return;
    setState(() {
      _previewing = false;
      _preview.text = text;
    });
  }

  void _create() {
    if (_planOnly) {
      widget.loop.planReset();
    } else {
      // 시작점을 만들면 루프가 계획(PLAYBOOK)도 같이 비운다.
      widget.loop.checkpointCreate(_compress, _compress ? _preview.text : '');
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return AlertDialog(
      title: Text(l.checkpointTitle),
      content: SizedBox(
        width: adaptiveDialogWidth(context, 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(l.checkpointModeCheckpoint)),
                  ButtonSegment(value: true, label: Text(l.checkpointModePlan)),
                ],
                selected: {_planOnly},
                onSelectionChanged: (v) => setState(() => _planOnly = v.first),
              ),
              const SizedBox(height: 12),
              if (_planOnly)
                Text(l.planResetDesc, style: small)
              else ...[
                Text(l.checkpointDesc, style: small),
                const SizedBox(height: 4),
                Text(l.checkpointPlanNote, style: small),
                const SizedBox(height: 8),
                Text('${l.checkpointCurrentContext}: ~$_contextTokens tok', style: small),
                CheckboxListTile(
                  value: _compress,
                  onChanged: (v) => setState(() => _compress = v ?? false),
                  title: Text(l.checkpointCompress, style: theme.textTheme.bodyMedium),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                if (_compress) ...[
                  Row(
                    children: [
                      Text('${l.checkpointSize}:', style: small),
                      Expanded(
                        child: Slider(
                          value: _size,
                          min: 200,
                          max: 4000,
                          divisions: 19,
                          label: '${(_size / 1000).toStringAsFixed(1)}k tok',
                          onChanged: (v) => setState(() => _size = v),
                        ),
                      ),
                      Text('${(_size / 1000).toStringAsFixed(1)}k tok', style: small),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: _previewing ? null : _makePreview,
                      icon: _previewing
                          ? const SizedBox(
                              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.auto_awesome, size: 18),
                      label: Text(_previewing ? l.checkpointGenerating : l.checkpointPreview),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _preview,
                    maxLines: 8,
                    minLines: 4,
                    style: small,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: l.checkpointMemory,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          onPressed: _canCreate ? _create : null,
          child: Text(_planOnly ? l.planResetButton : l.checkpointCreate),
        ),
      ],
    );
  }
}
