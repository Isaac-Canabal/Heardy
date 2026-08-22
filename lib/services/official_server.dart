/// El servidor oficial mantenido por el proyecto: el modo por defecto para
/// que el usuario promedio nunca tenga que configurar nada. Ver
/// docs/arquitectura_servidor_hibrido.md, secciones 3 y 4.
library;

/// URL y clave por defecto que usa [SettingsProvider] mientras el usuario no
/// haya elegido explícitamente un servidor propio en Ajustes avanzados.
///
/// La URL es pública (es sólo un hostname) y puede vivir en el código sin
/// problema. La clave, en cambio, NO se comitea nunca — aunque sea de una
/// beta cerrada de pocas personas, sigue siendo un secreto: se inyecta en
/// tiempo de build con `--dart-define=HEARDY_OFFICIAL_SERVER_API_KEY=...`
/// y queda vacía en un build de desarrollo normal.
///
/// **Actualización 2026-08-22:** el servidor oficial pasó a Render
/// (`heardy.onrender.com`), con el experimento de cookies de sesión de
/// YouTube activo (`HEARDY_COOKIES_FILE`, ver CLAUDE.md → "Lo que quedó a
/// medias — el experimento de cookies") para esquivar el bloqueo anti-bot
/// que antes hacía inviable una IP de datacenter. Deja de depender de que
/// el PC de Isaac esté encendido — el costo es que las cookies expiran cada
/// pocos días y hay que renovarlas a mano; hay una rutina diaria vigilando
/// `/health` que avisa cuando pase. El hostname de Tailscale
/// (`laptop-vmiof47a.tail939abb.ts.net`) sigue siendo el servidor local de
/// desarrollo — se configura a mano en Ajustes avanzados, ya no es el
/// default.
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
