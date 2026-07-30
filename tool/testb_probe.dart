// Test B de la investigación del 403-en-bytes (docs/investigacion_muro_antibot.md).
//
// Test A (test/ua_test2.dart, ya eliminado tras esta corrida) mostró: manifest
// sano, UA de bytes = main (Pixel 5 / Chrome 120), y aun así 403 en bytes, 2/2.
// Eso descarta el UA como causa aislada. La única variable de `main` que
// quedaba sin probar era la cascada de clientes del manifest: main pide
// [androidVr, safari] (con fallback a getManifest sin ytClients), esta rama
// pedía [android, androidSdkless, ambos] con requireWatchPage: false.
//
// Resultado (2026-07-29): 2/2 HTTP 206 con [androidVr, safari] + mismo UA,
// mismos vídeos que dieron 403 en Test A. Promovido a fix real en
// `YoutubeService._clientFallbacks` (ahora [androidVr, safari] primero).
//
// Reusa los mismos 2 vídeos de Test A a propósito: su manifest ya se confirmó
// sano en esa corrida, así que la única variable que cambia acá es el cliente
// del manifest — no el vídeo.
//
// Uso: dart run tool/testb_probe.dart
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const _videos = <String, String>{
  '7CUz7Ec7cWc': 'Ariana Grande — hate that i made you love me',
  'XZ868t23Pb4': 'Ariana Grande — 7 rings',
};

const _bytesUserAgent =
    'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

void _addHeaders(HttpClientRequest request) {
  request.headers.add('User-Agent', _bytesUserAgent);
  request.headers.add('Accept', '*/*');
  request.headers.add('Accept-Language', 'en-US,en;q=0.9');
  request.headers.add('Origin', 'https://www.youtube.com');
  request.headers.add('Referer', 'https://www.youtube.com/');
}

Future<void> main() async {
  for (final e in _videos.entries) {
    final yt = YoutubeExplode();
    print('\n=== ${e.key}  ${e.value} ===');
    try {
      StreamManifest manifest;
      try {
        manifest = await yt.videos.streamsClient.getManifest(
          VideoId(e.key),
          ytClients: [YoutubeApiClient.androidVr, YoutubeApiClient.safari],
        );
        print('  manifest OK con [androidVr, safari]');
      } catch (err) {
        print('  [androidVr, safari] falló: $err — probando fallback default');
        manifest = await yt.videos.streamsClient.getManifest(VideoId(e.key));
        print('  manifest OK con default');
      }

      final audio = manifest.audioOnly.toList();
      if (audio.isEmpty) {
        print('  sin streams audio-only');
        continue;
      }
      final best = audio.reduce(
          (a, b) => a.bitrate.bitsPerSecond > b.bitrate.bitsPerSecond ? a : b);
      print('  itag ${best.tag}  ${best.container.name}  '
          '${(best.bitrate.bitsPerSecond / 1000).round()}kbps');

      final client = HttpClient();
      try {
        final request = await client.getUrl(best.url);
        _addHeaders(request);
        request.headers.add('Range', 'bytes=0-${3 * 1024 * 1024 - 1}');
        final sw = Stopwatch()..start();
        final response = await request.close();
        var received = 0;
        await for (final chunk in response) {
          received += chunk.length;
        }
        sw.stop();
        print('  HTTP ${response.statusCode} · ${(received / 1024).toStringAsFixed(0)}KB '
            'en ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
      } catch (err) {
        print('  descarga de bytes FALLÓ: $err');
      } finally {
        client.close();
      }
    } catch (err) {
      print('  error general: $err');
    } finally {
      yt.close();
    }
  }
}
