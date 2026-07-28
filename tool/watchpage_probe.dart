// ¿`requireWatchPage: false` es lo que rompió las descargas?
//
// La rama `main` (que según el usuario funcionaba bien) pedía el manifest así:
//
//     getManifest(videoId, ytClients: [androidVr, safari])
//
// sin `requireWatchPage`, o sea con el default `true`. La rama actual pasa
// `requireWatchPage: false` para evitar el scrape de /watch con muro anti-bot.
//
// La hipótesis: ese scrape no era sólo coste, era lo que ESTABLECÍA SESIÓN.
// `WatchPage.get` recoge las cookies del `set-cookie` de YouTube, y
// `VideoController.getPlayerResponse` sólo las adjunta a la petición de InnerTube
// `if (watchPage != null)` (video_controller.dart:57). Sin página, todas nuestras
// peticiones van sin cookies — y YouTube trata mucho peor a una sesión anónima.
//
// DISEÑO: las condiciones se INTERCALAN sobre vídeos distintos dentro de la misma
// corrida, en vez de en bloques separados. tool/pacing_probe.dart demostró que el
// muro es un presupuesto acumulado (~12-24 peticiones) y que la tasa de fallo
// depende sobre todo de cuántas peticiones llevas hechas; con bloques separados,
// el que corre primero gana siempre. Intercalando, las dos condiciones
// atraviesan el mismo agotamiento. Se corre dos veces con la fase invertida para
// descartar que la posición explique el resultado.
//
//   dart run tool/watchpage_probe.dart
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const _videos = <String>[
  'dQw4w9WgXcQ', 'djV11Xbc914', 'fJ9rUzIMcZQ', 'hTWKbfoikeg',
  '8UVNT4wvIGY', '9bZkp7q19f0', 'kJQP7kiw5Fk', 'Zi_XLOBDo_Y',
  'dvgZkm1xWPE', 'YQHsXMglC9A', 'JGwWNGJdvx8', 'RgKAFK5djSk',
  'CevxZvSJLk8', 'OPf0YbXqDm0', 'lp-EO5I60KA', 'ktvTqknDobU',
];

/// `main`: trae /watch, así que la petición a InnerTube lleva cookies.
Future<void> _mainStyle(YoutubeExplode yt, String id) async {
  await yt.videos.streamsClient.getManifest(
    VideoId(id),
    ytClients: [YoutubeApiClient.androidVr, YoutubeApiClient.safari],
  );
}

/// Rama actual: sin /watch, sin cookies.
Future<void> _currentStyle(YoutubeExplode yt, String id) async {
  await yt.videos.streamsClient.getManifest(
    VideoId(id),
    ytClients: [YoutubeApiClient.android],
    requireWatchPage: false,
  );
}

/// Espera hasta que la IP se recupere del bloqueo previo, porque arrancar ya
/// bloqueado hace fallar las dos condiciones y no mide nada. Sondea con la
/// variante `main` sobre un vídeo aparte.
Future<bool> _waitForRecovery({int maxMinutes = 20}) async {
  print('Esperando a que la sesión se recupere antes de medir...');
  final sw = Stopwatch()..start();
  var attempt = 0;
  while (sw.elapsed.inMinutes < maxMinutes) {
    attempt++;
    final yt = YoutubeExplode();
    try {
      await _mainStyle(yt, 'jNQXAC9IVRw'); // "Me at the zoo"
      print('  recuperada tras ${sw.elapsed.inSeconds}s ($attempt intentos)');
      return true;
    } catch (_) {
      print('  aún bloqueada (${sw.elapsed.inSeconds}s), reintento en 60s');
      await Future.delayed(const Duration(seconds: 60));
    } finally {
      yt.close();
    }
  }
  print('  NO se recuperó en $maxMinutes min — se mide igual, con la salvedad');
  return false;
}

Future<Map<String, ({int ok, int fail})>> _runInterleaved(bool flip) async {
  final tally = <String, ({int ok, int fail})>{
    'main (con /watch)': (ok: 0, fail: 0),
    'actual (sin /watch)': (ok: 0, fail: 0),
  };

  for (var i = 0; i < _videos.length; i++) {
    // Alterna condición por vídeo; `flip` invierte la fase.
    final useMain = (i % 2 == 0) != flip;
    final label = useMain ? 'main (con /watch)' : 'actual (sin /watch)';

    final yt = YoutubeExplode();
    try {
      if (useMain) {
        await _mainStyle(yt, _videos[i]);
      } else {
        await _currentStyle(yt, _videos[i]);
      }
      tally[label] = (ok: tally[label]!.ok + 1, fail: tally[label]!.fail);
      print('  ${(i + 1).toString().padLeft(2)}. OK     ${label.padRight(20)} ${_videos[i]}');
    } catch (e) {
      tally[label] = (ok: tally[label]!.ok, fail: tally[label]!.fail + 1);
      final msg = e.toString().split('\n').first.trim();
      print('  ${(i + 1).toString().padLeft(2)}. FALLÓ  ${label.padRight(20)} ${_videos[i]}  '
          '${msg.length > 45 ? "${msg.substring(0, 45)}..." : msg}');
    } finally {
      yt.close();
    }
  }
  return tally;
}

Future<void> main() async {
  await _waitForRecovery();

  final totals = <String, ({int ok, int fail})>{
    'main (con /watch)': (ok: 0, fail: 0),
    'actual (sin /watch)': (ok: 0, fail: 0),
  };

  for (final flip in [false, true]) {
    print('\n--- corrida ${flip ? 2 : 1}/2 (fase ${flip ? "invertida" : "normal"}) ---');
    final t = await _runInterleaved(flip);
    for (final k in totals.keys) {
      totals[k] = (ok: totals[k]!.ok + t[k]!.ok, fail: totals[k]!.fail + t[k]!.fail);
    }
    if (!flip) {
      print('  (esperando recuperación antes de la segunda corrida)');
      await _waitForRecovery();
    }
  }

  print('\n=== RESUMEN (las dos condiciones sufrieron el mismo agotamiento) ===');
  for (final e in totals.entries) {
    final total = e.value.ok + e.value.fail;
    final rate = total == 0 ? 0 : e.value.fail / total * 100;
    print('  ${e.key.padRight(20)} ${e.value.ok} OK / ${e.value.fail} fallaron  '
        '=> ${rate.toStringAsFixed(0)}% de fallo');
  }
}
