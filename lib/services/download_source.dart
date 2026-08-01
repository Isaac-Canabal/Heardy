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

  /// El servidor respondió, pero no pudo extraer (vídeo privado, borrado,
  /// bloqueado por región, o YouTube bloqueando su IP).
  extraction,

  /// El vídeo no tiene ninguna pista de audio AAC/M4A. Definitivo: no tiene
  /// sentido reintentarlo.
  unsupportedMedia,

  /// El usuario canceló.
  cancelled,
}

class DownloadSourceException implements Exception {
  final DownloadSourceErrorKind kind;
  final String message;

  const DownloadSourceException(this.kind, this.message);

  /// True si reintentar más tarde tiene alguna posibilidad de funcionar.
  bool get isRetryable =>
      kind == DownloadSourceErrorKind.network || kind == DownloadSourceErrorKind.extraction;

  /// Mensaje para enseñar al usuario, ya en el idioma de la app.
  String get userMessage => switch (kind) {
        DownloadSourceErrorKind.notConfigured =>
          'Configura la dirección del servidor de descargas en Ajustes',
        DownloadSourceErrorKind.network =>
          'No se pudo contactar con el servidor de descargas',
        DownloadSourceErrorKind.unauthorized =>
          'La clave de API del servidor no es válida',
        DownloadSourceErrorKind.extraction => message,
        DownloadSourceErrorKind.unsupportedMedia =>
          'Ese vídeo no tiene una pista de audio compatible',
        DownloadSourceErrorKind.cancelled => 'Descarga cancelada',
      };

  @override
  String toString() => 'DownloadSourceException($kind): $message';
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
