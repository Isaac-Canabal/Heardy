// Cobertura de `MidDownloadCutException` (docs/investigacion_muro_antibot.md,
// sesión 2026-07-29): un corte a mitad de descarga (status ≠ 200/206 en un
// chunk que no es el primero) antes caía a `_validateDownloadedFile`, que sólo
// podía decir "descarga incompleta" sin dejar rastro de POR QUÉ. Esto verifica
// que ahora queda diagnosticable — status, chunk, bytes recibidos y cliente de
// manifest — sin tocar la red: usa el hook `@visibleForTesting`
// `checkMidChunkStatusForTesting`, envoltorio del método privado real.
//
// A propósito NO se prueba que dispare el salto de cliente ni el circuit
// breaker: todavía no hay ningún caso real de este modo de fallo, así que se
// deja sin decidir cuál de las dos hipótesis (cliente-condenado vs.
// expiración real de URL) aplica. Ver `_isHardBlockError` para la exclusión
// explícita por tipo.
import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/youtube_service.dart';

void main() {
  test('corte a mitad (chunk > 0, bytes ya recibidos) lanza con los 4 datos de diagnóstico', () {
    final service = YoutubeService();

    expect(
      () => service.checkMidChunkStatusForTesting(
        statusCode: 403,
        receivedSoFar: 5 * 1024 * 1024, // ya se había recibido el chunk 0 completo
        chunkIndex: 1,
        totalBytes: 20 * 1024 * 1024,
        manifestClientIndex: 0,
      ),
      throwsA(
        isA<MidDownloadCutException>()
            .having((e) => e.statusCode, 'statusCode', 403)
            .having((e) => e.chunkIndex, 'chunkIndex', 1)
            .having((e) => e.bytesReceived, 'bytesReceived', 5 * 1024 * 1024)
            .having((e) => e.totalBytes, 'totalBytes', 20 * 1024 * 1024)
            .having((e) => e.manifestClientIndex, 'manifestClientIndex', 0),
      ),
    );
  });

  test('el toString incluye los 4 datos, legible en un log real', () {
    late MidDownloadCutException caught;
    try {
      YoutubeService().checkMidChunkStatusForTesting(
        statusCode: 410,
        receivedSoFar: 12 * 1024 * 1024,
        chunkIndex: 3,
        totalBytes: 30 * 1024 * 1024,
        manifestClientIndex: 2,
      );
      fail('debería haber lanzado MidDownloadCutException');
    } on MidDownloadCutException catch (e) {
      caught = e;
    }

    final s = caught.toString();
    expect(s, contains('410'));
    expect(s, contains('chunk 3'));
    expect(s, contains('${12 * 1024 * 1024}'));
    expect(s, contains('#2'));
  });

  test('chunk 0 (nada recibido todavía) NO lanza — ese caso lo cubre el fallback sin Range', () {
    final service = YoutubeService();
    expect(
      () => service.checkMidChunkStatusForTesting(
        statusCode: 403,
        receivedSoFar: 0,
        chunkIndex: 0,
        totalBytes: 20 * 1024 * 1024,
        manifestClientIndex: 0,
      ),
      returnsNormally,
    );
  });

  test('status 200/206 nunca debería llegar acá, pero si llegara tampoco lanza '
      'con bytes ya recibidos (no es el ≠200/206 que dispara el chequeo)', () {
    // Documenta el contrato: el método sólo decide QUÉ HACER ante un status ya
    // sabido como distinto de 200/206; no vuelve a comprobar el status.
    final service = YoutubeService();
    expect(
      () => service.checkMidChunkStatusForTesting(
        statusCode: 200,
        receivedSoFar: 0,
        chunkIndex: 0,
        totalBytes: 20 * 1024 * 1024,
      ),
      returnsNormally,
    );
  });

  test('sin manifestClientIndex, igual lanza con manifestClientIndex/Names en null', () {
    expect(
      () => YoutubeService().checkMidChunkStatusForTesting(
        statusCode: 403,
        receivedSoFar: 5 * 1024 * 1024,
        chunkIndex: 1,
        totalBytes: 20 * 1024 * 1024,
      ),
      throwsA(
        isA<MidDownloadCutException>()
            .having((e) => e.manifestClientIndex, 'manifestClientIndex', isNull)
            .having((e) => e.manifestClientNames, 'manifestClientNames', isNull),
      ),
    );
  });
}
