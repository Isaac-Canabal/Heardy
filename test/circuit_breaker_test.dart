// Cobertura del techo del circuit breaker (docs/investigacion_muro_antibot.md,
// sesión 2026-07-28): el techo de escalada pasó de 180s a 20 min porque la
// ventana real de recuperación medida es de 20-40+ min, no minutos. Este test
// no depende de la red — usa los hooks `@visibleForTesting` de
// `YoutubeService` para invocar `_recordBlock` directamente y verificar la
// secuencia de escalada sin esperar los cooldowns reales.
import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/youtube_service.dart';

void main() {
  setUp(YoutubeService.resetCircuitBreaker);

  test('escala 20, 40, 80, 160, 320, 640 y luego se topa en 1200s (20 min)', () {
    final service = YoutubeService();
    const expectedSeconds = [20, 40, 80, 160, 320, 640, 1200, 1200];

    for (final expected in expectedSeconds) {
      service.recordBlockForTesting();
      final remaining = YoutubeService.blockedRemainingForTesting;
      expect(remaining, isNotNull, reason: 'debería haber un cooldown activo');
      // Margen de 2s por el tiempo real que tarda en correr el test.
      expect(remaining!.inSeconds, closeTo(expected, 2));
      YoutubeService.clearActiveCooldownForTesting();
    }
  });

  test('no crece sin límite más allá de 1200s aunque siga bloqueando', () {
    final service = YoutubeService();
    for (var i = 0; i < 20; i++) {
      service.recordBlockForTesting();
      final remaining = YoutubeService.blockedRemainingForTesting!;
      expect(remaining.inSeconds, lessThanOrEqualTo(1200));
      YoutubeService.clearActiveCooldownForTesting();
    }
  });

  test('no escala mientras haya un cooldown activo (evita que varios workers '
      'concurrentes atropellen la misma escalada)', () {
    final service = YoutubeService();
    service.recordBlockForTesting();
    final first = YoutubeService.blockedRemainingForTesting!.inSeconds;
    expect(first, closeTo(20, 2));

    // Sin `clearActiveCooldownForTesting()` de por medio: el cooldown de arriba
    // sigue activo, así que esta llamada no debería escalar a 40s.
    service.recordBlockForTesting();
    final second = YoutubeService.blockedRemainingForTesting!.inSeconds;
    expect(second, closeTo(20, 2));
  });

  test('resetCircuitBreaker vuelve la escalada a 20s', () {
    final service = YoutubeService();
    service.recordBlockForTesting();
    YoutubeService.clearActiveCooldownForTesting();
    service.recordBlockForTesting();
    expect(YoutubeService.blockedRemainingForTesting!.inSeconds, closeTo(40, 2));

    YoutubeService.resetCircuitBreaker();
    service.recordBlockForTesting();
    expect(YoutubeService.blockedRemainingForTesting!.inSeconds, closeTo(20, 2));
  });
}
