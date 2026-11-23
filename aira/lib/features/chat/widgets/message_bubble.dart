import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../core/models.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final scheme = Theme.of(context).colorScheme;
    final background =
        isUser ? scheme.primaryContainer : scheme.surfaceContainerHighest;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isUser ? 16 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.toolCalls.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final call in message.toolCalls)
                      Chip(
                        avatar: const Icon(Icons.build_outlined, size: 15),
                        label: Text(call.name ?? 'tool'),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              MarkdownBody(
                data: message.content.isEmpty && message.streaming
                    ? '▍'
                    : message.content,
                selectable: true,
              ),
              if (message.failed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Reply failed — check connection',
                    style: TextStyle(color: scheme.error, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
