/// Interfaz abstracta hacia el backend de cuentas en la nube (Etapa 16):
/// cuenta, biblioteca/historial sincronizados, amigos, "escuchando ahora".
///
/// Una sola interfaz para las cinco cosas, no cinco — `download_source.dart`
/// lleva escrito "No la hagas crecer sin un segundo proveedor real que lo
/// justifique", y aquí aplica igual: [CloudSource] existe para poder
/// inyectar un doble en tests (ver CLAUDE.md, "Cloud sync"), no para
/// intercambiar proveedores. [HeardyCloudSource] es la única implementación
/// real.
library;

enum CloudSourceErrorKind {
  /// Sin conexión/timeout — reintentable, nunca gasta el presupuesto de
  /// reintentos de quien llama.
  network,

  /// 401/403 — sesión ausente o token vencido.
  unauthorized,

  /// 404 — el nombre de usuario buscado no existe.
  notFound,

  /// 409 — nombre de usuario ocupado, o conflicto de versión de biblioteca
  /// (`library_version_conflict`, ver [CloudSourceException.isVersionConflict]).
  conflict,

  /// 429 con cuerpo — cupo diario agotado (búsquedas, solicitudes,
  /// subidas...). [CloudSourceException.retryAfterSeconds] cuando el
  /// servidor lo manda.
  quotaExceeded,

  /// 428 Precondition Required — la cuenta todavía no eligió nombre de
  /// usuario. Estado normal y duradero (E-5), no un error de verdad.
  needsUsername,

  /// 400/413/422 — payload rechazado (formato de nombre inválido, cuerpo
  /// demasiado grande, etc).
  badRequest,
}

class CloudSourceException implements Exception {
  final CloudSourceErrorKind kind;
  final String message;
  final int? retryAfterSeconds;
  final bool isVersionConflict;

  const CloudSourceException(
    this.kind,
    this.message, {
    this.retryAfterSeconds,
    this.isVersionConflict = false,
  });

  @override
  String toString() => 'CloudSourceException($kind, $message)';
}

class CloudAccount {
  final String identity;
  final String? username;
  final int libraryVersion;
  final bool hasLibrary;
  final int friendCount;

  const CloudAccount({
    required this.identity,
    required this.username,
    required this.libraryVersion,
    required this.hasLibrary,
    required this.friendCount,
  });

  factory CloudAccount.fromJson(Map<String, dynamic> json) => CloudAccount(
        identity: (json['identity'] ?? '').toString(),
        username: json['username'] as String?,
        libraryVersion: (json['libraryVersion'] as num?)?.toInt() ?? 0,
        hasLibrary: json['hasLibrary'] == true,
        friendCount: (json['friendCount'] as num?)?.toInt() ?? 0,
      );
}

class CloudLibrary {
  final int version;
  final List<Map<String, dynamic>> songs;
  final List<Map<String, dynamic>> playlists;
  final List<Map<String, dynamic>> playlistSongs;

  const CloudLibrary({
    required this.version,
    required this.songs,
    required this.playlists,
    required this.playlistSongs,
  });

  factory CloudLibrary.fromJson(Map<String, dynamic> json) => CloudLibrary(
        version: (json['version'] as num?)?.toInt() ?? 0,
        songs: List<Map<String, dynamic>>.from(json['songs'] as List? ?? const []),
        playlists: List<Map<String, dynamic>>.from(json['playlists'] as List? ?? const []),
        playlistSongs: List<Map<String, dynamic>>.from(json['playlistSongs'] as List? ?? const []),
      );
}

/// `null` cuando el servidor respondió 304 (nada cambió desde la versión
/// pedida) — distinto de una biblioteca vacía, que sí trae listas vacías.
typedef CloudLibraryOrNotModified = CloudLibrary?;

class HistoryPushResult {
  final int received;
  final int stored;
  final int skippedTooOld;

  const HistoryPushResult({required this.received, required this.stored, required this.skippedTooOld});

  factory HistoryPushResult.fromJson(Map<String, dynamic> json) => HistoryPushResult(
        received: (json['received'] as num?)?.toInt() ?? 0,
        stored: (json['stored'] as num?)?.toInt() ?? 0,
        skippedTooOld: (json['skippedTooOld'] as num?)?.toInt() ?? 0,
      );
}

class FriendEntry {
  final String username;
  final String? nowPlaying;

  const FriendEntry({required this.username, this.nowPlaying});

  factory FriendEntry.fromJson(Map<String, dynamic> json) => FriendEntry(
        username: (json['username'] ?? '').toString(),
        nowPlaying: json['nowPlaying'] as String?,
      );
}

class FriendsList {
  final List<FriendEntry> friends;
  final List<FriendEntry> incoming;
  final List<FriendEntry> outgoing;

  const FriendsList({required this.friends, required this.incoming, required this.outgoing});

  factory FriendsList.fromJson(Map<String, dynamic> json) => FriendsList(
        friends: (json['friends'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FriendEntry.fromJson)
            .toList(),
        incoming: (json['incoming'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FriendEntry.fromJson)
            .toList(),
        outgoing: (json['outgoing'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FriendEntry.fromJson)
            .toList(),
      );
}

enum UserRelation { self, friend, pendingOutgoing, pendingIncoming, none }

UserRelation _relationFromJson(String raw) => switch (raw) {
      'self' => UserRelation.self,
      'friend' => UserRelation.friend,
      'pending_outgoing' => UserRelation.pendingOutgoing,
      'pending_incoming' => UserRelation.pendingIncoming,
      _ => UserRelation.none,
    };

class UserLookupResult {
  final String username;
  final UserRelation relation;

  const UserLookupResult({required this.username, required this.relation});

  factory UserLookupResult.fromJson(Map<String, dynamic> json) => UserLookupResult(
        username: (json['username'] ?? '').toString(),
        relation: _relationFromJson((json['relation'] ?? '').toString()),
      );
}

abstract class CloudSource {
  Future<CloudAccount> getAccount();

  Future<String> setUsername(String username);

  Future<UserLookupResult> lookupUser(String username);

  Future<String> sendFriendRequest(String username); // "pending" | "accepted"

  Future<void> acceptFriendRequest(String username);

  Future<void> rejectOrCancelFriendRequest(String username);

  Future<void> removeFriend(String username);

  Future<FriendsList> getFriends();

  Future<CloudLibraryOrNotModified> getLibrary({String? ifNoneMatchVersion});

  Future<int> pushLibrary({
    required int baseVersion,
    String? contentHash,
    required List<Map<String, dynamic>> songs,
    required List<Map<String, dynamic>> playlists,
    required List<Map<String, dynamic>> playlistSongs,
  });

  Future<HistoryPushResult> pushHistory(List<Map<String, dynamic>> rows, {int? utcOffsetMinutes});

  Future<Map<String, dynamic>> getStatsMe({required String period, int? utcOffsetMinutes});

  Future<Map<String, dynamic>> getStatsFriend(String username, {required String period});

  Future<void> putPresence({required String songId, required int expiresInSeconds});

  Future<void> clearPresence();

  Future<bool> setShareNowPlaying(bool enabled);

  Future<void> deleteAccountData();
}
