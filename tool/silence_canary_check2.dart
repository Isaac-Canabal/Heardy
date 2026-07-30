// Canario único, segunda vez (2026-07-29). IDs de la reserva de 5 documentada
// en docs/investigacion_muro_antibot.md — no usados hoy, no pertenecen a los
// grupos A/B de la comparación 5-vs-5.
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const _videos = <String, String>{
  'rt_z10mb_k0': 'Sabrina Carpenter — House Tour',
  'T6Cfm27rHwA': 'corook — it’s ok! (bedroom demo)',
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
  print('\nCanario: $ok/${_videos.length}');
}
