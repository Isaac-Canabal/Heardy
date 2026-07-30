import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SAF (Storage Access Framework) access to the user-picked local music
/// folder. See CLAUDE.md D1 for why SAF over MediaStore/MANAGE_EXTERNAL_STORAGE.
class StorageService {
  static const String libraryFolderName = 'Heardy';
  static const String _libraryRootUriKey = 'heardy_library_root_uri';

  final SafUtil _safUtil = SafUtil();

  Future<String?> getLibraryRootUri() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_libraryRootUriKey);
  }

  /// Shows the system folder picker, creates/reuses a `Heardy/` folder
  /// inside the chosen location, and persists that folder's URI as the
  /// library root. Returns the root URI, or null if the user cancelled.
  Future<String?> pickLibraryRoot() async {
    final picked = await _safUtil.pickDirectory(
      writePermission: true,
      persistablePermission: true,
    );
    if (picked == null) return null;

    final heardyFolder = await _safUtil.mkdirp(picked.uri, [libraryFolderName]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_libraryRootUriKey, heardyFolder.uri);
    return heardyFolder.uri;
  }

  Future<bool> hasValidPermission(String uri) {
    return _safUtil.hasPersistedPermission(uri, checkRead: true, checkWrite: true);
  }

  Future<List<SafDocumentFile>> listChildren(String uri) => _safUtil.list(uri);
}
