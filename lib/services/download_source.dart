/// Abstracción sobre "de dónde salen los bytes de audio".
///
/// Existe para que cambiar de proveedor (hoy el microservidor yt-dlp propio,
/// mañana una API comercial si hiciera falta) sea una implementación nueva y
/// no un rediseño. Ver CLAUDE.md DD1.
///
/// **No la hagas crecer sin un segundo proveedor real que lo justifique.**
library;

/// Una pista remota ya resuelta, lista para descargar.
class RemoteTrack {
  /// Id en la fuente (para YouTube, el id de vídeo de 11 caracteres).
  final String id;
  final String title;
  final String artist;
  final String? album;
  final int durationSeconds;
  final String thumbnailUrl;

  /// URL canónica de origen. Se persiste en `songs.sourceUrl` para poder
  /// detectar "esto ya está descargado" sin gastar red.
  final String sourceUrl;

  const RemoteTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    required this.thumbnailUrl,
    required this.sourceUrl,
  });

  factory RemoteTrack.fromJson(Map<String, dynamic> json) {
    return RemoteTrack(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      artist: (json['artist'] ?? '').toString(),
      album: (json['album'] as String?)?.trim().isEmpty ?? true ? null : json['album'] as String,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
      thumbnailUrl: (json['thumbnailUrl'] ?? '').toString(),
      sourceUrl: (json['sourceUrl'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'durationSeconds': durationSeconds,
        'thumbnailUrl': thumbnailUrl,
        'sourceUrl': sourceUrl,
      };
}

/// Una playlist remota ya expandida.
class RemotePlaylist {
  final String id;
  final String name;
  final String sourceUrl;
  final List<RemoteTrack> entries;

  const RemotePlaylist({
    required this.id,
    required this.name,
    required this.sourceUrl,
    required this.entries,
  });

  factory RemotePlaylist.fromJson(Map<String, dynamic> json) {
    final rawEntries = (json['entries'] as List<dynamic>? ?? const []);
    return RemotePlaylist(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? 'Playlist').toString(),
      sourceUrl: (json['sourceUrl'] ?? '').toString(),
      entries: rawEntries
          .whereType<Map<String, dynamic>>()
          .map(RemoteTrack.fromJson)
          .where((t) => t.id.isNotEmpty)
          .toList(),
    );
  }
}

/// Por qué falló una operación. La UI y la cola de descargas necesitan
/// distinguirlos: solo [network] y [server] merecen reintento, y solo
/// [notConfigured] y [unauthorized] se arreglan tocando ajustes.
enum DownloadSourceErrorKind {
  /// No hay URL de servidor configurada todavía.
  notConfigured,

  /// El servidor no responde: apagado, fuera de la VPN, sin red.
  network,

  /// X-Api-Key ausente o incorrecta.
  unauthorized,

  /// El servidor respondió pero no pudo extraer, y el fallo **puede ser
  /// pasajero**: su IP bloqueada por YouTube, un corte de red por su lado.
  /// Reintentar tiene sentido.
  extraction,

  /// El vídeo ya no existe para nadie: borrado, privado, sólo para miembros,
  /// con restricción de edad, o la URL no era válida. **Definitivo.**
  /// Reintentar no puede funcionar nunca, así que la cola lo descarta en vez
  /// de gastar en él su presupuesto de reintentos.
  notFound,

  /// El vídeo no tiene ninguna pista de audio AAC/M4A. Definitivo: no tiene
  /// sentido reintentarlo.
  unsupportedMedia,

  /// El propio servidor rechazó la petición por límite de peticiones (HTTP
  /// 429) — no es YouTube bloqueando, es el servidor autolimitándose para
  /// proteger el presupuesto de IP compartido. A diferencia de [extraction],
  /// este caso sí sabe con certeza cuánto esperar:
  /// [DownloadSourceException.retryAfterSeconds] trae el valor exacto que
  /// calculó el servidor a partir de su propia ventana. Ver
  /// docs/arquitectura_servidor_hibrido.md, sección 5.
  quotaExceeded,

  /// El muro anti-bot de YouTube específicamente ("Sign in to confirm you're
  /// not a bot"), distinto de [extraction] genérico (HTTP 503, no 502 — ver
  /// `server/app/ytdlp_client.py`'s `AntiBotBlockError`). Temporal, pero con
  /// una ventana de recuperación medida en **20-40+ minutos**
  /// (`docs/investigacion_muro_antibot.md`), no los segundos que basta
  /// esperar tras un [extraction] cualquiera — el backoff corto de la cola
  /// se agotaría mucho antes de que esto se despeje, descartando de la cola
  /// canciones perfectamente descargables. Igual que con [quotaExceeded],
  /// nunca se inventa un tiempo exacto acá: no hay `Retry-After` real que
  /// mandar, sólo el rango medido.
  antiBotBlocked,

  /// El usuario canceló.
  cancelled,
}

class DownloadSourceException implements Exception {
  final DownloadSourceErrorKind kind;
  final String message;

  /// Sólo tiene valor para [DownloadSourceErrorKind.quotaExceeded]: los
  /// segundos exactos que el servidor calculó a partir de su propia ventana
  /// de límite (cabecera `Retry-After`, RFC 9110). Nunca se inventa un
  /// número aquí — si el servidor no lo mandó, queda en null y quien lo
  /// consuma debe mostrar un mensaje aproximado, no una cuenta atrás falsa.
  final int? retryAfterSeconds;

  const DownloadSourceException(this.kind, this.message, {this.retryAfterSeconds});

  /// True si reintentar más tarde tiene alguna posibilidad de funcionar.
  ///
  /// Es lo único que la cola mira para decidir entre reintentar y descartar,
  /// así que clasificar mal un error se paga de una de dos formas: gastar el
  /// presupuesto de reintentos en un vídeo que ya no existe, o tirar una
  /// canción perfectamente descargable por un corte de red de un segundo.
  bool get isRetryable =>
      kind == DownloadSourceErrorKind.network ||
      kind == DownloadSourceErrorKind.extraction ||
      kind == DownloadSourceErrorKind.quotaExceeded ||
      kind == DownloadSourceErrorKind.antiBotBlocked;

  /// Mensaje para enseñar al usuario, ya en el idioma de la app.
  String get userMessage => switch (kind) {
        DownloadSourceErrorKind.notConfigured =>
          'Configura la dirección del servidor de descargas en Ajustes',
        DownloadSourceErrorKind.network =>
          'No se pudo contactar con el servidor de descargas',
        DownloadSourceErrorKind.unauthorized =>
          'La clave de API del servidor no es válida',
        DownloadSourceErrorKind.extraction => message,
        DownloadSourceErrorKind.notFound =>
          'Ese vídeo ya no está disponible (borrado, privado o restringido)',
        DownloadSourceErrorKind.unsupportedMedia =>
          'Ese vídeo no tiene una pista de audio compatible',
        DownloadSourceErrorKind.quotaExceeded => retryAfterSeconds != null
            ? 'Límite del servidor alcanzado. Probá de nuevo en ${_formatRetryAfter(retryAfterSeconds!)}'
            : 'Límite del servidor alcanzado. Probá de nuevo más tarde',
        // Sin número: el rango de 20-40 min es lo único medido de verdad
        // (docs/investigacion_muro_antibot.md), inventar una cifra exacta
        // sería mentirle al usuario. Se reintenta solo igual.
        DownloadSourceErrorKind.antiBotBlocked =>
          'YouTube bloqueó temporalmente al servidor. Puede tardar entre 20 y 40 minutos; se reintentará solo',
        DownloadSourceErrorKind.cancelled => 'Descarga cancelada',
      };

  @override
  String toString() => 'DownloadSourceException($kind): $message'
      '${retryAfterSeconds != null ? ' (retryAfter=${retryAfterSeconds}s)' : ''}';
}

/// "3 minutos", "1 minuto", "unos segundos" — nunca un número exacto de
/// segundos: es una cifra que viene de un header HTTP, no algo que un
/// usuario deba leer al pie de la letra.
String _formatRetryAfter(int seconds) {
  if (seconds < 60) return 'unos segundos';
  final minutes = (seconds / 60).ceil();
  return minutes == 1 ? '1 minuto' : '$minutes minutos';
}

/// Estado del servidor, para el botón "Probar conexión" de Ajustes.
class DownloadSourceStatus {
  final bool reachable;
  final bool authenticated;
  final String? version;

  /// True si el proveedor de PO tokens responde. Si es false el servidor
  /// arranca igual pero la mayoría de descargas fallarán con 403, así que
  /// merece avisar en vez de dejar que el usuario lo descubra descargando.
  final bool potProviderReachable;
  final String detail;

  const DownloadSourceStatus({
    required this.reachable,
    required this.authenticated,
    required this.version,
    required this.potProviderReachable,
    required this.detail,
  });
}

typedef ProgressCallback = void Function(int receivedBytes, int? totalBytes);
typedef CancellationCheck = bool Function();

abstract class DownloadSource {
  /// Metadata de un vídeo suelto.
  Future<RemoteTrack> resolve(String url);

  /// Expande una playlist a sus pistas.
  Future<RemotePlaylist> resolvePlaylist(String url);

  /// Busca por texto.
  Future<List<RemoteTrack>> search(String query, {int limit});

  /// Descarga el audio de [trackId] a [destPath].
  ///
  /// [onProgress] puede tardar en recibir su primera llamada: el servidor
  /// baja el vídeo antes de empezar a transferir.
  Future<void> fetchAudio(
    String trackId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  });

  /// Diagnóstico para Ajustes. No lanza: devuelve el estado.
  Future<DownloadSourceStatus> probe();
}
