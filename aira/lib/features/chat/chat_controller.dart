import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/providers.dart';

final chatControllerProvider =
    StateNotifierProvider<ChatController, List<ChatMessage>>((ref) {
  return ChatController(ref.watch(apiClientProvider));
});

class ChatController extends StateNotifier<List<ChatMessage>> {
  ChatController(this._api) : super(const []);

  final ApiClient _api;
  int _sequence = 0;

  String _nextId(String prefix) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';

  /// Send [text], stream the assistant reply into a live message and keep the
  /// final result in history. Failed replies are retained (marked) so the user
  /// can see what happened, but excluded from the next request's context.
  Future<void> send(String text, {String? model}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final userMessage = ChatMessage(
      id: _nextId('user'),
      role: MessageRole.user,
      content: trimmed,
      createdAt: DateTime.now(),
    );
    final assistantId = _nextId('assistant');
    state = [
      ...state,
      userMessage,
      ChatMessage(
        id: assistantId,
        role: MessageRole.assistant,
        content: '',
        createdAt: DateTime.now(),
        streaming: true,
      ),
    ];

    final context = state
        .where((m) => !m.streaming && !m.failed && m.content.isNotEmpty)
        .map((m) => m.copyWith())
        .toList();

    try {
      await for (final chunk in _api.streamChat(
        messages: context,
        model: model,
      )) {
        _patch(
          assistantId,
          (message) => message.copyWith(
            content: message.content + chunk.content,
            toolCalls: chunk.toolCalls.isEmpty
                ? message.toolCalls
                : [...message.toolCalls, ...chunk.toolCalls],
            streaming: chunk.finishReason == null,
          ),
        );
      }
      _patch(assistantId, (message) => message.copyWith(streaming: false));
    } catch (e) {
      _patch(
        assistantId,
        (message) => message.copyWith(
          content: message.content.isEmpty ? '⚠️ $e' : '${message.content}\n\n⚠️ $e',
          streaming: false,
          failed: true,
        ),
      );
    }
  }

  void clear() => state = const [];

  void _patch(String id, ChatMessage Function(ChatMessage) update) {
    state = [
      for (final message in state)
        if (message.id == id) update(message) else message,
    ];
  }
}
