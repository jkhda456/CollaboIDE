import 'dart:convert';

import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:collabo_ide/src/llm/openai_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const cfg = LlmConfig(baseUrl: 'http://x/v1', apiKey: 'k', model: 'm');

  test('LlmConfig: JSON 왕복 + isConfigured', () {
    final full = cfg.copyWith(
        multimodal: true, reasoningEffort: 'low', parseTextToolCalls: true);
    final back = LlmConfig.fromJson(full.toJson());
    expect(back.baseUrl, 'http://x/v1');
    expect(back.model, 'm');
    expect(back.apiKey, 'k');
    expect(back.multimodal, isTrue);
    expect(back.reasoningEffort, 'low');
    expect(back.parseTextToolCalls, isTrue);
    expect(back.isConfigured, isTrue);
    // 기본값은 false.
    expect(const LlmConfig().parseTextToolCalls, isFalse);
    expect(const LlmConfig().isConfigured, isFalse);
    // 기본값(미전송) 왕복.
    expect(LlmConfig.fromJson(cfg.toJson()).reasoningEffort, '');
  });

  test('요청 본문: reasoning_effort 는 설정 시 포함, 빈 값이면 미전송', () async {
    Future<Map<String, Object?>> bodyFor(LlmConfig c) async {
      late Map<String, Object?> sent;
      final mock = MockClient.streaming((request, bodyStream) async {
        sent = jsonDecode(await bodyStream.bytesToString())
            as Map<String, Object?>;
        return http.StreamedResponse(
            Stream.value(utf8.encode('data: [DONE]\n\n')), 200);
      });
      await OpenAiClient(client: mock)
          .streamChat(cfg: c, messages: const [{'role': 'user', 'content': 'x'}])
          .toList();
      return sent;
    }

    expect(await bodyFor(cfg), isNot(contains('reasoning_effort')));
    expect((await bodyFor(cfg.copyWith(reasoningEffort: 'high')))['reasoning_effort'],
        'high');
    // 'none' 도 추론을 끄기 위해 그대로 전송한다(미전송과 구분).
    expect((await bodyFor(cfg.copyWith(reasoningEffort: 'none')))['reasoning_effort'],
        'none');
  });

  test('스트리밍: content 델타와 usage 를 파싱한다', () async {
    final sse = [
      'data: {"choices":[{"delta":{"content":"Hello"}}]}',
      'data: {"choices":[{"delta":{"content":" world"}}]}',
      'data: {"choices":[{"delta":{"reasoning_content":"think"}}]}',
      'data: {"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}',
      'data: [DONE]',
    ].join('\n\n');

    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(Stream.value(utf8.encode(sse)), 200);
    });
    final client = OpenAiClient(client: mock);

    final content = StringBuffer();
    final reasoning = StringBuffer();
    LlmUsage? usage;
    await for (final ev in client.streamChat(
      cfg: cfg,
      messages: const [{'role': 'user', 'content': 'hi'}],
    )) {
      switch (ev) {
        case LlmContent(:final text):
          content.write(text);
        case LlmReasoning(:final text):
          reasoning.write(text);
        case LlmUsage():
          usage = ev;
        case LlmToolCalls():
          break;
      }
    }

    expect(content.toString(), 'Hello world');
    expect(reasoning.toString(), 'think');
    expect(usage?.total, 7);
    expect(usage?.completion, 2);
  });

  test('스트리밍: tool_calls 조각을 합쳐 LlmToolCalls 로 방출', () async {
    final sse = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1",'
          '"type":"function","function":{"name":"read_file","arguments":"{\\"pa"}}]}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,'
          '"function":{"arguments":"th\\":\\"a.txt\\"}"}}]}}]}',
      'data: [DONE]',
    ].join('\n\n');

    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(Stream.value(utf8.encode(sse)), 200);
    });
    final client = OpenAiClient(client: mock);

    LlmToolCalls? tc;
    await for (final ev in client.streamChat(
      cfg: cfg,
      messages: const [{'role': 'user', 'content': 'read a.txt'}],
      tools: const [{'type': 'function', 'function': {'name': 'read_file'}}],
    )) {
      if (ev is LlmToolCalls) tc = ev;
    }
    expect(tc, isNotNull);
    expect(tc!.calls.single.id, 'call_1');
    expect(tc.calls.single.name, 'read_file');
    expect(tc.calls.single.arguments, '{"path":"a.txt"}');
  });

  test('폴백: tool_calls 없이 본문 텍스트로 샌 도구 호출을 잡는다(MLX)', () async {
    // 서버가 도구 호출을 구조화하지 못하고 <|tool_call>…<tool_call|> 로 흘리는 경우.
    String contentEvent(String c) =>
        'data: ${jsonEncode({'choices': [{'delta': {'content': c}}]})}';
    final sse = [
      contentEvent('Reading '),
      contentEvent("<|tool_call>call:collabo_ide:read_file{path:'a.txt'}<tool_call|>"),
      'data: [DONE]',
    ].join('\n\n');

    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(Stream.value(utf8.encode(sse)), 200);
    });
    final client = OpenAiClient(client: mock);

    final content = StringBuffer();
    LlmToolCalls? tc;
    await for (final ev in client.streamChat(
      // 옵션이 켜져 있을 때만 폴백이 동작한다.
      cfg: cfg.copyWith(parseTextToolCalls: true),
      messages: const [{'role': 'user', 'content': 'read a.txt'}],
      tools: const [{'type': 'function', 'function': {'name': 'read_file'}}],
    )) {
      if (ev is LlmContent) content.write(ev.text);
      if (ev is LlmToolCalls) tc = ev;
    }

    // 마커 블록은 사용자 표시에서 가려진다.
    expect(content.toString().contains('tool_call'), isFalse);
    expect(content.toString().trim(), 'Reading');
    // 네임스페이스가 벗겨진 read_file 호출이 방출된다.
    expect(tc, isNotNull);
    expect(tc!.calls.single.name, 'read_file');
    expect(jsonDecode(tc.calls.single.arguments), {'path': 'a.txt'});
  });

  test('폴백 off(기본): 본문 마커를 건드리지 않고 그대로 흘린다', () async {
    String contentEvent(String c) =>
        'data: ${jsonEncode({'choices': [{'delta': {'content': c}}]})}';
    final sse = [
      contentEvent("<|tool_call>call:read_file{path:'a.txt'}<tool_call|>"),
      'data: [DONE]',
    ].join('\n\n');
    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(Stream.value(utf8.encode(sse)), 200);
    });
    final client = OpenAiClient(client: mock);

    final content = StringBuffer();
    var sawToolCalls = false;
    await for (final ev in client.streamChat(
      cfg: cfg, // parseTextToolCalls 기본 false
      messages: const [{'role': 'user', 'content': 'read a.txt'}],
      tools: const [{'type': 'function', 'function': {'name': 'read_file'}}],
    )) {
      if (ev is LlmContent) content.write(ev.text);
      if (ev is LlmToolCalls) sawToolCalls = true;
    }
    // 옵션이 꺼져 있으면 마커를 파싱/은닉하지 않고 본문 그대로 전달.
    expect(sawToolCalls, isFalse);
    expect(content.toString(),
        "<|tool_call>call:read_file{path:'a.txt'}<tool_call|>");
  });

  test('스트리밍: 비정상 상태코드는 예외', () async {
    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(Stream.value(utf8.encode('nope')), 401);
    });
    final client = OpenAiClient(client: mock);
    expect(
      () => client.streamChat(cfg: cfg, messages: const [{'role': 'user', 'content': 'x'}]).toList(),
      throwsA(isA<Exception>()),
    );
  });

  test('연결 상태 확인: 200 이면 성공', () async {
    final mock = MockClient((request) async {
      expect(request.url.toString(), 'http://x/v1/models');
      return http.Response('{}', 200);
    });
    final client = OpenAiClient(client: mock);
    final r = await client.test(cfg);
    expect(r.ok, isTrue);
  });
}
