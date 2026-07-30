// ██ EXPERIMENTO PENDIENTE — NO ES UN TEST DE REGRESIÓN ██
//
// Comparación de 15 canciones del branch actual contra el baseline de `main`
// (15/15, 15 manifests, 141s — docs/investigacion_muro_antibot.md), con los
// IDs resueltos por búsqueda InnerTube el 2026-07-29 (sin usar antes en la
// investigación). Corre después de un canario post-silencio 2/2.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:heardy/services/ytmusic_service.dart';
import 'package:heardy/services/youtube_service.dart';

const _videos = <String, String>{
  'Kx7B-XvmFtE': 'Imagine Dragons — Believer',
  'J7p4bzqLvCw': 'The Weeknd — Blinding Lights',
  'ZD6rXLXZOEI': 'Billie Eilish — bad guy',
  'OsfAnsMY21M': 'Dua Lipa — Levitating',
  '4EQkYVtE-28': 'Post Malone — Circles',
  '9qnqYL0eNNI': 'Coldplay — Yellow',
  '4wOLVrGHiIU': 'Eminem — Lose Yourself',
  '4mVo93E9wpU': 'Rihanna — Diamonds',
  'M51-spaR4qk': 'Katy Perry — Firework',
  'lNilb-EaTOU': 'Maroon 5 — Memories',
  'uzaYLK3k0DQ': 'Sia — Chandelier',
  '2NiyrtYegso': 'Avicii — Wake Me Up',
  '1FeEa2Ew2yo': 'Shakira — Waka Waka',
  'pIWaVJPl0-c': 'Alan Walker — Faded',
  '6xzN8Nt0Pok': 'Whitney Houston — I Wanna Dance With Somebody',
};

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  late Directory sandbox;

  setUpAll(() {
    sandbox = Directory.systemTemp.createTempSync('heardy_15song_');
    PathProviderPlatform.instance = _TempPathProvider(sandbox.path);
  });

  setUp(YoutubeService.resetCircuitBreaker);

  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('15 canciones, IDs nuevos, contra baseline de main (15/15, 15 manifests, 141s)', () async {
    final service = YTMusicService();
    final totalSw = Stopwatch()..start();
    var completed = 0;
    var pos = 0;

    for (final e in _videos.entries) {
      pos++;
      final sw = Stopwatch()..start();
      try {
        final r = await service.downloadVideoWithAudio(
          'https://www.youtube.com/watch?v=${e.key}',
        );
        sw.stop();
        final f = File(r['filePath'] as String);
        final kb = f.existsSync() ? f.lengthSync() / 1024 : 0;
        completed++;
        print('$pos. OK     ${e.key}  ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s  '
            '${kb.toStringAsFixed(0)}KB  ${e.value}');
      } catch (err) {
        sw.stop();
        final full = err.toString().replaceAll('\n', ' | ').trim();
        print('$pos. FALLÓ  ${e.key}  ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s  ${e.value}');
        print('   ${full.length > 250 ? "${full.substring(0, 250)}…" : full}');
      }
    }

    totalSw.stop();
    print('\n=== RESULTADO: $completed/${_videos.length} completadas en '
        '${(totalSw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s ===');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
