// ¿Necesita esta app el solver de retos JS?
//
// El bloque que los resuelve (`StreamClient._parseStreamInfo`) está gated tras
// `watchPage != null`, y la app pasa `requireWatchPage: false` para evitar el
// muro anti-bot de la página /watch. Es decir: hoy el solver NO se invoca nunca.
// Antes de montar un runtime JS en Android para habilitarlo, hay que comprobar
// si las URLs que devuelven los clientes android traen algo que resolver, y si
// la descarga va throttleada.
//
// Un `n` sin descifrar limita la descarga a ~50-80 KB/s. Si no hay `n` ni firma,
// y el throughput es de MB/s, el solver es irrelevante para esta app.
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const _videoId = 'dQw4w9WgXcQ';

/// Cuánto se descarga para medir throughput.
const _probeBytes = 3 * 1024 * 1024;

Future<void> main() async {
  final yt = YoutubeExplode();
  try {
    // Etiquetados a mano: `androidSdkless` declara el mismo `clientName`
    // ("ANDROID") que `android` en su payload, así que leerlo de ahí hacía que
    // las dos secciones salieran con el mismo título pese a devolver manifests
    // distintos (6 streams vs 4).
    final configs = <String, List<YoutubeApiClient>>{
      'android': [YoutubeApiClient.android],
      'androidSdkless': [YoutubeApiClient.androidSdkless],
    };

    for (final entry in configs.entries) {
      final clients = entry.value;
      print('\n=== cliente ${entry.key} (requireWatchPage: false) ===');

      final StreamManifest manifest;
      try {
        manifest = await yt.videos.streamsClient.getManifest(
          VideoId(_videoId),
          ytClients: clients,
          requireWatchPage: false,
        );
      } catch (e) {
        print('  manifest falló: $e');
        continue;
      }

      final audio = manifest.audioOnly.toList();
      print('  ${audio.length} streams audio-only');

      for (final s in audio) {
        final q = s.url.queryParameters;
        final flags = [
          if (q.containsKey('n')) 'n=${q['n']}',
          if (q.containsKey('sig')) 'sig=SÍ',
          if (q.containsKey('s')) 's=SÍ (firma sin descifrar)',
          if (q.containsKey('ratebypass')) 'ratebypass=${q['ratebypass']}',
        ];
        print('    itag ${s.tag}  ${s.container.name}  '
            '${(s.bitrate.bitsPerSecond / 1000).round()}kbps  '
            '${(s.size.totalBytes / 1024 / 1024).toStringAsFixed(1)}MB  '
            '${flags.isEmpty ? "sin params de reto" : flags.join("  ")}');
      }

      if (audio.isEmpty) continue;

      // Throughput real sobre el stream que elegiría la app (mayor bitrate m4a,
      // si existe; si no, el mayor bitrate a secas).
      final best = audio.where((s) => s.container.name == 'mp4').isNotEmpty
          ? audio.where((s) => s.container.name == 'mp4').reduce(
              (a, b) => a.bitrate.bitsPerSecond > b.bitrate.bitsPerSecond ? a : b)
          : audio.reduce((a, b) => a.bitrate.bitsPerSecond > b.bitrate.bitsPerSecond ? a : b);

      print('  midiendo throughput con itag ${best.tag}...');
      final client = HttpClient();
      try {
        final request = await client.getUrl(best.url);
        request.headers.add('Range', 'bytes=0-${_probeBytes - 1}');
        final sw = Stopwatch()..start();
        final response = await request.close();
        var received = 0;
        await for (final chunk in response) {
          received += chunk.length;
        }
        sw.stop();
        final kbps = received / 1024 / (sw.elapsedMilliseconds / 1000);
        print('    HTTP ${response.statusCode} · '
            '${(received / 1024 / 1024).toStringAsFixed(1)}MB en '
            '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s · '
            '${kbps.round()} KB/s'
            '${kbps < 200 ? "   <-- THROTTLEADO (síntoma de n sin resolver)" : ""}');
      } catch (e) {
        print('    descarga de prueba falló: $e');
      } finally {
        client.close();
      }
    }
  } finally {
    yt.close();
  }
}
