import 'dart:convert';

import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:collabo_ide/src/llm/openai_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const cfg = LlmConfig(baseUrl: 'http://x/v1', apiKey: 'k', model: 'm');

  test('LlmConfig: JSON 왕복 + isConfigured', () {
    final j = cfg.toJson();
    final back = LlmConfig.fromJson(j);
    expect(back.baseUrl, 'http://x/v1');
    expect(back.model, 'm');
    expect(back.apiKey, 'k');
    expect(back.isConfigured, isTrue);
    expect(const LlmConfig().isConfigured, isFalse);
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
