/// Minimal Server-Sent Events decoder.
///
/// OpenJarvis streams chat completions as standard SSE: `data: {json}\n\n`
/// frames terminated by `data: [DONE]`. HTTP chunk boundaries do not line up
/// with frame boundaries, so bytes are fed in as they arrive and complete
/// frames are emitted only once the blank separator line is seen.
class SseEvent {
  const SseEvent({required this.data, this.event});

  final String data;
  final String? event;

  @override
  String toString() => 'SseEvent(event: $event, data: $data)';
}

class SseDecoder {
  final StringBuffer _buffer = StringBuffer();

  /// Feed a newly received text chunk and return all complete events.
  List<SseEvent> feed(String chunk) {
    _buffer.write(chunk.replaceAll('\r\n', '\n'));
    final text = _buffer.toString();
    final events = <SseEvent>[];
    var cursor = 0;

    while (true) {
      final separator = text.indexOf('\n\n', cursor);
      if (separator == -1) break;
      final block = text.substring(cursor, separator);
      cursor = separator + 2;
      final parsed = _parseBlock(block);
      if (parsed != null) events.add(parsed);
    }

    _buffer.clear();
    if (cursor < text.length) _buffer.write(text.substring(cursor));
    return events;
  }

  SseEvent? _parseBlock(String block) {
    final dataLines = <String>[];
    String? event;
    for (final line in block.split('\n')) {
      if (line.isEmpty || line.startsWith(':')) continue;
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      } else if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      }
    }
    if (dataLines.isEmpty) return null;
    return SseEvent(data: dataLines.join('\n'), event: event);
  }
}
