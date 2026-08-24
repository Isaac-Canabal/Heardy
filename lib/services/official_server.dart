/// El servidor oficial mantenido por el proyecto: el modo por defecto para
/// que el usuario promedio nunca tenga que configurar nada. Ver
/// docs/arquitectura_servidor_hibrido.md, secciones 3 y 4.
library;

/// URL y clave por defecto que usa [SettingsProvider] mientras el usuario no
/// haya elegido explícitamente un servidor propio en Ajustes avanzados.
///
/// La URL del servidor oficial es pública (es sólo un hostname de Render, un
/// servicio compartido) y puede vivir en el código sin problema. **Ojo con
/// esto si el servidor vuelve a ser casero:** un hostname de Tailscale Funnel
/// nombra una máquina personal, y este repositorio es público — ese caso va
/// por `--dart-define`, nunca como `defaultValue` acá.
///
/// La clave, en cambio, NO se comitea nunca — aunque sea de una beta cerrada
/// de pocas personas, sigue siendo un secreto: se inyecta en tiempo de build
/// con `--dart-define=HEARDY_OFFICIAL_SERVER_API_KEY=...` y queda vacía en un
/// build de desarrollo normal.
///
/// **Actualización 2026-08-22:** el servidor oficial pasó a Render
/// (`heardy.onrender.com`), con cookies de sesión de YouTube
/// (`HEARDY_COOKIES_FILE`) para esquivar el bloqueo anti-bot que antes hacía
/// inviable una IP de datacenter. Ya no depende de que ningún PC concreto
/// esté encendido.
///
/// **Actualización 2026-08-24: esta dirección ya no se puede cambiar desde
/// la app.** Antes se podía pisar en "Ajustes avanzados" y quedaba guardada
/// en `SharedPreferences`; eso desapareció (ver
/// `SettingsProvider.downloadServerUrl`), porque el servidor oficial es uno
/// solo y estable, y lo único que conseguía un campo editable era que
/// alguien se rompiera las descargas sin saber volver. Para apuntar a otro
/// servidor —el flujo de desarrollo contra `server/` en local— se usa
/// `--dart-define=HEARDY_OFFICIAL_SERVER_URL=...` en tiempo de build, que es
/// donde corresponde. Por eso ambos valores siguen siendo
/// `String.fromEnvironment` y no constantes literales.
class OfficialServer {
  const OfficialServer._();

  static const String url = String.fromEnvironment(
    'HEARDY_OFFICIAL_SERVER_URL',
    defaultValue: 'https://heardy.onrender.com',
  );

  static const String apiKey = String.fromEnvironment(
    'HEARDY_OFFICIAL_SERVER_API_KEY',
  );
}
