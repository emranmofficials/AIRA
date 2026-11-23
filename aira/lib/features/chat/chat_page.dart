import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../shared/adaptive_shell.dart';
import '../voice/voice_service.dart';
import 'chat_controller.dart';
import 'widgets/message_bubble.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final VoiceService _voice;
  List<String> _models = const [];
  bool _loadingModels = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _voice = VoiceService();
    unawaited(_loadModels());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    unawaited(_voice.dispose());
    super.dispose();
  }

  Future<void> _loadModels() async {
    try {
      final models = await ref.read(apiClientProvider).listModels();
      if (mounted) setState(() => _models = models);
    } on ApiException {
      // Settings page has an explicit connection test; stay quiet here.
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _send([String? override]) async {
    final text = (override ?? _input.text).trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    setState(() => _busy = true);

    final settings = ref.read(settingsProvider);
    await ref.read(chatControllerProvider.notifier).send(
          text,
          model: settings.model.isEmpty ? null : settings.model,
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (settings.autoSpeak) {
      final messages = ref.read(chatControllerProvider);
      for (final message in messages.reversed) {
        if (message.role == MessageRole.assistant &&
            !message.failed &&
            message.content.isNotEmpty) {
          await _speak(message.content);
          break;
        }
      }
    }
  }

  Future<void> _speak(String text) async {
    try {
      final bytes = await ref.read(apiClientProvider).synthesize(
            text: text,
            voiceId: ref.read(settingsProvider).voiceId,
            speed: ref.read(settingsProvider).speechRate,
          );
      await _voice.speak(bytes);
    } on ApiException catch (e) {
      if (mounted) _snack('Voice output unavailable: $e');
    }
  }

  Future<void> _toggleRecording() async {
    try {
      if (_voice.isRecording) {
        final path = await _voice.stopRecording();
        setState(() {});
        if (path == null || path.isEmpty) {
          _snack('No audio captured');
          return;
        }
        _snack('Transcribing…');
        final settings = ref.read(settingsProvider);
        final text = await _voice.transcribe(
          ref.read(apiClientProvider),
          path: path,
          language: settings.language,
        );
        if (text.trim().isEmpty) {
          _snack('Nothing recognized');
          return;
        }
        await _send(text);
      } else {
        await _voice.startRecording();
        setState(() {});
        _snack('Listening… tap the mic again to finish');
      }
    } on ApiException catch (e) {
      _snack('Speech error: $e');
    } on VoiceException catch (e) {
      _snack(e.message);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatControllerProvider);
    final settings = ref.watch(settingsProvider);
    final modelValue = _models.contains(settings.model) ? settings.model : '';

    if (messages.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }

    return AdaptiveShell(
      selectedIndex: 0,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AIRA'),
          actions: [
            SizedBox(
              width: 200,
              child: DropdownButton<String>(
                value: modelValue,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('Server default model'),
                  ),
                  for (final model in _models)
                    DropdownMenuItem(value: model, child: Text(model)),
                ],
                onChanged: _loadingModels
                    ? null
                    : (value) {
                        if (value == null) return;
                        unawaited(
                          ref.read(settingsProvider.notifier).update(
                                settings.copyWith(model: value),
                              ),
                        );
                      },
              ),
            ),
            IconButton(
              tooltip: 'Clear conversation',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => ref.read(chatControllerProvider.notifier).clear(),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: messages.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.smart_toy_outlined,
                              size: 64,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'What can I help with?',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Chat, speak, call tools, remember facts and schedule work —\n'
                              'powered by your OpenJarvis server.',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 20),
                            Wrap(
                              spacing: 8,
                              children: [
                                for (final suggestion in [
                                  'বাংলায় একটা গল্প বলো',
                                  'Explain this repo',
                                  'What did I ask you to remember?',
                                ])
                                  ActionChip(
                                    label: Text(suggestion),
                                    onPressed: () => _send(suggestion),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      itemCount: messages.length,
                      itemBuilder: (context, index) =>
                          MessageBubble(message: messages[index]),
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: _voice.isRecording ? 'Stop and transcribe' : 'Voice input',
                      icon: Icon(
                        _voice.isRecording ? Icons.stop_circle : Icons.mic_none,
                        color: _voice.isRecording ? Colors.red : null,
                      ),
                      onPressed: _toggleRecording,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 6,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          hintText: 'Message AIRA…',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _busy ? null : () => _send(),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
