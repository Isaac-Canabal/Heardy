// ¿Espaciar las peticiones reduce la tasa de fallo del muro anti-bot?
//
// Mide el paso que falla de verdad (`streamsClient.getManifest`, ver CLAUDE.md)
// sobre el mismo set de vídeos, variando SÓLO la pausa entre peticiones.
//
// Usa YoutubeExplode en crudo a propósito, sin pasar por YoutubeService: así se
// mide la respuesta de YouTube al ritmo de peticiones, sin que el circuit breaker
// ni los reintentos propios contaminen el resultado.
//
// Se ejecutan las dos condiciones en los dos órdenes (A,B,B,A) porque la primera
// en correr siempre parte de una sesión más "fresca" — sin eso, el orden explica
// parte del resultado. Entre bloques hay una pausa larga para dejar que el
// bloqueo previo expire.
//
//   dart run tool/pacing_probe.dart
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const _videos = <String>[
  'dQw4w9WgXcQ', // Rick Astley - Never Gonna Give You Up
  'djV11Xbc914', // a-ha - Take On Me
  'fJ9rUzIMcZQ', // Queen - Bohemian Rhapsody
  'hTWKbfoikeg', // Nirvana - Smells Like Teen Spirit
  '8UVNT4wvIGY', // Gotye - Somebody That I Used To Know
  '9bZkp7q19f0', // PSY - Gangnam Style
  'kJQP7kiw5Fk', // Luis Fonsi - Despacito
  'Zi_XLOBDo_Y', // Michael Jackson - Billie Jean
  'dvgZkm1xWPE', // Coldplay - Viva La Vida
  'YQHsXMglC9A', // Adele - Hello
  'JGwWNGJdvx8', // Ed Sheeran - Shape of You
  'RgKAFK5djSk', // Wiz Khalifa - See You Again
];

/// Pausa entre bloques, para que el bloqueo del bloque anterior expire.
const _blockCooldown = Duration(seconds: 150);

class _Result {
  _Result(this.spacing, this.ok, this.failed, this.elapsedMs);
  final Duration spacing;
  final int ok;
  final int failed;
  final int elapsedMs;

  double get failureRate => failed / (ok + failed);
}

Future<_Result> _runBlock(String label, Duration spacing) async {
  print('\n--- $label (pausa ${spacing.inSeconds}s entre peticiones) ---');
  var ok = 0;
  var failed = 0;
  final sw = Stopwatch()..start();

  for (var i = 0; i < _videos.length; i++) {
    if (i > 0 && spacing > Duration.zero) {
      await Future.delayed(spacing);
    }
    final yt = YoutubeExplode();
    try {
      final m = await yt.videos.streamsClient
          .getManifest(VideoId(_videos[i]),
              ytClients: [YoutubeApiClient.android], requireWatchPage: false)
          .timeout(const Duration(seconds: 40));
      if (m.audioOnly.isNotEmpty) {
        ok++;
        print('  ${(i + 1).toString().padLeft(2)}. OK      ${_videos[i]}');
      } else {
        failed++;
        print('  ${(i + 1).toString().padLeft(2)}. 0 audio ${_videos[i]}');
      }
    } catch (e) {
      failed++;
      final msg = e.toString().split('\n').first.trim();
      print('  ${(i + 1).toString().padLeft(2)}. FALLÓ   ${_videos[i]}  '
          '${msg.length > 60 ? "${msg.substring(0, 60)}..." : msg}');
    } finally {
      yt.close();
    }
  }
  sw.stop();

  final r = _Result(spacing, ok, failed, sw.elapsedMilliseconds);
  print('  => $ok OK / $failed fallaron '
      '(${(r.failureRate * 100).toStringAsFixed(0)}% de fallo) '
      'en ${(r.elapsedMs / 1000).toStringAsFixed(0)}s');
  return r;
}

Future<void> main() async {
  const spacings = <String, Duration>{
    'SIN pausa': Duration.zero,
    'CON pausa': Duration(seconds: 5),
  };

  final results = <String, List<_Result>>{};

  // Orden A,B luego B,A para que ninguna condición se lleve siempre la sesión
  // fresca.
  final order = [
    ...spacings.entries,
    ...spacings.entries.toList().reversed,
  ];

  for (var i = 0; i < order.length; i++) {
    final entry = order[i];
    final r = await _runBlock('bloque ${i + 1}/4: ${entry.key}', entry.value);
    results.putIfAbsent(entry.key, () => []).add(r);

    if (i < order.length - 1) {
      print('  (esperando ${_blockCooldown.inSeconds}s para que expire el bloqueo)');
      await Future.delayed(_blockCooldown);
    }
  }

  print('\n=== RESUMEN ===');
  for (final entry in results.entries) {
    final totalOk = entry.value.fold(0, (s, r) => s + r.ok);
    final totalFailed = entry.value.fold(0, (s, r) => s + r.failed);
    final rate = totalFailed / (totalOk + totalFailed) * 100;
    final secs = entry.value.fold(0, (s, r) => s + r.elapsedMs) / 1000;
    print('  ${entry.key.padRight(10)} '
        '$totalOk OK / $totalFailed fallaron  '
        '=> ${rate.toStringAsFixed(0)}% de fallo  '
        '(${secs.toStringAsFixed(0)}s de reloj en total)');
    print('    por bloque: ${entry.value.map((r) => "${(r.failureRate * 100).round()}%").join(", ")}');
  }
}
