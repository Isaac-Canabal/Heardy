// Cubre `shouldRecordPlay`, la única pieza de la lógica de estadísticas de
// reproducción que es una función pura y por tanto testeable sin un doble de
// `just_audio` (que este codebase no tiene — ver CLAUDE.md, "Testing").
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/audio_player_handler.dart';

void main() {
  group('shouldRecordPlay', () {
    test('por debajo del 50% no cuenta', () {
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 89),
          duration: const Duration(seconds: 180),
        ),
        isFalse,
      );
    });

    test('al 50% exacto o más sí cuenta', () {
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 90),
          duration: const Duration(seconds: 180),
        ),
        isTrue,
      );
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 180),
          duration: const Duration(seconds: 180),
        ),
        isTrue,
      );
    });

    test('el umbral se redondea hacia arriba, nunca a favor del usuario', () {
      // 50% de 181s son 90.5s → 91, no 90.
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 90),
          duration: const Duration(seconds: 181),
        ),
        isFalse,
      );
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 91),
          duration: const Duration(seconds: 181),
        ),
        isTrue,
      );
    });

    test('duración desconocida o inválida nunca cuenta', () {
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 30),
          duration: Duration.zero,
        ),
        isFalse,
      );
    });
  });
}
