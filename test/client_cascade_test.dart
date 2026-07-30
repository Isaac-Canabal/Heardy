// Cobertura del orden de `_clientFallbacks` y del avance de `startIndex` /
// `clientIndex` en `_getManifestWithFallback` (docs/investigacion_muro_antibot.md,
// sesión 2026-07-29): `[androidVr, safari]` tiene que ir primero porque Test A/B
// midió que evita el 403-en-bytes que sí da la cascada vieja
// (`android`/`androidSdkless`), y `downloadVideoWithAudio` depende de que, al
// escalar tras un 403, la cascada retome desde el cliente siguiente — no desde
// el principio.
//
// Usa los hooks `@visibleForTesting` (`clientFallbackNamesForTesting`,
// `manifestAttemptOverrideForTesting`, `getManifestWithFallbackForTesting`)
// para ejercer la lógica real sin pegarle a la red: el fake sustituye
// `streamsClient.getManifest`.
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:heardy/services/youtube_service.dart';

// Manifest vacío válido — sólo hace falta un StreamManifest real para que el
// fake pueda devolver "éxito" sin construir streams de verdad.
StreamManifest _emptyManifest() => StreamManifest([]);

void main() {
  test('tabla: [androidVr, safari] va primero; android/androidSdkless quedan '
      'como último recurso, no se eliminan', () {
    final cascade = YoutubeService.clientFallbacksForTesting;

    expect(
      cascade.first,
      [YoutubeApiClient.androidVr, YoutubeApiClient.safari],
      reason: 'Test A/B (2026-07-29) midió que esta combinación evita el '
          '403-en-bytes que sí da la cascada vieja',
    );

    final soloAndroidIdx =
        cascade.indexWhere((c) => c.length == 1 && identical(c.first, YoutubeApiClient.android));
    final soloSdklessIdx = cascade
        .indexWhere((c) => c.length == 1 && identical(c.first, YoutubeApiClient.androidSdkless));

    expect(soloAndroidIdx, greaterThan(0),
        reason: '"android" sigue presente, pero ya no primero');
    expect(soloSdklessIdx, greaterThan(0),
        reason: '"androidSdkless" sigue presente, pero ya no primero');
  });

  test('getManifestWithFallback usa el primer cliente cuando startIndex=0', () async {
    final service = YoutubeService();
    final attempted = <int>[];
    var callCount = 0;

    service.manifestAttemptOverrideForTesting = (videoId, clients) async {
      callCount++;
      attempted.add(callCount);
      return _emptyManifest();
    };

    final yt = YoutubeExplode();
    final result = await service.getManifestWithFallbackForTesting(
      yt,
      VideoId('dQw4w9WgXcQ'),
    );

    expect(result.clientIndex, 0);
    expect(callCount, 1, reason: 'el primer cliente ya tiene que servir — sin cascada de más');
  });

  test('startIndex salta los clientes ya descartados por 403-en-bytes', () async {
    final service = YoutubeService();
    final triedIndices = <int>[];
    var callIndex = 0;

    service.manifestAttemptOverrideForTesting = (videoId, clients) async {
      triedIndices.add(callIndex);
      callIndex++;
      return _emptyManifest();
    };

    final yt = YoutubeExplode();
    final result = await service.getManifestWithFallbackForTesting(
      yt,
      VideoId('dQw4w9WgXcQ'),
      startIndex: 2,
    );

    // Con startIndex: 2 no debería intentarse el cliente 0 (androidVr+safari)
    // ni el 1 (android) — el primer intento real tiene que caer directo en el
    // cliente #2 de la cascada.
    expect(result.clientIndex, 2);
    expect(triedIndices, [0],
        reason: 'sólo se llamó una vez, y correspondía al cliente #2, no al #0');
  });

  test('startIndex más allá del final de la cascada se clampea al último cliente', () async {
    final service = YoutubeService();
    var wasCalled = false;

    service.manifestAttemptOverrideForTesting = (videoId, clients) async {
      wasCalled = true;
      return _emptyManifest();
    };

    final yt = YoutubeExplode();
    final totalClients = YoutubeService.clientFallbacksForTesting.length;
    final result = await service.getManifestWithFallbackForTesting(
      yt,
      VideoId('dQw4w9WgXcQ'),
      startIndex: totalClients + 5, // muy por delante del final
    );

    expect(wasCalled, isTrue);
    expect(result.clientIndex, totalClients - 1,
        reason: 'no debería quedarse sin clientes para probar; se clampea al último');
  });

  test('si el cliente resuelto da error, escala al siguiente y devuelve su índice', () async {
    final service = YoutubeService();
    var callIndex = 0;

    service.manifestAttemptOverrideForTesting = (videoId, clients) async {
      final current = callIndex;
      callIndex++;
      if (current == 0) {
        throw Exception('manifest falló para el primer cliente');
      }
      return _emptyManifest();
    };

    final yt = YoutubeExplode();
    final result = await service.getManifestWithFallbackForTesting(
      yt,
      VideoId('dQw4w9WgXcQ'),
    );

    expect(result.clientIndex, 1,
        reason: 'el cliente 0 falló, así que el manifest debe venir del cliente 1');
  });
}
