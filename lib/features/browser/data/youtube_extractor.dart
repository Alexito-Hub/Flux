import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' hide VideoType;
import '../domain/video_classifier.dart';

class YouTubeExtractor {
  static final _yt = YoutubeExplode();

  static bool isYouTubeUrl(String url) {
    return url.contains('youtube.com/watch') || url.contains('youtu.be/');
  }

  /// Extrae el video de YouTube usando youtube_explode_dart
  static Future<ClassifiedVideo?> extractVideo(String url) async {
    try {
      // 1. Obtener ID del video
      final videoId = VideoId.parseVideoId(url);
      if (videoId == null) return null;

      // 2. Obtener metadatos
      final video = await _yt.videos.get(videoId);
      
      // 3. Obtener el manifiesto de streams
      final manifest = await _yt.videos.streamsClient.getManifest(videoId);
      
      // Buscar stream combinado (Muxed) de mayor calidad (Video + Audio)
      final muxed = manifest.muxed.sortByVideoQuality().toList();
      if (muxed.isEmpty) return null; // No hay stream jugable directamente
      
      final bestStream = muxed.first;
      
      // Obtener resolución de calidad, ej: "720p" -> 720
      int? height;
      if (bestStream.videoQuality.name.contains('p')) {
         final parsed = int.tryParse(bestStream.videoQuality.name.replaceAll(RegExp(r'[^0-9]'), ''));
         if (parsed != null) height = parsed;
      }

      return ClassifiedVideo(
        url: bestStream.url.toString(),
        type: VideoType.main,
        confidence: 1.0,
        duration: video.duration?.inSeconds.toDouble(),
        width: height != null ? (height * 16 ~/ 9) : null, // Estimación 16:9
        height: height,
        source: 'youtube',
        poster: video.thumbnails.highResUrl, // Miniatura en alta calidad
        referer: url,
      );
    } catch (e) {
      debugPrint('[YouTubeExtractor] Error extrayendo $url: $e');
      return null;
    }
  }

  static void dispose() {
    _yt.close();
  }
}
