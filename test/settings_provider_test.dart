// Verifica el modo automático (docs/arquitectura_servidor_hibrido.md,
// sección 4): sin que el usuario toque nada, SettingsProvider ya apunta al
// servidor oficial. Cambiar a un servidor propio y volver atrás son las
// únicas dos acciones que le corresponden a Ajustes avanzados.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heardy/providers/settings_provider.dart';
import 'package:heardy/services/official_server.dart';

Future<void> _waitLoaded(SettingsProvider settings) async {
  for (var i = 0; i < 50 && !settings.isLoaded; i++) {
    await Future.delayed(const Duration(milliseconds: 1));
  }
  expect(settings.isLoaded, isTrue, reason: 'SettingsProvider no terminó de cargar a tiempo');
}

void main() {
  group('modo automático', () {
    test('sin nada guardado todavía, usa el servidor oficial por defecto', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await _waitLoaded(settings);

      expect(settings.downloadServerUrl, OfficialServer.url);
      expect(settings.downloadServerApiKey, OfficialServer.apiKey);
      expect(settings.hasDownloadServer, isTrue,
          reason: 'el modo automático no debe requerir configuración previa');
      expect(settings.isOfficialServer, isTrue);
    });

    test('un servidor guardado antes pisa el valor oficial al cargar', () async {
      SharedPreferences.setMockInitialValues({
        'download_server_url': 'http://mi-servidor:8080',
        'download_server_api_key': 'mi-clave',
      });
      final settings = SettingsProvider();
      await _waitLoaded(settings);

      expect(settings.downloadServerUrl, 'http://mi-servidor:8080');
      expect(settings.downloadServerApiKey, 'mi-clave');
      expect(settings.isOfficialServer, isFalse);
    });
  });

  group('cambiar y volver al servidor oficial', () {
    test('setDownloadServer deja de estar en el servidor oficial', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await _waitLoaded(settings);
      expect(settings.isOfficialServer, isTrue);

      await settings.setDownloadServer(url: 'http://propio:8080', apiKey: 'clave-propia');

      expect(settings.isOfficialServer, isFalse);
      expect(settings.downloadServerUrl, 'http://propio:8080');
      expect(settings.downloadServerApiKey, 'clave-propia');
    });

    test('setDownloadServer persiste: un provider nuevo retoma el servidor propio', () async {
      SharedPreferences.setMockInitialValues({});
      final primero = SettingsProvider();
      await _waitLoaded(primero);
      await primero.setDownloadServer(url: 'http://propio:9090', apiKey: 'k');

      final segundo = SettingsProvider();
      await _waitLoaded(segundo);

      expect(segundo.downloadServerUrl, 'http://propio:9090');
      expect(segundo.isOfficialServer, isFalse);
    });

    test('restoreOfficialServer vuelve al oficial y lo persiste', () async {
      SharedPreferences.setMockInitialValues({
        'download_server_url': 'http://propio:8080',
        'download_server_api_key': 'clave-propia',
      });
      final settings = SettingsProvider();
      await _waitLoaded(settings);
      expect(settings.isOfficialServer, isFalse);

      await settings.restoreOfficialServer();

      expect(settings.isOfficialServer, isTrue);
      expect(settings.downloadServerUrl, OfficialServer.url);
      expect(settings.downloadServerApiKey, OfficialServer.apiKey);

      // Y sobrevive a un provider nuevo, como cualquier otro cambio guardado.
      final otro = SettingsProvider();
      await _waitLoaded(otro);
      expect(otro.isOfficialServer, isTrue);
    });
  });
}
