// ¿Qué clientes de InnerTube consiguen un manifest cuando YouTube está sirviendo
// el muro "Sign in to confirm you're not a bot"?
//
// Contexto: el smoke test (test/download_smoke_test.dart) demostró que el fallo
// real de descarga NO está en el paso de metadata —el priming por InnerTube de
// YTMusicService ya lo resolvió— sino en `streamsClient.getManifest`, que falla
// con VideoUnplayableException / "Sign in to confirm you're not a bot" para todos
// los clientes de la cascada actual (`android`, `androidSdkless`).
//
// youtube_explode_dart 3.1.0 expone bastantes más clientes de los que la app
// prueba. Esto los barre todos contra los mismos vídeos y dice cuáles devuelven
// streams de audio usables, para elegir la cascada con datos en vez de a ojo.
//
//   dart run tool/client_sweep_probe.dart
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// El primero funciona hoy; el segundo es el que falla de forma reproducible.
const _videos = <String, String>{
  'Rick Astley (funciona)': 'dQw4w9WgXcQ',
  'a-ha Take On Me (falla)': 'djV11Xbc914',
};

final _clients = <String, YoutubeApiClient>{
  'android': YoutubeApiClient.android,
  'androidSdkless': YoutubeApiClient.androidSdkless,
  'androidMusic': YoutubeApiClient.androidMusic,
  'androidVr': YoutubeApiClient.androidVr,
  'ios': YoutubeApiClient.ios,
  'tv': YoutubeApiClient.tv,
  // tvSimplyEmbedded y webCreator están deprecados en la librería: "Youtube always
  // requires authentication for this client". Se dejan en el barrido a
  // propósito, para tener la medición de que efectivamente no sirven.
  // ignore: deprecated_member_use
  'tvSimplyEmbedded': YoutubeApiClient.tvSimplyEmbedded,
  'mediaConnect': YoutubeApiClient.mediaConnect,
  'mweb': YoutubeApiClient.mweb,
  'safari': YoutubeApiClient.safari,
  // ignore: deprecated_member_use
  'webCreator': YoutubeApiClient.webCreator,
};

Future<void> main() async {
  final winners = <String, List<String>>{};

  for (final video in _videos.entries) {
    print('\n=== ${video.key} (${video.value}) ===');

    for (final client in _clients.entries) {
      final yt = YoutubeExplode();
      final sw = Stopwatch()..start();
      try {
        final manifest = await yt.videos.streamsClient
            .getManifest(
              VideoId(video.value),
              ytClients: [client.value],
              requireWatchPage: false,
            )
            .timeout(const Duration(seconds: 45));
        sw.stop();

        final audio = manifest.audioOnly.toList();
        if (audio.isEmpty) {
          print('  ${client.key.padRight(17)} manifest OK pero 0 streams audio');
          continue;
        }

        // Que devuelva un manifest no basta: hay que comprobar que la URL sirve
        // bytes de verdad. Un cliente puede devolver streams que dan 403 al
        // pedirlos.
        final best = audio.reduce((a, b) =>
            a.bitrate.bitsPerSecond > b.bitrate.bitsPerSecond ? a : b);
        final http = HttpClient();
        String byteCheck;
        try {
          final req = await http.getUrl(best.url);
          req.headers.add('Range', 'bytes=0-65535');
          final res = await req.close().timeout(const Duration(seconds: 20));
          var got = 0;
          await for (final c in res) {
            got += c.length;
          }
          byteCheck = 'HTTP ${res.statusCode}, ${got ~/ 1024}KB';
          if (res.statusCode == 200 || res.statusCode == 206) {
            winners.putIfAbsent(video.key, () => []).add(client.key);
          }
        } catch (e) {
          byteCheck = 'bytes FALLARON (${e.runtimeType})';
        } finally {
          http.close(force: true);
        }

        print('  ${client.key.padRight(17)} OK  ${audio.length} streams  '
            'mejor itag ${best.tag} ${best.container.name}  '
            '${sw.elapsedMilliseconds}ms  ·  $byteCheck');
      } catch (e) {
        sw.stop();
        final msg = e.toString().split('\n').first.trim();
        print('  ${client.key.padRight(17)} FALLÓ (${sw.elapsedMilliseconds}ms) $msg');
      } finally {
        yt.close();
      }
    }
  }

  print('\n=== clientes que sirvieron bytes ===');
  for (final entry in _videos.entries) {
    final ok = winners[entry.key] ?? const <String>[];
    print('  ${entry.key}: ${ok.isEmpty ? "NINGUNO" : ok.join(", ")}');
  }
}
