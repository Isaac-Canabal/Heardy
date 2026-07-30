// Sondeo de recuperación de IP para la investigación del muro anti-bot
// (docs/investigacion_muro_antibot.md). Corre canarios de 2 manifests cada 5
// minutos, rotando de a pares por los 17 vídeos documentados el 2026-07-29
// (resueltos por búsqueda InnerTube, sin usar antes en esta investigación),
// hasta ver DOS rondas 2/2 seguidas — una sola puede ser ruido de un vídeo
// puntual, no de la IP.
//
// De paso, esto da el primer dato fino de cuánto tarda esta IP en recuperarse
// (hasta ahora sólo había una estimación gruesa de 15-40 min sin medir).
//
// Uso: dart run tool/recovery_probe.dart <ruta-log>
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const _videos = <MapEntry<String, String>>[
  MapEntry('Kx7B-XvmFtE', 'Imagine Dragons — Believer'),
  MapEntry('J7p4bzqLvCw', 'The Weeknd — Blinding Lights'),
  MapEntry('ZD6rXLXZOEI', 'Billie Eilish — bad guy'),
  MapEntry('OsfAnsMY21M', 'Dua Lipa — Levitating'),
  MapEntry('4EQkYVtE-28', 'Post Malone — Circles'),
  MapEntry('9qnqYL0eNNI', 'Coldplay — Yellow'),
  MapEntry('4wOLVrGHiIU', 'Eminem — Lose Yourself'),
  MapEntry('4mVo93E9wpU', 'Rihanna — Diamonds'),
  MapEntry('M51-spaR4qk', 'Katy Perry — Firework'),
  MapEntry('lNilb-EaTOU', 'Maroon 5 — Memories'),
  MapEntry('uzaYLK3k0DQ', 'Sia — Chandelier'),
  MapEntry('2NiyrtYegso', 'Avicii — Wake Me Up'),
  MapEntry('1FeEa2Ew2yo', 'Shakira — Waka Waka'),
  MapEntry('pIWaVJPl0-c', 'Alan Walker — Faded'),
  MapEntry('6xzN8Nt0Pok', 'Whitney Houston — I Wanna Dance With Somebody'),
  MapEntry('b72gdhV_rXM', 'Queen — Another One Bites the Dust'),
  MapEntry('Kr4EQDVETuA', 'Michael Jackson — Billie Jean'),
];

const _intervalMinutes = 5;
const _maxRounds = 24; // 2h de techo — si no converge para entonces, algo cambió.

Future<bool> _checkOne(String videoId) async {
  final yt = YoutubeExplode();
  try {
    await yt.videos.streamsClient.getManifest(
      VideoId(videoId),
      ytClients: [YoutubeApiClient.android],
      requireWatchPage: false,
    );
    return true;
  } catch (_) {
    return false;
  } finally {
    yt.close();
  }
}

void main(List<String> args) async {
  final logPath = args.isNotEmpty ? args[0] : 'recovery_probe.log';
  final logFile = File(logPath);
  final start = DateTime.now();

  void log(String line) {
    final ts = DateTime.now().toIso8601String();
    final full = '[$ts] $line';
    print(full);
    logFile.writeAsStringSync('$full\n', mode: FileMode.append, flush: true);
  }

  log('=== Sondeo de recuperación iniciado ===');

  var consecutiveFullPasses = 0;

  for (var round = 0; round < _maxRounds; round++) {
    final idx1 = (round * 2) % _videos.length;
    final idx2 = (round * 2 + 1) % _videos.length;
    final v1 = _videos[idx1];
    final v2 = _videos[idx2];

    final ok1 = await _checkOne(v1.key);
    final ok2 = await _checkOne(v2.key);
    final passCount = (ok1 ? 1 : 0) + (ok2 ? 1 : 0);
    final elapsedMin = DateTime.now().difference(start).inMinutes;

    log('ronda $round (+${elapsedMin}min)  '
        '${v1.key}=${ok1 ? "OK" : "FALLO"} (${v1.value})  '
        '${v2.key}=${ok2 ? "OK" : "FALLO"} (${v2.value})  -> $passCount/2');

    if (passCount == 2) {
      consecutiveFullPasses++;
    } else {
      consecutiveFullPasses = 0;
    }

    if (consecutiveFullPasses >= 2) {
      log('=== RECUPERACIÓN CONFIRMADA: 2/2 dos rondas seguidas, '
          '${elapsedMin} min desde el inicio del sondeo ===');
      exit(0);
    }

    if (round < _maxRounds - 1) {
      await Future.delayed(const Duration(minutes: _intervalMinutes));
    }
  }

  log('=== Sin recuperación confirmada tras $_maxRounds rondas '
      '(~${_maxRounds * _intervalMinutes} min) — deteniendo el sondeo ===');
  exit(1);
}
