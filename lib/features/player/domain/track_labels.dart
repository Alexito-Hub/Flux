import 'package:media_kit/media_kit.dart';

/// Nombres legibles para las pistas de audio y subtítulos.
///
/// Un MKV típico trae `id: "2", title: null, language: "spa"`, que en crudo no
/// le dice nada a nadie. Aquí eso se convierte en "Español".
abstract final class TrackLabels {
  static const _languages = <String, String>{
    'spa': 'Español', 'es': 'Español', 'esp': 'Español',
    'eng': 'Inglés', 'en': 'Inglés',
    'fre': 'Francés', 'fra': 'Francés', 'fr': 'Francés',
    'ger': 'Alemán', 'deu': 'Alemán', 'de': 'Alemán',
    'ita': 'Italiano', 'it': 'Italiano',
    'por': 'Portugués', 'pt': 'Portugués',
    'jpn': 'Japonés', 'ja': 'Japonés',
    'kor': 'Coreano', 'ko': 'Coreano',
    'chi': 'Chino', 'zho': 'Chino', 'zh': 'Chino',
    'rus': 'Ruso', 'ru': 'Ruso',
    'cat': 'Catalán', 'ca': 'Catalán',
    'glg': 'Gallego', 'eus': 'Euskera', 'baq': 'Euskera',
    'ara': 'Árabe', 'ar': 'Árabe',
    'hin': 'Hindi', 'tur': 'Turco', 'pol': 'Polaco',
    'nld': 'Neerlandés', 'dut': 'Neerlandés',
    'swe': 'Sueco', 'nor': 'Noruego', 'dan': 'Danés', 'fin': 'Finés',
    'ces': 'Checo', 'cze': 'Checo', 'ell': 'Griego', 'gre': 'Griego',
    'heb': 'Hebreo', 'tha': 'Tailandés', 'vie': 'Vietnamita',
    'ind': 'Indonesio', 'ukr': 'Ucraniano', 'ron': 'Rumano', 'hun': 'Húngaro',
  };

  static String? language(String? code) {
    if (code == null || code.isEmpty) return null;
    return _languages[code.toLowerCase()] ?? code.toUpperCase();
  }

  static String audio(AudioTrack track, int index) {
    if (track.id == 'auto') return 'Automático';
    if (track.id == 'no') return 'Sin audio';
    return _compose(track.title, track.language, 'Pista de audio $index');
  }

  static String subtitle(SubtitleTrack track, int index) {
    if (track.id == 'auto') return 'Automático';
    if (track.id == 'no') return 'Desactivados';
    return _compose(track.title, track.language, 'Subtítulo $index');
  }

  /// Prioriza el título que puso quien creó el archivo ("Castellano Forzados"),
  /// y cae al idioma solo si no hay título.
  static String _compose(String? title, String? language, String fallback) {
    final named = title?.trim();
    final lang = TrackLabels.language(language);
    if (named != null && named.isNotEmpty) {
      if (lang != null && !named.toLowerCase().contains(lang.toLowerCase())) {
        return '$named · $lang';
      }
      return named;
    }
    return lang ?? fallback;
  }
}
