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
/// **Actualización 2026-08-03:** el servidor oficial ya no va en Oracle
/// Cloud (fricción de verificación de cuenta, ver `server/README.md` →
/// "Despliegue oficial"). Corre en el PC de casa de Isaac y se publica con
/// Tailscale Funnel (`tailscale funnel --bg 8080`), que le da este hostname
/// estable mientras no cambie de máquina — confirmado con
/// `tailscale funnel status` y probado con `/health` real desde fuera de la
/// red local el 2026-08-03. Si el servidor se muda de PC, este valor es lo
/// único que hay que actualizar (ver `tailscale funnel status` en la máquina
/// nueva).
class OfficialServer {
  const OfficialServer._();

  static const String url = String.fromEnvironment(
    'HEARDY_OFFICIAL_SERVER_URL',
    defaultValue: 'https://laptop-vmiof47a.tail939abb.ts.net',
  );

  static const String apiKey = String.fromEnvironment(
    'HEARDY_OFFICIAL_SERVER_API_KEY',
  );
}
