import 'package:flutter_test/flutter_test.dart';
import 'package:aira/core/sse.dart';

void main() {
  test('emits complete frames across arbitrary chunk boundaries', () {
    final decoder = SseDecoder();
    expect(decoder.feed('data: {"a":1}\n\ndata: [DO'), isEmpty);
    final events = decoder.feed('NE]\n\n');
    expect(events, hasLength(2));
    expect(events.first.data, '{"a":1}');
    expect(events.last.data, '[DONE]');
  });

  test('handles CRLF, comments and named events', () {
    final decoder = SseDecoder();
    final events = decoder.feed(': keepalive\r\nevent: message\r\ndata: hi\r\n\r\n');
    expect(events, hasLength(1));
    expect(events.single.event, 'message');
    expect(events.single.data, 'hi');
  });

  test('joins multi-line data fields', () {
    final decoder = SseDecoder();
    final events = decoder.feed('data: first\ndata: second\n\n');
    expect(events.single.data, 'first\nsecond');
  });
}
