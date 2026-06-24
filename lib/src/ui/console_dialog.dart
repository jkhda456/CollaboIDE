import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// 실시간 출력 콘솔 다이얼로그.
///
/// 주어진 인터프리터로 스크립트를 실행하고 stdout/stderr 를 **실시간**으로 보여준다.
/// (사용자 입력은 받지 않는다 — 표시 전용.)
class ConsoleDialog extends StatefulWidget {
  const ConsoleDialog({
    super.key,
    required this.interpreter,
    required this.scriptPath,
    this.title,
    this.environment,
  });

  final String interpreter;
  final String scriptPath;
  final String? title;
  final Map<String, String>? environment;

  @override
  State<ConsoleDialog> createState() => _ConsoleDialogState();
}

class _ConsoleDialogState extends State<ConsoleDialog> {
  Process? _proc;
  final StringBuffer _buf = StringBuffer();
  final ScrollController _scroll = ScrollController();
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final env = <String, String>{'PYTHONIOENCODING': 'utf-8'};
      if (widget.environment != null) env.addAll(widget.environment!);
      // -u: 버퍼링 없이 실시간 출력.
      final proc = await Process.start(
        widget.interpreter,
        ['-u', widget.scriptPath],
        environment: env,
      );
      _proc = proc;
      setState(() => _running = true);
      proc.stdout.transform(utf8.decoder).listen(_append);
      proc.stderr.transform(utf8.decoder).listen(_append);
      proc.exitCode.then((code) {
        if (mounted) {
          _append('\n${AppLocalizations.of(context).consoleProcessExited(code)}\n');
          setState(() => _running = false);
        }
      });
    } catch (e) {
      if (mounted) {
        _append('${AppLocalizations.of(context).consoleExecFailed('$e')}\n');
        setState(() => _running = false);
      }
    }
  }

  void _append(String s) {
    _buf.write(s);
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _proc?.kill();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.title ?? l.console,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  if (_running)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(
                          width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // 콘솔 출력(실시간, 표시 전용).
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: SelectableText(
                    _buf.isEmpty ? l.consoleStarting : _buf.toString(),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      color: Color(0xFFE0E0E0),
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
