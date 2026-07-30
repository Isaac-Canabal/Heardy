// ██ EXPERIMENTO PENDIENTE — NO ES UN TEST DE REGRESIÓN ██
//
// Mitad "branch actual" de la comparación 5-vs-5 rediseñada
// (docs/investigacion_muro_antibot.md): 15 canciones no es viable con el
// presupuesto real de una ventana de silencio (~10-12 min medidos). Corre
// DESPUÉS de: silencio total + un solo canario 2/2. Métrica principal:
// manifests emitidos por canción, no cuántas completan.
//
// Grupo A (este archivo) — de los 15 IDs ya validados el 2026-07-28 en
// C:/heardy-main/test/main_15_test.dart (baseline: 15/15, 15 manifests, 141s),
// partidos en dos grupos de 5 disjuntos para no tener que resolver IDs nuevos
// por red durante la ventana de silencio. Grupo B (main) y una reserva de 5
// para la próxima corrida (alternar quién va primero) están documentados en el
// propio doc de investigación.
//
// Captura TODO el output a archivo vía un `print` de zona — nada de `tail` ni
// pipes que puedan truncar la salida si la corrida se corta a mitad.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:heardy/services/ytmusic_service.dart';
import 'package:heardy/services/youtube_service.dart';

const _videos = <String, String>{
  'SzJXikN_4wA': 'Taylor Swift — I Knew It, I Knew You',
  'UdGMRQg5szM': 'Bad Bunny — WHERE SHE GOES',
  'DntZ3-yCaFs': 'Sabrina Carpenter — Manchild',
  'QQXZyf0OJpI': 'Taylor Swift — 22',
  'TRjlrJ2zqn0': 'Bad Bunny — WELTiTA',
};

const _logPath =
    'C:/Users/ISAACC~1/AppData/Local/Temp/claude/C--Heardy/1145cfb6-5641-4f65-8c54-8997136ee366/scratchpad/five_song_branch.log';

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
  late IOSink sink;

  setUpAll(() {
    sandbox = Directory.systemTemp.createTempSync('heardy_5song_branch_');
    PathProviderPlatform.instance = _TempPathProvider(sandbox.path);
    sink = File(_logPath).openWrite();
  });

  setUp(YoutubeService.resetCircuitBreaker);

  tearDownAll(() async {
    await sink.flush();
    await sink.close();
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('branch actual: 5 descargas, grupo A', () async {
    final service = YTMusicService();
    var manifestAttemptsThisSong = 0;
    var breakerActivationsThisSong = 0;
    var botWallThisSong = 0;
    var completed = 0;
    final perSong = <String>[];
    final total = Stopwatch()..start();

    void log(String line) {
      sink.writeln(line);
    }

    await runZonedGuarded(() async {
      var pos = 0;
      for (final e in _videos.entries) {
        pos++;
        manifestAttemptsThisSong = 0;
        breakerActivationsThisSong = 0;
        botWallThisSong = 0;
        final sw = Stopwatch()..start();
        try {
          final r = await service.downloadVideoWithAudio(
            'https://www.youtube.com/watch?v=${e.key}',
          );
          sw.stop();
          final f = File(r['filePath'] as String);
          final kb = f.existsSync() ? f.lengthSync() / 1024 : 0;
          completed++;
          final line = '$pos. OK     ${e.key}  '
              '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s  '
              '${kb.toStringAsFixed(0)}KB  manifests=$manifestAttemptsThisSong  '
              'breaker=$breakerActivationsThisSong  botwall=$botWallThisSong  ${e.value}';
          log(line);
          perSong.add(line);
        } catch (err) {
          sw.stop();
          final full = err.toString().replaceAll('\n', ' | ').trim();
          final line = '$pos. FALLÓ  ${e.key}  '
              '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s  '
              'manifests=$manifestAttemptsThisSong  breaker=$breakerActivationsThisSong  '
              'botwall=$botWallThisSong  ${e.value}\n   '
              '${full.length > 300 ? "${full.substring(0, 300)}…" : full}';
          log(line);
          perSong.add(line);
        }
      }
    }, (error, stack) {
      log('ERROR NO CAPTURADO: $error');
    }, zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        sink.writeln('  | $line');
        if (line.contains('Manifest intento #')) manifestAttemptsThisSong++;
        if (line.contains('Hard block detected')) breakerActivationsThisSong++;
        if (line.contains('BotWallException') || line.contains('Muro anti-bot')) {
          botWallThisSong++;
        }
        parent.print(zone, line);
      },
    ));

    total.stop();
    log('\n=== RESUMEN BRANCH (grupo A) ===');
    log('  $completed/${_videos.length} completadas');
    log('  tiempo total: ${(total.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
    for (final l in perSong) {
      log('  $l');
    }
    print('=== branch: $completed/${_videos.length}, '
        '${(total.elapsedMilliseconds / 1000).toStringAsFixed(1)}s — log completo en $_logPath ===');
  }, timeout: const Timeout(Duration(minutes: 12)));
}
