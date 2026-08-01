import 'dart:typed_data';

import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SAF (Storage Access Framework) access to the user-picked local music
/// folder. See CLAUDE.md D1 for why SAF over MediaStore/MANAGE_EXTERNAL_STORAGE.
///
/// Owns the whole lifecycle of the library root: picking it, recognizing an
/// already-initialized one so re-picking never nests `Heardy/` inside
/// itself, and clearing it when it turns out to be gone.
class StorageService {
  static const String libraryFolderName = 'Heardy';
  static const String _rootMarkerFileName = '.heardy_root';
  static const String _libraryRootUriKey = 'heardy_library_root_uri';

  final SafUtil _safUtil = SafUtil();
  final SafStream _safStream = SafStream();

  Future<String?> getLibraryRootUri() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_libraryRootUriKey);
  }

  /// Forgets the stored root — e.g. after a scan discovers it's gone.
  Future<void> clearLibraryRootUri() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_libraryRootUriKey);
  }

  /// Shows the system folder picker and resolves it to a library root.
  /// Returns null if the user cancelled.
  ///
  /// Three cases, so re-picking never nests `Heardy/` inside itself:
  /// - the chosen folder already has the root marker (any name) -> use it
  ///   as-is;
  /// - it doesn't, but it's literally named "Heardy" (a root from before
  ///   this marker existed, or the user pointed straight at a folder with
  ///   that name) -> use it as-is and write the marker retroactively;
  /// - otherwise -> create/reuse a "Heardy" child of the chosen folder
  ///   (looked up first, never blindly `mkdirp`'d, so re-picking the same
  ///   parent doesn't create a second one either) and mark that.
  Future<String?> pickLibraryRoot() async {
    final picked = await _safUtil.pickDirectory(
      writePermission: true,
      persistablePermission: true,
    );
    if (picked == null) return null;

    final String rootUri;
    if (await _hasRootMarker(picked.uri)) {
      rootUri = picked.uri;
    } else if (picked.name.toLowerCase() == libraryFolderName.toLowerCase()) {
      rootUri = picked.uri;
      await _writeRootMarker(rootUri);
    } else {
      final existingChild = await _findChildDir(picked.uri, libraryFolderName);
      if (existingChild != null) {
        rootUri = existingChild.uri;
        if (!await _hasRootMarker(rootUri)) {
          await _writeRootMarker(rootUri);
        }
      } else {
        final created = await _safUtil.mkdirp(picked.uri, [libraryFolderName]);
        rootUri = created.uri;
        await _writeRootMarker(rootUri);
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_libraryRootUriKey, rootUri);
    return rootUri;
  }

  Future<bool> hasValidPermission(String uri) {
    return _safUtil.hasPersistedPermission(uri, checkRead: true, checkWrite: true);
  }

  /// Carpeta de una playlist dentro de la raíz, creándola si no existe.
  ///
  /// Es el único punto donde la app crea algo en la carpeta del usuario, y lo
  /// hace por la enmienda a D3 (ver CLAUDE.md, DD3): crear archivos nuevos en
  /// la carpeta que el usuario eligió para su música es el mecanismo de
  /// importación. Lo que sigue prohibido es reorganizar o reescribir lo que
  /// ya estaba ahí.
  ///
  /// Se busca con `child()` antes de `mkdirp()`, misma cautela que
  /// [pickLibraryRoot], para no acabar con dos carpetas del mismo nombre.
  Future<String> resolvePlaylistFolder(String rootUri, String playlistName) async {
    final safeName = sanitizeFolderName(playlistName);
    final existing = await _findChildDir(rootUri, safeName);
    if (existing != null) return existing.uri;
    final created = await _safUtil.mkdirp(rootUri, [safeName]);
    return created.uri;
  }

  /// Quita lo que ningún sistema de archivos de Android acepta en un nombre.
  /// Nunca devuelve vacío: un nombre de playlist compuesto solo de caracteres
  /// prohibidos crearía una carpeta sin nombre.
  static String sanitizeFolderName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        // Un punto final lo descarta FAT32, común en tarjetas SD.
        .replaceAll(RegExp(r'\.+$'), '')
        .trim();
    if (cleaned.isEmpty) return 'Sin nombre';
    return cleaned.length > 100 ? cleaned.substring(0, 100).trim() : cleaned;
  }

  Future<List<SafDocumentFile>> listChildren(String uri) => _safUtil.list(uri);

  Future<SafDocumentFile?> _findChildDir(String parentUri, String name) async {
    try {
      final child = await _safUtil.child(parentUri, [name]);
      return (child != null && child.isDir) ? child : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _hasRootMarker(String folderUri) async {
    try {
      final marker = await _safUtil.child(folderUri, [_rootMarkerFileName]);
      return marker != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeRootMarker(String folderUri) async {
    try {
      await _safStream.writeFileBytes(
        folderUri,
        _rootMarkerFileName,
        'text/plain',
        Uint8List(0),
        overwrite: true,
      );
    } catch (e) {
      print('StorageService: no se pudo escribir el marcador de raíz en $folderUri: $e');
    }
  }
}
