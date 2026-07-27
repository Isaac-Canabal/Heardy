// Valida el solver EJS en aislamiento: ¿ejecuta el bundle de yt-dlp y devuelve
// un `n` descifrado, sin depender de que YouTube nos deje pedir un manifest?
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/base_ejs_solver.dart';
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/ejs.dart';
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/js_challenge.dart';

class NodeEJSSolver extends BaseEJSSolver {
  final String _initCode;
  NodeEJSSolver._(this._initCode);

  static Future<NodeEJSSolver> init() async =>
      NodeEJSSolver._(await EJSBuilder.getJSModules());

  @override
  Future<String> executeJavaScript(String jsCode) async {
    final dir = await Directory.systemTemp.createTemp('ejs_probe_');
    try {
      final f = File('${dir.path}/run.js');
      await f.writeAsString('$_initCode\nconsole.log($jsCode);\n');
      final sw = Stopwatch()..start();
      final r = await Process.run('node', [f.path], stdoutEncoding: utf8);
      print('    [node ejecutó en ${sw.elapsedMilliseconds}ms, '
          'script ${(f.lengthSync() / 1024 / 1024).toStringAsFixed(1)}MB]');
      if (r.exitCode != 0) {
        throw Exception('node exit ${r.exitCode}: ${r.stderr}');
      }
      return (r.stdout as String).trim();
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

Future<void> main() async {
  final resp = await http.get(Uri.parse('https://www.youtube.com/iframe_api'));
  final m = RegExp(r'player\\?/([0-9a-fA-F]{8})\\?/').firstMatch(resp.body);
  final playerUrl =
      'https://www.youtube.com/s/player/${m!.group(1)}/player_ias.vflset/en_US/base.js';
  print('player: $playerUrl');

  final solver = await NodeEJSSolver.init();

  // Retos `n` con la forma real que emite YouTube.
  const challenges = ['1Yq5rNPQmcVfLLKz', 'aBcDeFgHiJkLmNoP', 'xK9_mQ2-vT4wRs7Z'];

  print('\n--- resolución de retos n ---');
  final results = await solver.solveBulk(playerUrl, {
    JSChallengeType.n: challenges,
  });
  for (final c in challenges) {
    final r = results[c];
    print('  $c  ->  ${r ?? "NULL (no resuelto)"}'
        '${r != null && r != c ? "   [transformado]" : ""}');
  }

  // Segunda llamada: debe usar el player preprocesado cacheado y ser mas rapida.
  print('\n--- segunda llamada (cache de player preprocesado) ---');
  final again = await solver.solveBulk(playerUrl, {
    JSChallengeType.n: ['ZZ11aa22BB33cc44'],
  });
  print('  ZZ11aa22BB33cc44 -> ${again['ZZ11aa22BB33cc44'] ?? "NULL"}');

  solver.dispose();
}
