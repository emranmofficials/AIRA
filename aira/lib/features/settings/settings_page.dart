import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/providers.dart';
import '../../shared/adaptive_shell.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _server;
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _language;
  late final TextEditingController _voice;
  late final TextEditingController _rate;
  late bool _autoSpeak;
  String? _testResult;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _server = TextEditingController(text: s.serverUrl);
    _key = TextEditingController(text: s.apiKey);
    _model = TextEditingController(text: s.model);
    _language = TextEditingController(text: s.language);
    _voice = TextEditingController(text: s.voiceId);
    _rate = TextEditingController(text: s.speechRate.toString());
    _autoSpeak = s.autoSpeak;
  }

  @override
  void dispose() {
    for (final c in [_server, _key, _model, _language, _voice, _rate]) {
      c.dispose();
    }
    super.dispose();
  }

  AppSettings _buildSettings() {
    final current = ref.read(settingsProvider);
    return current.copyWith(
      serverUrl: _server.text.trim(),
      apiKey: _key.text.trim(),
      model: _model.text.trim(),
      language: _language.text.trim().isEmpty ? 'bn' : _language.text.trim(),
      voiceId: _voice.text.trim(),
      speechRate: double.tryParse(_rate.text.trim()) ?? 1.0,
      autoSpeak: _autoSpeak,
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    await ref.read(settingsProvider.notifier).update(_buildSettings());
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    // A fresh client is needed because base URL/key live in Dio options.
    final client = ApiClient(_buildSettings());
    try {
      await client.health();
      final models = await client.listModels();
      if (mounted) {
        setState(() => _testResult = 'Connected · ${models.length} model(s) available');
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _testResult = 'Failed: $e');
    } finally {
      client.dispose();
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveShell(
      selectedIndex: 3,
      child: Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'OpenJarvis server',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _server,
                  labelText: 'Server URL',
                  keyboardType: TextInputType.url,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Required'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _key,
                  labelText: 'API key (optional)',
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _model,
                  labelText: 'Model (blank = server default)',
                ),
                const SizedBox(height: 24),
                Text(
                  'Voice',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Speak replies automatically'),
                  value: _autoSpeak,
                  onChanged: (v) => setState(() => _autoSpeak = v),
                ),
                TextFormField(
                  controller: _language,
                  labelText: 'Speech language (e.g. bn, en)',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _voice,
                  labelText: 'TTS voice id (blank = server default)',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _rate,
                  labelText: 'Speech rate',
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: const Icon(Icons.network_check),
                      label: Text(_testing ? 'Testing…' : 'Test connection'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save'),
                    ),
                  ],
                ),
                if (_testResult != null) ...[
                  const SizedBox(height: 16),
                  Text(_testResult!),
                ],
                const SizedBox(height: 32),
                const Text(
                  'The API key is stored in the platform keystore. Tools, memory '
                  'and scheduling run on the server, not in this app.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
