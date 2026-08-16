import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferencias de comportamiento, persistidas entre sesiones.
class AppSettings {
  const AppSettings({this.autoPlay = true, this.followSource = true});

  /// Abrir automáticamente el primer stream encontrado al iniciar la app.
  /// Solo dispara una vez por arranque: después, la elección es del usuario.
  final bool autoPlay;

  /// Seguir la emisión: si cambias de capítulo en el teléfono, Flux carga el
  /// nuevo sin que tengas que volver atrás ni buscar otra vez.
  final bool followSource;

  AppSettings copyWith({bool? autoPlay, bool? followSource}) => AppSettings(
        autoPlay: autoPlay ?? this.autoPlay,
        followSource: followSource ?? this.followSource,
      );
}

class SettingsController extends Notifier<AppSettings> {
  static const _autoPlayKey = 'flux.autoplay';
  static const _followKey = 'flux.follow_source';

  @override
  AppSettings build() {
    // Se devuelven los valores por defecto y se corrigen en cuanto termina la
    // lectura del disco: así la primera pantalla no espera a nada.
    _load();
    return const AppSettings();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    state = AppSettings(
      autoPlay: prefs.getBool(_autoPlayKey) ?? true,
      followSource: prefs.getBool(_followKey) ?? true,
    );
  }

  Future<void> setAutoPlay(bool value) async {
    state = state.copyWith(autoPlay: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPlayKey, value);
  }

  Future<void> setFollowSource(bool value) async {
    state = state.copyWith(followSource: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_followKey, value);
  }
}

final settingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
