// 좁은 화면 대비 공용 배치: 목록 | 상세(폭 조절) ↔ 한 장씩(뒤로), 대화상자 폭.
import 'package:collabo_ide/l10n/app_localizations.dart';
import 'package:collabo_ide/src/ui/adaptive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {double width = 1000}) => MaterialApp(
      locale: const Locale('ko'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: SizedBox(width: width, height: 600, child: child))),
    );

class _Harness extends StatefulWidget {
  const _Harness();
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool detail = false;
  @override
  Widget build(BuildContext context) => MasterDetail(
        master: ListView(children: [
          ListTile(title: const Text('item'), onTap: () => setState(() => detail = true)),
        ]),
        detail: const Center(child: Text('DETAIL')),
        showDetail: detail,
        detailTitle: 'item',
        onBack: () => setState(() => detail = false),
      );
}

void main() {
  testWidgets('넓으면 목록과 상세를 나란히, 목록 폭은 끌어서 바꾼다', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(const _Harness()));
    expect(find.text('item'), findsOneWidget);
    expect(find.text('DETAIL'), findsOneWidget);
    final listW = tester.getSize(find.byType(ListView)).width;
    expect(listW, 280);
    await tester.dragFrom(tester.getTopRight(find.byType(ListView)) + const Offset(3, 100), const Offset(120, 0));
    await tester.pump();
    expect(tester.getSize(find.byType(ListView)).width, greaterThan(listW + 80));
    // 상세 최소 폭(240)은 지킨다.
    await tester.dragFrom(tester.getTopRight(find.byType(ListView)) + const Offset(3, 100), const Offset(2000, 0));
    await tester.pump();
    expect(tester.getSize(find.byType(ListView)).width, lessThanOrEqualTo(1000 - 240 - 6));
  });

  testWidgets('좁으면 목록 → 상세(뒤로) 한 장씩', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(const _Harness(), width: 380));
    expect(find.text('DETAIL'), findsNothing);
    await tester.tap(find.text('item'));
    await tester.pump();
    expect(find.text('DETAIL'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(find.text('DETAIL'), findsNothing);
    expect(find.text('item'), findsOneWidget);
  });

  testWidgets('대화상자 폭은 화면에 맞춰 줄어든다', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late double narrow;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      narrow = adaptiveDialogWidth(c, 460);
      return const SizedBox();
    })));
    expect(narrow, 390 - 128);
    expect(isCompactScreen(tester.element(find.byType(SizedBox))), isTrue);
  });
}
