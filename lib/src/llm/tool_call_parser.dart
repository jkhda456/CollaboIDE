import 'dart:convert';

import 'llm_provider.dart';

/// 도구 호출을 감싸는 마커 한 쌍(여는/닫는). 서버·모델마다 형식이 달라서
/// 여러 쌍을 동시에 인식한다.
class ToolMarker {
  const ToolMarker(this.open, this.close);
  final String open;
  final String close;
}

/// 기본 인식 마커 목록. 앞쪽이 우선(같은 위치에서 겹치면 먼저 나온 게 이긴다).
///
/// - `<tool_call>…</tool_call>` : 프롬프트 폴백이 모델에 지시하는 표준 형식.
/// - `<|tool_call>…<tool_call|>` : 일부 로컬(MLX 등) 모델이 자기 훈련 토큰으로
///   뱉는 형식(파이프가 안쪽, 비대칭). 서버가 이를 `tool_calls` 로 변환하지 못하고
///   본문 텍스트로 흘릴 때 여기서 잡는다.
const List<ToolMarker> defaultToolMarkers = [
  ToolMarker('<tool_call>', '</tool_call>'),
  ToolMarker('<|tool_call>', '<tool_call|>'),
];

/// 본문 스트림에서 도구 호출 블록을 가려내는 증분 파서.
///
/// - 여러 [ToolMarker] 쌍을 동시에 인식한다(서버/모델별 형식 차이 흡수).
/// - 델타 경계에 마커가 걸쳐도(부분 마커) 안전하게 처리한다.
/// - [knownNames] 를 주면 그 이름의 도구 호출만 인정한다(일반 산문에 우연히 낀
///   `<tool_call>` 오탐 방지). 네임스페이스 접두어(`collabo_ide:read_file`)는
///   마지막 `:` 뒤 이름으로도 매칭한다. 미지정이면 파싱되는 모든 호출을 인정.
class PromptedToolParser {
  PromptedToolParser({List<ToolMarker>? markers, Set<String>? knownNames})
      : _markers = markers ?? defaultToolMarkers,
        // 네임드 파라미터라 private 초기화 형식(this._knownNames) 을 못 쓴다.
        // ignore: prefer_initializing_formals
        _knownNames = knownNames;

  final List<ToolMarker> _markers;
  final Set<String>? _knownNames;

  bool _capturing = false;
  ToolMarker? _active; // 캡처 중인 블록을 연 마커(닫는 마커 매칭·복원용)
  String _buf = ''; // 텍스트 모드에서 아직 안전하게 못 내보낸 잔여
  String _cap = ''; // 캡처 모드에서 모으는 도구 호출 본문
  final List<_Captured> _captured = []; // 추출된 (마커, 본문) 블록

  /// 청크를 먹이고, 지금 보여줘도 안전한 텍스트를 돌려준다.
  String add(String chunk) {
    final out = StringBuffer();
    _buf += chunk;
    while (true) {
      if (!_capturing) {
        // 여러 여는 마커 중 가장 앞서 등장하는 것을 찾는다.
        var bestIdx = -1;
        ToolMarker? best;
        for (final m in _markers) {
          final i = _buf.indexOf(m.open);
          if (i >= 0 && (bestIdx < 0 || i < bestIdx)) {
            bestIdx = i;
            best = m;
          }
        }
        if (bestIdx >= 0) {
          out.write(_buf.substring(0, bestIdx));
          _buf = _buf.substring(bestIdx + best!.open.length);
          _capturing = true;
          _active = best;
          continue;
        }
        // 부분 여는 태그일 수 있는 접미(어떤 마커든)는 남기고 나머지를 내보낸다.
        final keep = _maxPartialOpenSuffix(_buf);
        out.write(_buf.substring(0, _buf.length - keep));
        _buf = _buf.substring(_buf.length - keep);
        break;
      } else {
        final close = _active!.close;
        final j = _buf.indexOf(close);
        if (j >= 0) {
          _cap += _buf.substring(0, j);
          _captured.add(_Captured(_active!, _cap));
          _cap = '';
          _buf = _buf.substring(j + close.length);
          _capturing = false;
          _active = null;
          continue;
        }
        // 부분 닫는 태그일 수 있는 접미는 남기고 나머지를 캡처에 모은다.
        final keep = _partialSuffix(_buf, close);
        _cap += _buf.substring(0, _buf.length - keep);
        _buf = _buf.substring(_buf.length - keep);
        break;
      }
    }
    return out.toString();
  }

  /// 스트림 끝. 닫히지 않은 캡처는 도구 호출이 아니라고 보고 텍스트로 되돌린다
  /// (내용 유실 방지).
  String finish() {
    if (_capturing) {
      final leftover = '${_active!.open}$_cap$_buf';
      _cap = '';
      _buf = '';
      _capturing = false;
      _active = null;
      return leftover;
    }
    final out = _buf;
    _buf = '';
    return out;
  }

  /// 추출된 도구 호출들을 [ToolCall] 로 변환.
  /// 파싱 실패하거나 [knownNames] 에 없는 이름은 건너뛴다(→ [unparsedAsText] 로 복원).
  List<ToolCall> toolCalls() {
    final result = <ToolCall>[];
    for (var k = 0; k < _captured.length; k++) {
      final call = _asCall(_captured[k].body, 'call_$k');
      if (call != null) result.add(call);
    }
    return result;
  }

  /// 도구 호출로 인정되지 못한(파싱 실패/미지 이름) 캡처 블록을 원래 마커째 텍스트로
  /// 복원해 돌려준다. 캡처 중 가려졌던 내용이 유실되지 않게 하기 위함.
  String unparsedAsText() {
    final b = StringBuffer();
    for (final c in _captured) {
      if (_asCall(c.body, 'x') == null) {
        b.write('${c.marker.open}${c.body}${c.marker.close}');
      }
    }
    return b.toString();
  }

  /// 캡처 본문을 (게이팅 통과한) [ToolCall] 로. 아니면 null.
  ToolCall? _asCall(String body, String id) {
    final parsed = _parseCall(body);
    if (parsed == null) return null;
    final name = _resolveName(parsed.$1);
    if (name == null) return null;
    return ToolCall(id: id, name: name, arguments: parsed.$2);
  }

  /// [knownNames] 게이팅 + 네임스페이스 정규화. 통과 못 하면 null.
  String? _resolveName(String raw) {
    final known = _knownNames;
    if (known == null) return raw;
    if (known.contains(raw)) return raw;
    final i = raw.lastIndexOf(':');
    if (i >= 0) {
      final tail = raw.substring(i + 1);
      if (known.contains(tail)) return tail;
    }
    return null;
  }

  /// 캡처 본문 한 개를 (도구 이름, arguments JSON 문자열)로 파싱. 두 형식을 받는다:
  ///  (a) JSON 오브젝트: `{"name":..,"arguments":{..}}`   — 프롬프트 폴백 계약.
  ///  (b) 인라인 호출:   `call:<name>{<args>}` / `<name>(<args>)` — 일부 로컬 모델.
  /// `call:` 접두어·코드펜스를 벗기고, args 는 느슨한(JSON5류) 표기도 받는다
  /// (따옴표 없는 키, 작은따옴표 문자열 등).
  static (String, String)? _parseCall(String raw) {
    var s = raw.trim();
    if (s.length >= 5 && s.substring(0, 5).toLowerCase() == 'call:') {
      s = s.substring(5).trim();
    }
    if (s.startsWith('```')) {
      final nl = s.indexOf('\n');
      if (nl >= 0) s = s.substring(nl + 1);
      if (s.endsWith('```')) s = s.substring(0, s.length - 3);
      s = s.trim();
    }
    if (s.isEmpty) return null;

    // (a) JSON 오브젝트 형태: {"name":..,"arguments":..}
    if (s.startsWith('{')) {
      final obj = relaxedJsonValue(s);
      if (obj is! Map) return null;
      final name = obj['name'];
      if (name is! String || name.isEmpty) return null;
      final args = obj['arguments'] ?? obj['parameters'];
      final argStr =
          args == null ? '{}' : (args is String ? args : jsonEncode(args));
      return (name, argStr);
    }

    // (b) 인라인 형태: <name>{...} 또는 <name>(...)
    final brace = s.indexOf('{');
    final paren = s.indexOf('(');
    int cut;
    bool isParen;
    if (brace >= 0 && (paren < 0 || brace < paren)) {
      cut = brace;
      isParen = false;
    } else if (paren >= 0) {
      cut = paren;
      isParen = true;
    } else {
      cut = -1;
      isParen = false;
    }
    final name = (cut < 0 ? s : s.substring(0, cut)).trim();
    if (name.isEmpty) return null;
    if (cut < 0) return (name, '{}'); // 인자 없는 호출
    var argText = s.substring(cut).trim();
    if (isParen && argText.startsWith('(') && argText.endsWith(')')) {
      // (a=1, b='x') → {a:1, b:'x'} 로 감싸 느슨 파서에 태운다.
      argText = '{${argText.substring(1, argText.length - 1)}}';
    }
    final parsedArgs = relaxedJsonValue(argText);
    if (parsedArgs is Map) return (name, jsonEncode(parsedArgs));
    return (name, '{}');
  }

  /// 아직 완성되지 않은 여는 마커의 접미를 얼마나 남겨둘지(모든 마커 중 최대).
  int _maxPartialOpenSuffix(String s) {
    var keep = 0;
    for (final m in _markers) {
      final k = _partialSuffix(s, m.open);
      if (k > keep) keep = k;
    }
    return keep;
  }

  /// [s] 의 접미사 중 [marker] 의 접두사와 일치하는 가장 긴 길이(< marker 길이).
  static int _partialSuffix(String s, String marker) {
    final max = s.length < marker.length - 1 ? s.length : marker.length - 1;
    for (var k = max; k > 0; k--) {
      if (s.substring(s.length - k) == marker.substring(0, k)) return k;
    }
    return 0;
  }
}

class _Captured {
  _Captured(this.marker, this.body);
  final ToolMarker marker;
  final String body;
}

/// [tools](OpenAI function 스키마)에서 도구 이름 집합을 뽑는다(오탐 게이팅용).
/// 비어 있으면 null(게이팅 안 함).
Set<String>? knownToolNames(List<Map<String, Object?>>? tools) {
  if (tools == null || tools.isEmpty) return null;
  final names = <String>{};
  for (final t in tools) {
    final fn = (t['function'] as Map?)?.cast<String, Object?>();
    final name = fn?['name'];
    if (name is String && name.isNotEmpty) names.add(name);
  }
  return names.isEmpty ? null : names;
}

/// 느슨한 JSON(JSON5 유사) 값 파서: 따옴표 없는 키, 작은따옴표 문자열, 후행 콤마,
/// 따옴표 없는 스칼라를 허용한다(표준 JSON 도 당연히 그대로 파싱). 실패 시 null.
Object? relaxedJsonValue(String src) {
  try {
    final p = _RelaxedParser(src);
    p._ws();
    final v = p._value();
    p._ws();
    if (!p._atEnd) return null; // 뒤에 잉여가 있으면 실패로 본다.
    return v;
  } catch (_) {
    return null;
  }
}

class _RelaxedParser {
  _RelaxedParser(this.s);
  final String s;
  int i = 0;

  bool get _atEnd => i >= s.length;

  void _ws() {
    while (!_atEnd) {
      final ch = s[i];
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        i++;
      } else {
        break;
      }
    }
  }

  Object? _value() {
    _ws();
    if (_atEnd) throw const FormatException('eof');
    final ch = s[i];
    if (ch == '{') return _object();
    if (ch == '[') return _array();
    if (ch == '"' || ch == "'") return _string(ch);
    return _scalar();
  }

  Map<String, Object?> _object() {
    final m = <String, Object?>{};
    i++; // {
    _ws();
    if (!_atEnd && s[i] == '}') {
      i++;
      return m;
    }
    while (true) {
      _ws();
      final key = _key();
      _ws();
      if (_atEnd || s[i] != ':') throw const FormatException('expected :');
      i++; // :
      m[key] = _value();
      _ws();
      if (_atEnd) throw const FormatException('unterminated object');
      if (s[i] == ',') {
        i++;
        _ws();
        if (!_atEnd && s[i] == '}') {
          i++;
          return m;
        }
        continue;
      }
      if (s[i] == '}') {
        i++;
        return m;
      }
      throw const FormatException('expected , or }');
    }
  }

  List<Object?> _array() {
    final list = <Object?>[];
    i++; // [
    _ws();
    if (!_atEnd && s[i] == ']') {
      i++;
      return list;
    }
    while (true) {
      list.add(_value());
      _ws();
      if (_atEnd) throw const FormatException('unterminated array');
      if (s[i] == ',') {
        i++;
        _ws();
        if (!_atEnd && s[i] == ']') {
          i++;
          return list;
        }
        continue;
      }
      if (s[i] == ']') {
        i++;
        return list;
      }
      throw const FormatException('expected , or ]');
    }
  }

  String _key() {
    _ws();
    if (_atEnd) throw const FormatException('expected key');
    final ch = s[i];
    if (ch == '"' || ch == "'") return _string(ch);
    final start = i;
    while (!_atEnd) {
      final c = s[i];
      if (c == ':' || c == ' ' || c == '\t' || c == '\n' || c == '\r') break;
      i++;
    }
    if (i == start) throw const FormatException('empty key');
    return s.substring(start, i);
  }

  String _string(String quote) {
    i++; // 여는 따옴표
    final sb = StringBuffer();
    while (!_atEnd) {
      final ch = s[i];
      if (ch == '\\') {
        i++;
        if (_atEnd) break;
        final e = s[i];
        switch (e) {
          case 'n':
            sb.write('\n');
            break;
          case 't':
            sb.write('\t');
            break;
          case 'r':
            sb.write('\r');
            break;
          case 'b':
            sb.writeCharCode(8);
            break;
          case 'f':
            sb.writeCharCode(12);
            break;
          case 'u':
            if (i + 4 < s.length) {
              final code = int.tryParse(s.substring(i + 1, i + 5), radix: 16);
              if (code != null) {
                sb.writeCharCode(code);
                i += 4;
              }
            }
            break;
          default:
            sb.write(e);
        }
        i++;
        continue;
      }
      if (ch == quote) {
        i++;
        return sb.toString();
      }
      sb.write(ch);
      i++;
    }
    throw const FormatException('unterminated string');
  }

  Object? _scalar() {
    final start = i;
    while (!_atEnd) {
      final c = s[i];
      if (c == ',' || c == '}' || c == ']') break;
      i++;
    }
    final tok = s.substring(start, i).trim();
    if (tok.isEmpty) throw const FormatException('empty scalar');
    if (tok == 'true') return true;
    if (tok == 'false') return false;
    if (tok == 'null') return null;
    final n = num.tryParse(tok);
    if (n != null) return n;
    return tok; // 따옴표 없는 문자열
  }
}
