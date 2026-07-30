// Cobertura del fallback de `YTMusicService.searchAndDownload` a
// `YoutubeService.searchAndDownload` (youtube_explode_dart), sin pegarle a la
// red. Ver docs/investigacion_muro_antibot.md: `yt.search.search()` de
// youtube_explode_dart 3.1.0 tiene un bug de librería reproducible
// (NoSuchMethodError al parsear viewCountText en formato "runs"), y antes de
// esta sesión TODA descarga de Spotify dependía en exclusiva de esa búsqueda
// rota, sin ningún fallback.
//
// Usa los hooks `@visibleForTesting` de `YTMusicService`
// (`searchSongsOverrideForTesting` / `fallbackSearchAndDownloadOverrideForTesting`)
// para forzar un NoSuchMethodError real (invocando dinámicamente un método que
// no existe, igual que el bug real de la librería) y confirmar que se llega
// al fallback — sin tocar InnerTube ni youtube_explode_dart de verdad.
import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/ytmusic_service.dart';

void main() {
  test('cae al fallback de youtube_explode_dart cuando InnerTube tira NoSuchMethodError', () async {
    final service = YTMusicService();
    var fallbackCalled = false;
    String? fallbackQueryTitle;

    service.searchSongsOverrideForTesting = (query) async {
      // Mismo tipo de error que el bug real: invocación dinámica a un método
      // que no existe (ver search_page.dart:181 en youtube_explode_dart).
      final dynamic broken = <String, dynamic>{};
      return broken.getT();
    };

    service.fallbackSearchAndDownloadOverrideForTesting = ({
      required String title,
      required String artist,
      required int expectedDurationMs,
      String? spotifyThumbnailUrl,
      void Function(String title)? onMetadata,
      void Function(double)? onProgress,
      void Function(String phase)? onPhase,
      bool Function()? isCancelled,
    }) async {
      fallbackCalled = true;
      fallbackQueryTitle = title;
      return <String, dynamic>{
        'videoId': 'fakeFallbackId',
        'title': title,
        'artist': artist,
        'filePath': '/fake/path.m4a',
      };
    };

    final result = await service.searchAndDownload(
      title: 'Test Song',
      artist: 'Test Artist',
      expectedDurationMs: 200000,
    );

    expect(fallbackCalled, isTrue,
        reason: 'un NoSuchMethodError en la búsqueda de InnerTube debería degradar al fallback');
    expect(fallbackQueryTitle, 'Test Song');
    expect(result['videoId'], 'fakeFallbackId');
  });

  test('un Exception cualquiera de InnerTube también degrada al fallback', () async {
    final service = YTMusicService();
    var fallbackCalled = false;

    service.searchSongsOverrideForTesting = (query) async {
      throw Exception('InnerTube no devolvió resultados para "$query"');
    };
    service.fallbackSearchAndDownloadOverrideForTesting = ({
      required String title,
      required String artist,
      required int expectedDurationMs,
      String? spotifyThumbnailUrl,
      void Function(String title)? onMetadata,
      void Function(double)? onProgress,
      void Function(String phase)? onPhase,
      bool Function()? isCancelled,
    }) async {
      fallbackCalled = true;
      return <String, dynamic>{'videoId': 'fakeFallbackId2'};
    };

    await service.searchAndDownload(
      title: 'Test Song 3',
      artist: 'Test Artist 3',
      expectedDurationMs: 200000,
    );

    expect(fallbackCalled, isTrue);
  });
}
