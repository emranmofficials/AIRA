import 'dart:convert';

import 'sse.dart' as sse;

enum MessageRole { system, user, assistant, tool }

extension MessageRoleX on MessageRole {
  String get wireName => name;
}

class ToolCallInfo {
  const ToolCallInfo({
    required this.index,
    this.id,
    this.name,
    this.arguments = '',
  });

  final int index;
  final String? id;
  final String? name;
  final String arguments;

  static List<ToolCallInfo> fromJsonList(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<Map<String, dynamic>>().map((raw) {
      final fn = (raw['function'] is Map)
          ? Map<String, dynamic>.from(raw['function'] as Map)
          : const <String, dynamic>{};
      return ToolCallInfo(
        index: (raw['index'] as num?)?.toInt() ?? 0,
        id: raw['id'] as String?,
        name: fn['name'] as String?,
        arguments: fn['arguments'] as String? ?? '',
      );
    }).toList();
  }
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.toolCalls = const [],
    this.streaming = false,
    this.failed = false,
  });

  final String id;
  final MessageRole role;
  final String content;
  final DateTime createdAt;
  final List<ToolCallInfo> toolCalls;
  final bool streaming;
  final bool failed;

  ChatMessage copyWith({
    String? content,
    List<ToolCallInfo>? toolCalls,
    bool? streaming,
    bool? failed,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      createdAt: createdAt,
      toolCalls: toolCalls ?? this.toolCalls,
      streaming: streaming ?? this.streaming,
      failed: failed ?? this.failed,
    );
  }

  Map<String, dynamic> toJson() => {
        'role': role.wireName,
        'content': content,
      };
}

class ChatChunk {
  const ChatChunk({
    this.content = '',
    this.toolCalls = const [],
    this.finishReason,
    this.usage,
  });

  final String content;
  final List<ToolCallInfo> toolCalls;
  final String? finishReason;
  final Map<String, dynamic>? usage;

  bool get isEmpty =>
      content.isEmpty && toolCalls.isEmpty && finishReason == null && usage == null;

  static ChatChunk fromSse(sse.SseEvent event) {
    if (event.data == '[DONE]') return const ChatChunk(finishReason: 'done');
    final decoded = _decode(event.data);
    if (decoded == null) return const ChatChunk();
    final choices = decoded['choices'];
    String content = '';
    List<ToolCallInfo> toolCalls = const [];
    String? finishReason;
    if (choices is List && choices.isNotEmpty) {
      final choice = choices.first;
      if (choice is Map<String, dynamic>) {
        final delta = choice['delta'];
        if (delta is Map<String, dynamic>) {
          content = delta['content'] as String? ?? '';
          toolCalls = ToolCallInfo.fromJsonList(delta['tool_calls']);
        }
        finishReason = choice['finish_reason'] as String?;
      }
    }
    final rawUsage = decoded['usage'];
    return ChatChunk(
      content: content,
      toolCalls: toolCalls,
      finishReason: finishReason,
      usage: rawUsage is Map<String, dynamic> ? rawUsage : null,
    );
  }

  static Map<String, dynamic>? _decode(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

class MemoryFact {
  const MemoryFact({
    required this.content,
    this.score = 0,
    this.metadata = const {},
  });

  final String content;
  final double score;
  final Map<String, dynamic> metadata;

  static List<MemoryFact> fromJsonList(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<Map<String, dynamic>>().map((raw) {
      return MemoryFact(
        content: raw['content'] as String? ?? '',
        score: (raw['score'] as num?)?.toDouble() ?? 0,
        metadata: raw['metadata'] is Map
            ? Map<String, dynamic>.from(raw['metadata'] as Map)
            : const {},
      );
    }).toList();
  }
}

class ManagedAgent {
  ManagedAgent({
    required this.id,
    required this.name,
    this.agentType = 'monitor_operative',
    this.scheduleType = 'manual',
    this.scheduleValue = '',
    this.status = 'idle',
    this.instruction = '',
  });

  final String id;
  final String name;
  final String agentType;
  final String scheduleType;
  final String scheduleValue;
  final String status;
  final String instruction;

  static List<ManagedAgent> fromJsonList(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<Map<String, dynamic>>().map((raw) {
      final config = raw['config'] is Map
          ? Map<String, dynamic>.from(raw['config'] as Map)
          : const <String, dynamic>{};
      return ManagedAgent(
        id: raw['id'] as String? ?? '',
        name: raw['name'] as String? ?? 'Untitled',
        agentType: raw['agent_type'] as String? ?? 'monitor_operative',
        scheduleType: config['schedule_type'] as String? ?? 'manual',
        scheduleValue: (config['schedule_value'] ?? '').toString(),
        status: raw['status'] as String? ?? 'idle',
        instruction: config['instruction'] as String? ?? '',
      );
    }).toList();
  }

  String get scheduleLabel {
    switch (scheduleType) {
      case 'cron':
        return 'cron: $scheduleValue';
      case 'interval':
        return 'every ${scheduleValue}s';
      default:
        return 'manual';
    }
  }
}
