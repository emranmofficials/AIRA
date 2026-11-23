import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'app_config.dart';

/// Overridden in main() with the persisted settings, so the first frame already
/// has the correct server URL.
final initialSettingsProvider = Provider<AppSettings>(
  (_) => AppSettings.defaults,
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (_) => SettingsRepository(),
);

final settingsProvider =
    StateNotifierProvider<SettingsController, AppSettings>((ref) {
  return SettingsController(
    ref.watch(initialSettingsProvider),
    ref.watch(settingsRepositoryProvider),
  );
});

class SettingsController extends StateNotifier<AppSettings> {
  SettingsController(this._initial, this._repository) : super(_initial);

  final AppSettings _initial;
  final SettingsRepository _repository;

  Future<void> update(AppSettings next) async {
    state = next;
    await _repository.save(next);
  }

  Future<void> reset() => update(_initial);
}

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(ref.watch(settingsProvider));
  ref.onDispose(client.dispose);
  return client;
});
