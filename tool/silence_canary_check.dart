// Canario único post-silencio (2026-07-29, 25 min sin tráfico real tras
// detener tool/recovery_probe.dart). IDs sin usar hoy: los dos "de repuesto"
// documentados en docs/investigacion_muro_antibot.md.
//
// Uso: dart run tool/silence_canary_check.dart
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const _videos = <String, String>{
  'b72gdhV_rXM': 'Queen — Another One Bites the Dust',
  'Kr4EQDVETuA': 'Michael Jackson — Billie Jean',
};

Future<void> main() async {
  var ok = 0;
  for (final e in _videos.entries) {
    final yt = YoutubeExplode();
    final sw = Stopwatch()..start();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(
        VideoId(e.key),
        ytClients: [YoutubeApiClient.android],
        requireWatchPage: false,
      );
      sw.stop();
      ok++;
      print('OK    ${e.key}  ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s  '
          '${manifest.audioOnly.length} streams audio  ${e.value}');
    } catch (err) {
      sw.stop();
      print('FALLÓ ${e.key}  ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s  ${e.value}');
      print('  $err');
    } finally {
      yt.close();
    }
  }
  print('\nCanario post-silencio: $ok/${_videos.length}');
}
