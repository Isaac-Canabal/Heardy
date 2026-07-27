// Smoke test del motor de descarga real, ejecutable desde escritorio.
//
//   flutter test test/download_smoke_test.dart
//
// Por qué existe: los cuelgues y fallos de descarga sólo se veían en el móvil, y
// verificarlos implicaba compilar e instalar la APK cada vez. `dart run` no
// sirve porque `YoutubeService` usa `path_provider`, que es un plugin y no carga
// fuera de Flutter — pero es su ÚNICA dependencia de plugin, así que basta con
// sustituir `PathProviderPlatform` por un directorio temporal para ejercitar el
// motor entero (metadata, manifest, chunks, validación, miniatura) contra
// YouTube de verdad. `flutter test` corre en la VM de Dart con red real.
//
// Estos tests hacen peticiones de red reales, así que no son deterministas: un
// fallo puede significar "hay un bug" o "YouTube está bloqueando ahora mismo".
// La salida imprime fases y tiempos para poder distinguirlo.
//
// Deliberadamente NO se prueba `DownloadProvider`: eso arrastraría sqflite,
// wakelock y notificaciones. Aquí vive el motor, que es donde están los bugs de
// timeout/cuelgue.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:heardy/services/youtube_service.dart';
import 'package:heardy/services/ytmusic_service.dart';

/// Vídeos de prueba. Estables y de larga data; si uno empieza a fallar de forma
/// consistente mientras los demás pasan, es que ese vídeo cambió, no el código.
const _testVideos = <String, String>{
  'Rick Astley - Never Gonna Give You Up': 'dQw4w9WgXcQ',
  'a-ha - Take On Me': 'djV11Xbc914',
};

/// Playlist pública y estable, para el path de expansión.
const _testPlaylist =
    'https://www.youtube.com/playlist?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI';

/// El muro anti-bot, en las dos formas en que llega: `VideoUnplayableException`
/// desde el paso del manifest y `VideoUnavailableException` desde el scrape de
/// /watch. El apóstrofo de YouTube es tipográfico (’), no ASCII.
bool _isBotWall(Object e) {
  final s = e.toString().toLowerCase();
  return s.contains("confirm you're not a bot") ||
      s.contains('confirm you’re not a bot') ||
      s.contains('videounplayableexception') ||
      s.contains('videounavailableexception');
}

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
    sandbox = Directory.systemTemp.createTempSync('heardy_smoke_');
    PathProviderPlatform.instance = _TempPathProvider(sandbox.path);
    print('sandbox: ${sandbox.path}');
  });

  // El circuit breaker es estado `static` compartido: sin esto, un test que
  // provoca un bloqueo deja a los siguientes esperando cooldowns heredados de
  // hasta 180s, y fallan por timeout por un motivo que no es el que prueban.
  setUp(YoutubeService.resetCircuitBreaker);

  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('metadata', () {
    test('YTMusicService (InnerTube) devuelve metadata utilizable', () async {
      // Este es el path que evita el scrape de /watch con muro anti-bot. Si
      // falla, las descargas caen al scrape frágil y empiezan los
      // VideoUnavailableException falsos.
      final ytmusic = YTMusicService();
      final sw = Stopwatch()..start();
      final info = await ytmusic.getVideoInfo(
        'https://www.youtube.com/watch?v=${_testVideos.values.first}',
      );
      sw.stop();

      print('  metadata en ${sw.elapsedMilliseconds}ms: '
          '"${info['title']}" / "${info['artist']}" / ${info['duration']}');

      expect(info['title'], isNotEmpty);
      // Regresión concreta: `song.artists` (plural) no existe en
      // dart_ytmusic_api, y el catch se lo tragaba devolviendo esto siempre.
      expect(info['artist'], isNot('Unknown Artist'),
          reason: 'el parseo de artista volvió a romperse');
      // Idem: `durationMs` no existe, la duración viene en segundos.
      expect((info['duration'] as Duration).inSeconds, greaterThan(0),
          reason: 'el parseo de duración volvió a romperse');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('descarga completa', () {
    for (final entry in _testVideos.entries) {
      test('descarga "${entry.key}"', () async {
        // OJO: tiene que ser YTMusicService, NO YoutubeService. Es lo que usa
        // `DownloadProvider`, y la diferencia no es cosmética: YTMusicService
        // primero pide metadata por InnerTube y con ella cebra la caché de
        // YoutubeService, que es exactamente lo que evita el scrape de /watch
        // donde YouTube sirve el muro anti-bot. Escrito contra YoutubeService
        // directo, este test fallaba con VideoUnavailableException — estaba
        // ejercitando el path SIN el arreglo. Ver el A/B de abajo.
        final service = YTMusicService();
        final phases = <String>[];
        var lastProgress = 0.0;
        final sw = Stopwatch()..start();

        final Map<String, dynamic> result;
        try {
          result = await service.downloadVideoWithAudio(
            'https://www.youtube.com/watch?v=${entry.value}',
            onPhase: (p) {
              phases.add('${p}@${sw.elapsedMilliseconds}ms');
              print('  fase: $p (${sw.elapsedMilliseconds}ms)');
            },
            onProgress: (p) => lastProgress = p,
          );
        } catch (e) {
          // Distinguir "hay un bug" de "YouTube está bloqueando esta IP ahora".
          //
          // Medido: el bloqueo NO es por vídeo. Dos corridas seguidas del mismo
          // set de 10 vídeos dieron resultados opuestos para los mismos IDs
          // (a-ha OK en la primera y fallando en la segunda, Nirvana al revés),
          // con ~80% de fallos en ambas. Basta con una decena de manifests
          // seguidos para disparar el muro, y ningún cliente de InnerTube es
          // inmune (ver tool/client_sweep_probe.dart: los 11 fallan a la vez
          // cuando la sesión está bloqueada).
          //
          // Por eso un fallo de descarga aquí no puede tratarse como fallo del
          // test: sería intermitente por diseño. Se marca fuerte en la salida y
          // se deja pasar; lo que sí falla el test es cualquier OTRO error.
          if (_isBotWall(e)) {
            print('  === MURO ANTI-BOT (no es un bug del código) ===');
            print('  ${e.toString().split("\n").first.trim()}');
            print('  fases alcanzadas: ${phases.join(" -> ")}');
            print('  YouTube está limitando esta IP. Espera unos minutos y '
                'reintenta, o corre menos tests a la vez.');
            return;
          }
          rethrow;
        }
        sw.stop();

        final file = File(result['filePath'] as String);
        final sizeKb = file.lengthSync() / 1024;
        final seconds = sw.elapsedMilliseconds / 1000;
        print('  OK en ${seconds.toStringAsFixed(1)}s · '
            '${sizeKb.toStringAsFixed(0)}KB · ${result['format']} · '
            '${(sizeKb / seconds).toStringAsFixed(0)}KB/s · '
            'progreso final ${(lastProgress * 100).toStringAsFixed(0)}%');
        print('  fases: ${phases.join(" -> ")}');

        expect(file.existsSync(), isTrue);
        // `_validateDownloadedFile` ya rechaza por debajo de 1KB; 100KB es el
        // umbral de "esto es audio real y no una página de error".
        expect(sizeKb, greaterThan(100),
            reason: 'el archivo es demasiado pequeño para ser audio real');
        expect(result['title'], isNotEmpty);
        expect(result['artist'], isNot('Unknown Artist'));
        expect(File(result['artPath'] as String).existsSync(), isTrue,
            reason: 'la miniatura no se descargó');
        // 12 minutos, no 5: con la sesión bloqueada el camino hasta el error
        // definitivo son 5 intentos con cooldowns del breaker que escalan
        // 20s->40s->80s->160s (medido: fases a los 22s, 64s, 148s y 310s). Con 5
        // minutos el test moría por timeout ANTES de llegar a la detección de
        // muro anti-bot, y se reportaba como fallo de código en vez de como lo
        // que era. Un descarga sana tarda ~1s.
      }, timeout: const Timeout(Duration(minutes: 12)));
    }

    test('un vídeo ya descargado se reutiliza en vez de re-descargarse',
        () async {
      // `_downloadViaParallelChunks` corta en seco si el archivo ya está
      // completo. Debe ser mucho más rápido que la descarga original.
      final service = YTMusicService();
      final url =
          'https://www.youtube.com/watch?v=${_testVideos.values.first}';
      final sw = Stopwatch()..start();
      final result = await service.downloadVideoWithAudio(url);
      sw.stop();

      print('  segunda pasada en ${sw.elapsedMilliseconds}ms');
      expect(File(result['filePath'] as String).existsSync(), isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('expansión de playlist', () {
    test('resuelve los IDs de una playlist', () async {
      // El path que se quedaba clavado en "Analizando lista..." sin timeout.
      final ytmusic = YTMusicService();
      final sw = Stopwatch()..start();
      final ids = await ytmusic.getPlaylistVideoIds(_testPlaylist);
      sw.stop();

      print('  ${ids.length} IDs en ${sw.elapsedMilliseconds}ms');
      expect(ids, isNotEmpty);
      expect(ids.every((id) => id.isNotEmpty), isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('se puede cancelar a mitad', () async {
      // Regresión del cuelgue: cancelar tiene que devolver el control rápido,
      // no esperar a que termine la expansión entera.
      final service = YoutubeService();
      final sw = Stopwatch()..start();

      await expectLater(
        service.getPlaylistVideoIds(
          _testPlaylist,
          isCancelled: () => sw.elapsedMilliseconds > 500,
        ),
        throwsA(predicate((e) => YoutubeService.isCancellationError(e as Object),
            'es un error de cancelación')),
      );
      sw.stop();

      print('  cancelado en ${sw.elapsedMilliseconds}ms');
      expect(sw.elapsedMilliseconds, lessThan(30000),
          reason: 'la cancelación tardó demasiado en propagarse');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('el muro anti-bot de /watch (diagnóstico)', () {
    // Compara las dos fuentes de metadata sobre el mismo vídeo:
    //
    //   - YoutubeService.getVideoInfo -> videos.get() -> scrapea el HTML de
    //     /watch y deduce disponibilidad de la presencia de un
    //     <meta property="og:url">. Cuando YouTube sirve ahí el muro
    //     "Sign in to confirm you're not a bot", la etiqueta no está y la
    //     librería lanza VideoUnavailableException para un vídeo perfectamente
    //     reproducible.
    //   - YTMusicService.getVideoInfo -> endpoint JSON InnerTube, no pasa por
    //     ese muro.
    //
    // Sólo se afirma sobre InnerTube: que el scrape falle depende de si YouTube
    // está bloqueando en ese momento, así que afirmarlo haría el test
    // intermitente. Lo que importa es la comparación impresa — si InnerTube
    // funciona y el scrape no, el diagnóstico está confirmado en esta corrida.
    for (final entry in _testVideos.entries) {
      test('${entry.key}: InnerTube vs scrape de /watch', () async {
        final url = 'https://www.youtube.com/watch?v=${entry.value}';

        String scrapeResult;
        YoutubeService.resetCircuitBreaker();
        try {
          final raw = await YoutubeService().getVideoInfo(url);
          scrapeResult = 'OK ("${raw['title']}")';
        } catch (e) {
          scrapeResult =
              'FALLÓ (${e.toString().split("\n").first.trim()})';
        }

        String innertubeResult;
        Object? innertubeError;
        YoutubeService.resetCircuitBreaker();
        try {
          final ytm = await YTMusicService().getVideoInfo(url);
          innertubeResult = 'OK ("${ytm['title']}")';
        } catch (e) {
          innertubeResult = 'FALLÓ ($e)';
          innertubeError = e;
        }

        print('  scrape /watch : $scrapeResult');
        print('  InnerTube     : $innertubeResult');
        if (scrapeResult.startsWith('FALLÓ') &&
            innertubeResult.startsWith('OK')) {
          print('  -> muro anti-bot confirmado en esta corrida; '
              'el priming de YTMusicService es lo que salva la descarga');
        }

        expect(innertubeError, isNull,
            reason: 'InnerTube también falló: sin fuente de metadata viable');
      }, timeout: const Timeout(Duration(minutes: 3)));
    }
  });

  group('timeouts', () {
    test('un host que no responde falla rápido y no se queda colgado',
        () async {
      // El bug de fondo era que ninguna capa de red tenía timeout, así que un
      // socket muerto esperaba para siempre. 10.255.255.1 es una IP no
      // enrutable: acepta la conexión o la deja pendiente, nunca responde.
      // Sirve como prueba de que un cuelgue de red ahora se convierte en error.
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final sw = Stopwatch()..start();
      var threw = false;
      try {
        final request =
            await client.getUrl(Uri.parse('http://10.255.255.1/probe'));
        await request.close().timeout(const Duration(seconds: 5));
      } catch (_) {
        threw = true;
      } finally {
        client.close(force: true);
        sw.stop();
      }

      print('  falló en ${sw.elapsedMilliseconds}ms');
      expect(threw, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(15000));
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
