// Canario de 2 manifests — confirma que la IP está sana ANTES de correr
// cualquier otra cosa contra la red. Ver docs/investigacion_muro_antibot.md.
//
// IDs elegidos por no aparecer en ningún tool/probe ni test previo de esta
// investigación (grep sobre tool/*.dart, test/*.dart, docs/*.md), para no
// heredar el estado de cuota de una corrida anterior.
//
// Uso: dart run tool/canary_probe.dart
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const _videos = <String, String>{
  '09R8_2nJtjg': 'Maroon 5 — Sugar',
  'kXYiU_JCYtU': 'Linkin Park — Numb',
};

Future<void> main() async {
  final yt = YoutubeExplode();
  var ok = 0;
  try {
    for (final e in _videos.entries) {
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
      }
    }
  } finally {
    yt.close();
  }
  print('\nCanario: $ok/${_videos.length}');
}
