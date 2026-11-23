import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aira/core/models.dart';
import 'package:aira/core/sse.dart';

void main() {
  test('parses streamed text, tool calls and finish reason', () {
    final payload = jsonEncode({
      'choices': [
        {
          'delta': {
            'content': 'Assalamu alaikum',
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_1',
                'function': {'name': 'delegate_to_openai_agent', 'arguments': '{"task":'},
              }
            ],
          },
          'finish_reason': null,
        }
      ]
    });
    final chunk = ChatChunk.fromSse(SseEvent(data: payload));
    expect(chunk.content, 'Assalamu alaikum');
    expect(chunk.toolCalls.single.name, 'delegate_to_openai_agent');
    expect(chunk.finishReason, isNull);
    expect(chunk.isEmpty, isFalse);
  });

  test('treats DONE as a terminal empty chunk', () {
    final chunk = ChatChunk.fromSse(const SseEvent(data: '[DONE]'));
    expect(chunk.finishReason, 'done');
    expect(chunk.content, isEmpty);
  });

  test('ignores malformed SSE payloads', () {
    expect(ChatChunk.fromSse(const SseEvent(data: 'not json')).isEmpty, isTrue);
  });
}
