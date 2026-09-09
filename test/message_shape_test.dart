import 'package:collabo_ide/src/llm/message_shape.dart';
import 'package:flutter_test/flutter_test.dart';

/// 보내는 메시지 배열의 **모양** 규칙.
///
/// OpenAI 호환 서버는 관대하지만 로컬 서버(llama.cpp)는 모델의 Jinja 템플릿을 그대로
/// 렌더링해서, system 이 여러 개거나 배열이 system 으로 끝나면 그 자리에서 실패한다.
/// 여기서 고정하는 것은 **양쪽 다 통과하는 모양**이다.
void main() {
  group('systemHead', () {
    test('여러 조각을 하나의 system 으로 합친다', () {
      final head = systemHead(['프롬프트', '프로젝트 상태']);

      expect(head, hasLength(1));
      expect(head.first['role'], 'system');
      expect(head.first['content'], '프롬프트\n\n프로젝트 상태');
    });

    test('빈 조각과 null 은 버린다', () {
      final head = systemHead([null, '  ', '프롬프트', '']);

      expect(head, hasLength(1));
      expect(head.first['content'], '프롬프트');
    });

    test('남는 조각이 없으면 아무것도 넣지 않는다', () {
      expect(systemHead([null, '   ']), isEmpty);
    });
  });

  group('chatShapeProblem', () {
    Map<String, Object?> msg(String role, [String text = 'x']) =>
        {'role': role, 'content': text};

    test('system 하나 + 대화면 통과', () {
      expect(
        chatShapeProblem([msg('system'), msg('user'), msg('assistant'), msg('user')]),
        isNull,
      );
    });

    test('system 이 없어도 된다', () {
      expect(chatShapeProblem([msg('user')]), isNull);
    });

    test('도구 결과로 끝나는 중간 상태도 통과한다', () {
      // 에이전트 루프는 tool 결과를 붙인 뒤 같은 배열로 다시 호출한다.
      expect(
        chatShapeProblem([msg('system'), msg('user'), msg('assistant'), msg('tool')]),
        isNull,
      );
    });

    test('system 이 두 개면 잡는다', () {
      expect(chatShapeProblem([msg('system'), msg('system'), msg('user')]),
          contains('more than one system'));
    });

    test('대화 중간의 system 을 잡는다', () {
      expect(
        chatShapeProblem([msg('system'), msg('user'), msg('system'), msg('user')]),
        contains('after the conversation started'),
      );
    });

    test('system 으로 끝나면 잡는다', () {
      // 사전 평가를 맨 뒤에 붙이던 예전 모양 — 대부분의 템플릿이 생성을 시작하지 못한다.
      expect(chatShapeProblem([msg('system'), msg('user'), msg('system')]),
          contains('ends with a system'));
    });

    test('사용자 메시지가 하나도 없으면 잡는다', () {
      // 시작점을 만든 직후 "다시 시도" 를 누르면 이 모양이 됐다.
      expect(chatShapeProblem([msg('system')]), contains('no user message'));
    });

    test('빈 배열을 잡는다', () {
      expect(chatShapeProblem([]), isNotNull);
    });
  });

  group('시작점(체크포인트) 이후의 모양', () {
    test('압축본이 있으면 assistant 요약 + 사용자 메시지', () {
      final messages = [
        ...systemHead(['프롬프트', '프로젝트 상태']),
        {'role': 'assistant', 'content': 'Summary of our earlier conversation…'},
        {'role': 'user', 'content': '이어서 해줘'},
      ];

      expect(chatShapeProblem(messages), isNull);
      expect(messages.where((m) => m['role'] == 'system'), hasLength(1));
    });

    test('압축본이 없으면 요약이 들어가지 않는다', () {
      // 시작점 이후 메시지만 남는 것이 곧 "압축 없음" 의 의미다.
      final messages = [
        ...systemHead(['프롬프트']),
        {'role': 'user', 'content': '새로 시작'},
      ];

      expect(chatShapeProblem(messages), isNull);
      expect(messages, hasLength(2));
    });
  });
}
