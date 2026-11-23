import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../shared/adaptive_shell.dart';

final agentsProvider = FutureProvider.autoDispose<List<ManagedAgent>>((ref) {
  return ref.watch(apiClientProvider).listAgents();
});

class SchedulePage extends ConsumerWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(agentsProvider);
    return AdaptiveShell(
      selectedIndex: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Scheduled agents'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(agentsProvider),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _createDialog(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('New task'),
        ),
        body: agents.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load tasks: $error',
                textAlign: TextAlign.center,
              ),
            ),
          ),
          data: (list) => list.isEmpty
              ? const Center(
                  child: Text(
                    'No scheduled agents yet.\nThe server runs them even when this app is closed.',
                    textAlign: TextAlign.center,
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () async => ref.invalidate(agentsProvider),
                  child: ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final agent = list[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        child: ListTile(
                          leading: Icon(
                            agent.status == 'paused'
                                ? Icons.pause_circle_outline
                                : Icons.play_circle_outline,
                          ),
                          title: Text(agent.name),
                          subtitle: Text(
                            '${agent.scheduleLabel} · ${agent.agentType}\n'
                            '${agent.instruction}',
                            maxLines: 2,
                          ),
                          isThreeLine: true,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: agent.status == 'paused'
                                    ? 'Resume'
                                    : 'Pause',
                                icon: Icon(
                                  agent.status == 'paused'
                                      ? Icons.play_arrow
                                      : Icons.pause,
                                ),
                                onPressed: () async {
                                  final api = ref.read(apiClientProvider);
                                  try {
                                    if (agent.status == 'paused') {
                                      await api.resumeAgent(agent.id);
                                    } else {
                                      await api.pauseAgent(agent.id);
                                    }
                                    ref.invalidate(agentsProvider);
                                  } on ApiException catch (e) {
                                    _snack(context, e.message);
                                  }
                                },
                              ),
                              IconButton(
                                tooltip: 'Delete',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text('Delete task?'),
                                          content: Text(
                                            'Remove "${agent.name}" from the server?',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, false),
                                              child: const Text('Cancel'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, true),
                                              child: const Text('Delete'),
                                            ),
                                          ],
                                        ),
                                      ) ??
                                      false;
                                  if (!confirmed) return;
                                  try {
                                    await ref
                                        .read(apiClientProvider)
                                        .deleteAgent(agent.id);
                                    ref.invalidate(agentsProvider);
                                  } on ApiException catch (e) {
                                    _snack(context, e.message);
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _createDialog(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController(text: 'Morning briefing');
    final instruction = TextEditingController(
      text: 'Summarize today\'s important news in Bengali.',
    );
    final value = TextEditingController(text: '0 9 * * *');
    String scheduleType = 'cron';

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('New scheduled task'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: instruction,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'What should it do?',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: scheduleType,
                  decoration: const InputDecoration(labelText: 'Repeat'),
                  items: const [
                    DropdownMenuItem(value: 'cron', child: Text('cron')),
                    DropdownMenuItem(value: 'interval', child: Text('interval (seconds)')),
                    DropdownMenuItem(value: 'manual', child: Text('manual')),
                  ],
                  onChanged: (v) => setState(() => scheduleType = v ?? 'cron'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: value,
                  decoration: InputDecoration(
                    labelText: scheduleType == 'cron'
                        ? 'Cron expression'
                        : 'Seconds between runs',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    if (created != true) return;
    try {
      await ref.read(apiClientProvider).createAgent(
            name: name.text.trim(),
            instruction: instruction.text.trim(),
            scheduleType: scheduleType,
            scheduleValue: value.text.trim(),
          );
      ref.invalidate(agentsProvider);
    } on ApiException catch (e) {
      if (context.mounted) _snack(context, e.message);
    }
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
