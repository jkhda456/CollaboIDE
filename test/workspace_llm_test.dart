import 'dart:io';

import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/data/app_database.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUpAll(initSqliteFfi);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_llm_');
    db = await AppDatabase.open(path: p.join(tmp.path, 'collabo.db'));
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('마이그레이션: 레거시 단일 llm 설정 → 프리셋 1개(Default)', () async {
    await db.setSetting('llm', {
      'baseUrl': 'http://legacy/v1',
      'model': 'old-model',
      'multimodal': true,
    });
    final wc = WorkspaceController();
    await wc.loadLlmForTest(db);

    expect(wc.llmPresets, hasLength(1));
    expect(wc.llmPresets.first.name, 'Default');
    expect(wc.defaultPresetId, wc.llmPresets.first.id);
    expect(wc.llmConfig.baseUrl, 'http://legacy/v1');
    expect(wc.llmConfig.model, 'old-model');
    expect(wc.llmConfig.multimodal, isTrue);
    // 프리셋 목록이 DB 에 저장됐다.
    expect(await db.getSetting('llm_presets'), isA<List>());
  });

  test('설정이 전혀 없으면 빈 기본 프리셋 1개를 만든다', () async {
    final wc = WorkspaceController();
    await wc.loadLlmForTest(db);
    expect(wc.llmPresets, hasLength(1));
    expect(wc.llmConfig.isConfigured, isFalse);
    expect(wc.defaultPresetId, isNotEmpty);
  });

  test('해석 우선순위: 프로젝트/도구 매핑 > 기본 프리셋', () async {
    final wc = WorkspaceController();
    await wc.loadLlmForTest(db);
    // 기본 프리셋(default) 구성.
    await wc.updatePreset(wc.defaultPresetId,
        config: const LlmConfig(baseUrl: 'http://def/v1', model: 'def'));
    // 두 번째 프리셋 추가.
    final alt = await wc.addPreset(
        name: 'Alt', config: const LlmConfig(baseUrl: 'http://alt/v1', model: 'alt'));

    // 도구 매핑 없으면 기본.
    expect(wc.configForTool('run_subagent').model, 'def');
    // 도구에 alt 지정 → alt.
    await wc.setToolModel('run_subagent', alt.id);
    expect(wc.configForTool('run_subagent').model, 'alt');
    // verify_work 는 여전히 기본.
    expect(wc.configForTool('verify_work').model, 'def');

    // 프로젝트 매핑.
    expect(wc.configForConversation('/proj/x').model, 'def');
    await wc.setProjectModel('/proj/x', alt.id);
    expect(wc.configForConversation('/proj/x').model, 'alt');
    expect(wc.configForConversation('/proj/y').model, 'def');
  });

  test('도구 기본값은 프로젝트 대화 모델(헤더 선택)을 따른다', () async {
    final wc = WorkspaceController();
    await wc.loadLlmForTest(db);
    await wc.updatePreset(wc.defaultPresetId,
        config: const LlmConfig(baseUrl: 'http://def/v1', model: 'def'));
    final alt = await wc.addPreset(
        name: 'Alt', config: const LlmConfig(baseUrl: 'http://alt/v1', model: 'alt'));

    // 프로젝트 지정이 없으면 기본 프리셋.
    expect(wc.configForTool('run_subagent', '/proj/x').model, 'def');

    // 헤더에서 alt 를 고르면, 도구 지정이 없는 서브에이전트도 alt 를 쓴다.
    await wc.setProjectModel('/proj/x', alt.id);
    expect(wc.configForTool('run_subagent', '/proj/x').model, 'alt');
    expect(wc.configForTool('verify_work', '/proj/x').model, 'alt');
    // 다른 프로젝트는 영향 없음.
    expect(wc.configForTool('run_subagent', '/proj/y').model, 'def');

    // 도구에 명시 지정이 있으면 그게 대화 모델보다 우선.
    final third = await wc.addPreset(
        name: 'Third',
        config: const LlmConfig(baseUrl: 'http://third/v1', model: 'third'));
    await wc.setToolModel('run_subagent', third.id);
    expect(wc.configForTool('run_subagent', '/proj/x').model, 'third');
    expect(wc.configForTool('verify_work', '/proj/x').model, 'alt');
  });

  test('기본 프리셋 변경 + 프리셋 삭제 시 매핑 정리', () async {
    final wc = WorkspaceController();
    await wc.loadLlmForTest(db);
    final defId = wc.defaultPresetId;
    final alt = await wc.addPreset(name: 'Alt');
    await wc.setToolModel('verify_work', alt.id);
    await wc.setProjectModel('/proj/z', alt.id);

    // alt 를 기본으로.
    await wc.setDefaultPreset(alt.id);
    expect(wc.defaultPresetId, alt.id);

    // alt 삭제 → 기본은 남은 프리셋, 매핑은 정리되어 기본 사용으로 환원.
    await wc.removePreset(alt.id);
    expect(wc.llmPresets, hasLength(1));
    expect(wc.defaultPresetId, defId);
    expect(wc.presetIdForTool('verify_work'), '');
    expect(wc.presetIdForProject('/proj/z'), '');
  });

  test('마지막 1개 프리셋은 삭제되지 않는다', () async {
    final wc = WorkspaceController();
    await wc.loadLlmForTest(db);
    await wc.removePreset(wc.defaultPresetId);
    expect(wc.llmPresets, hasLength(1));
  });
}
