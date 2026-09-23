import 'package:flutter/material.dart';

import '../agent/agent_loop.dart';
import '../../l10n/app_localizations.dart';

/// 중지: **지금까지 한 것을 어떻게 할지** 묻는다.
///
/// 생성 도중에는 이미 도구가 돌고 계획이 바뀌었을 수 있다. 예전에는 중지가 무조건
/// 요청 직전으로 되돌려, 절반쯤 끝난 작업이 통째로 사라졌다 — 그래서 고른다:
///  - **여기까지 남기기**: 이번 요청이 남긴 기록을 그대로 두고 멈춘다(흘러오던 답도 그 자리까지).
///  - **전부 취소**: 요청 직전으로 되돌린다(예전 동작).
///  - **계속 진행**: 아무것도 하지 않는다.
///
/// 도구가 이미 고친 파일은 어느 쪽을 골라도 그대로다 — 되돌리는 것은 대화 기록뿐이다.
/// 웹은 **진행된 것이 있을 때만** 이 창을 요청한다(없으면 바로 중지한다).
Future<void> showStopChoice(BuildContext context, AgentLoop loop) async {
  final l = AppLocalizations.of(context);
  final keep = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.stopChoiceTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.stopChoiceBody),
          const SizedBox(height: 8),
          Text(l.stopChoiceNote, style: Theme.of(ctx).textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.stopContinue)),
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
          child: Text(l.stopDiscard),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.stopKeep)),
      ],
    ),
  );
  if (keep == null) return; // 계속 진행
  loop.stop(keep: keep);
}
