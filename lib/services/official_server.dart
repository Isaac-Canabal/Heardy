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
/// Mientras el servidor oficial no esté desplegado de verdad (ver
/// CLAUDE.md, sección "YouTube downloads" → Oracle Cloud), esta URL
/// simplemente no responde todavía: el manejo de errores que ya existe
/// (`DownloadSourceErrorKind.network`) cubre ese estado sin nada especial —
/// la app se comporta exactamente como si el usuario hubiera escrito una
/// dirección incorrecta, que es justo lo que es hasta que se despliegue.
class OfficialServer {
  const OfficialServer._();

  static const String url = String.fromEnvironment(
    'HEARDY_OFFICIAL_SERVER_URL',
    defaultValue: 'https://heardy-oficial.duckdns.org',
  );

  static const String apiKey = String.fromEnvironment(
    'HEARDY_OFFICIAL_SERVER_API_KEY',
  );
}
