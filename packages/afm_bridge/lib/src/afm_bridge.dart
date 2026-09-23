import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'models.dart';

/// AFMBridge 진입점.
///
/// 요청/응답은 OpenAI Chat Completions 형식의 `Map` 이다.
/// ```dart
/// final status = await AfmBridge.status();
/// final res = await AfmBridge.chatCompletions({'messages': [AfmMessage.user('안녕?')]});
/// print(res['choices'][0]['message']['content']);
/// ```
abstract final class AfmBridge {
  static const MethodChannel _channel = MethodChannel('afm_bridge');
  static const EventChannel _events = EventChannel('afm_bridge/stream');

  static const String defaultModel = 'apple-on-device';

  static Stream<Map<Object?, Object?>>? _eventStream;
  static int _nextStreamId = 0;

  static Stream<Map<Object?, Object?>> get _allEvents =>
      _eventStream ??= _events.receiveBroadcastStream().map((e) => e as Map<Object?, Object?>);

  /// 모델 상태. 사용 불가 시 [AfmStatus.reason] 과 안내 문구를 확인한다.
  static Future<AfmStatus> status({String model = defaultModel}) async {
    final json = await _channel.invokeMethod<String>('status', {'model': model});
    return AfmStatus.fromJson(jsonDecode(json!) as Map<String, dynamic>);
  }

  /// 엔진 설정. 한국어 서비스에서는 기본 가드레일의 오탐이 잦아 [permissiveGuardrails] 사용을 권장.
  static Future<void> configure({
    int? maxConcurrentRequests,
    bool? trimHistory,
    bool? permissiveGuardrails,
    String? defaultInstructions,
  }) =>
      _channel.invokeMethod<void>('configure', {
        'maxConcurrentRequests': ?maxConcurrentRequests,
        'trimHistory': ?trimHistory,
        'permissiveGuardrails': ?permissiveGuardrails,
        'defaultInstructions': ?defaultInstructions,
      });

  /// 모델을 미리 로드해 첫 응답 지연을 줄인다.
  static Future<void> prewarm({String? instructions}) =>
      _channel.invokeMethod<void>('prewarm', {'instructions': ?instructions});

  /// `POST /v1/chat/completions` (비스트리밍). 실패 시 [AfmBridgeException].
  static Future<Map<String, dynamic>> chatCompletions(Map<String, dynamic> request) async {
    try {
      final json = await _channel.invokeMethod<String>('chatCompletions', {'request': _encode(request)});
      return jsonDecode(json!) as Map<String, dynamic>;
    } on PlatformException catch (e) {
      throw _exception(e);
    }
  }

  /// 스트리밍. `chat.completion.chunk` 를 순서대로 내보낸다. 구독 취소 시 생성도 취소된다.
  static Stream<Map<String, dynamic>> chatCompletionsStream(Map<String, dynamic> request) {
    final id = 's${DateTime.now().microsecondsSinceEpoch}_${_nextStreamId++}';
    late final StreamController<Map<String, dynamic>> controller;
    StreamSubscription<Map<Object?, Object?>>? subscription;
    var finished = false;

    controller = StreamController<Map<String, dynamic>>(
      onListen: () {
        subscription = _allEvents.where((e) => e['id'] == id).listen((event) {
          final data = event['data'] as String?;
          switch (event['event']) {
            case 'chunk':
              controller.add(jsonDecode(data!) as Map<String, dynamic>);
            case 'error':
              finished = true;
              controller.addError(AfmBridgeException.fromJson(jsonDecode(data!) as Map<String, dynamic>));
              controller.close();
            case 'done':
              finished = true;
              controller.close();
          }
        }, onError: controller.addError);
        _channel.invokeMethod<void>('streamStart', {'id': id, 'request': _encode(request)}).catchError(
          (Object e) {
            finished = true;
            controller.addError(e is PlatformException ? _exception(e) : e);
            controller.close();
          },
        );
      },
      onCancel: () async {
        if (!finished) await _channel.invokeMethod<void>('streamCancel', {'id': id});
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// 간단 호출: 프롬프트 → 답변 텍스트.
  static Future<String> chat(
    String prompt, {
    String? system,
    List<Map<String, dynamic>> history = const [],
    double? temperature,
    int? maxTokens,
  }) async {
    final res = await chatCompletions({
      'messages': [if (system != null) AfmMessage.system(system), ...history, AfmMessage.user(prompt)],
      'temperature': ?temperature,
      'max_tokens': ?maxTokens,
    });
    return (res['choices'] as List).first['message']['content'] as String? ?? '';
  }

  /// 간단 스트리밍: 텍스트 조각만 내보낸다.
  static Stream<String> chatStream(
    String prompt, {
    String? system,
    List<Map<String, dynamic>> history = const [],
    double? temperature,
    int? maxTokens,
  }) =>
      chatCompletionsStream({
        'messages': [if (system != null) AfmMessage.system(system), ...history, AfmMessage.user(prompt)],
        'temperature': ?temperature,
        'max_tokens': ?maxTokens,
      }).expand((chunk) {
        final choices = chunk['choices'] as List;
        if (choices.isEmpty) return const <String>[];
        final content = (choices.first['delta'] as Map)['content'] as String?;
        return content == null || content.isEmpty ? const <String>[] : [content];
      });

  /// 앱 내장 OpenAI 호환 서버 시작 (127.0.0.1). [port] 0 이면 자동 할당. 바인딩된 포트를 반환.
  static Future<int> startServer({String host = '127.0.0.1', int port = 0, String? apiKey, bool allowCORS = false}) async {
    final bound = await _channel.invokeMethod<int>('serverStart', {
      'host': host,
      'port': port,
      'apiKey': ?apiKey,
      'allowCORS': allowCORS,
    });
    return bound!;
  }

  static Future<void> stopServer() => _channel.invokeMethod<void>('serverStop');

  static String _encode(Map<String, dynamic> request) =>
      jsonEncode({'model': defaultModel, ...request});

  static AfmBridgeException _exception(PlatformException e) {
    final details = e.details;
    if (details is String) {
      try {
        return AfmBridgeException.fromJson(jsonDecode(details) as Map<String, dynamic>);
      } catch (_) {}
    }
    return AfmBridgeException(message: e.message ?? e.code, code: e.code);
  }
}
