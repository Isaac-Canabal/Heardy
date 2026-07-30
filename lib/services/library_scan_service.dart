import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
import 'package:uuid/uuid.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import 'database_helper.dart';

/// Scans the SAF-backed library folder into SQLite. See CLAUDE.md D2/D3 for
/// the reconciliation rules this implements — do not re-derive them here.
class LibraryScanResult {
  final int inserted;
  final int moved;
  final int updated;
  final int unchanged;
  final int unsupported;
  final int missing;

  const LibraryScanResult({
    required this.inserted,
    required this.moved,
    required this.updated,
    required this.unchanged,
    required this.unsupported,
    required this.missing,
  });
}

enum _FileOutcome { inserted, moved, updated, unchanged, unsupported }

class _ByteRange {
  final int start;
  final int length;
  const _ByteRange(this.start, this.length);
}

class _HashResult {
  final String hash;
  final String kind;
  const _HashResult(this.hash, this.kind);
}

class LibraryScanService {
  static const _audioExtensions = {'mp3', 'mp4', 'm4a'};
  static const _headTailSize = 64 * 1024;

  final SafUtil _safUtil = SafUtil();
  final SafStream _safStream = SafStream();
  final DatabaseHelper _db = DatabaseHelper.instance;

  Future<LibraryScanResult> scan(String libraryRootUri) async {
    await _db.markAllImportedSongsMissing();

    var inserted = 0, moved = 0, updated = 0, unchanged = 0, unsupported = 0;

    final playlistIdByName = <String, String>{};
    for (final playlist in await _db.getPlaylists()) {
      playlistIdByName[playlist.name] = playlist.id;
    }

    final rootChildren = await _safUtil.list(libraryRootUri);
    for (final entry in rootChildren) {
      if (entry.isDir) {
        final playlistId = await _resolvePlaylistId(entry.name, playlistIdByName);
        final children = await _safUtil.list(entry.uri);
        for (final file in children) {
          if (file.isDir) continue; // nested subfolders aren't supported
          final outcome = await _reconcileFile(file, playlistId: playlistId);
          switch (outcome) {
            case _FileOutcome.inserted:
              inserted++;
            case _FileOutcome.moved:
              moved++;
            case _FileOutcome.updated:
              updated++;
            case _FileOutcome.unchanged:
              unchanged++;
            case _FileOutcome.unsupported:
              unsupported++;
          }
        }
      } else {
        // Loose file directly in the library root: imported with no
        // playlist, so it lands in the inbox (D6).
        final outcome = await _reconcileFile(entry, playlistId: null);
        switch (outcome) {
          case _FileOutcome.inserted:
            inserted++;
          case _FileOutcome.moved:
            moved++;
          case _FileOutcome.updated:
            updated++;
          case _FileOutcome.unchanged:
            unchanged++;
          case _FileOutcome.unsupported:
            unsupported++;
        }
      }
    }

    final missing = await _db.getMissingImportedSongCount();
    return LibraryScanResult(
      inserted: inserted,
      moved: moved,
      updated: updated,
      unchanged: unchanged,
      unsupported: unsupported,
      missing: missing,
    );
  }

  Future<String> _resolvePlaylistId(String name, Map<String, String> cache) async {
    final cached = cache[name];
    if (cached != null) return cached;
    final id = const Uuid().v4();
    await _db.insertPlaylist(Playlist(id: id, name: name, creationDate: DateTime.now()));
    cache[name] = id;
    return id;
  }

  Future<_FileOutcome> _reconcileFile(
    SafDocumentFile file, {
    required String? playlistId,
  }) async {
    final ext = _extensionOf(file.name);
    if (!_audioExtensions.contains(ext)) return _FileOutcome.unsupported;

    // Matcher 1: same URI as last scan (D2). Covers the common no-change
    // case (skip hashing entirely) and in-place tag edits (same file,
    // different size/mtime).
    final existingByUri = await _db.getSongByUri(file.uri);
    if (existingByUri != null) {
      if (existingByUri.fileSize == file.length && existingByUri.modifiedAt == file.lastModified) {
        await _db.touchSongFound(
          existingByUri.id,
          uri: file.uri,
          fileSize: file.length,
          modifiedAt: file.lastModified,
        );
        return _FileOutcome.unchanged;
      }

      final hash = await _hashAudioPayload(file, ext);
      await _db.touchSongFound(
        existingByUri.id,
        uri: file.uri,
        fileSize: file.length,
        modifiedAt: file.lastModified,
        fileHash: hash.hash,
        hashKind: hash.kind,
      );
      return _FileOutcome.updated;
    }

    // Matcher 2: unknown URI, but the audio payload matches an existing
    // row (D2) — a move or rename. Playlist membership is left untouched;
    // per D3 the folder only assigns a playlist on first insert.
    final hash = await _hashAudioPayload(file, ext);
    final existingByHash = await _db.getSongByHash(hash.hash);
    if (existingByHash != null) {
      await _db.touchSongFound(
        existingByHash.id,
        uri: file.uri,
        fileSize: file.length,
        modifiedAt: file.lastModified,
        fileHash: hash.hash,
        hashKind: hash.kind,
      );
      return _FileOutcome.moved;
    }

    // Genuinely new song. Title/artist here are a placeholder — real tag
    // reading is Stage 2 (D5); this stage only needs a stable id and a
    // non-empty title.
    final song = Song(
      id: hash.hash,
      title: _titleFromFilename(file.name),
      artist: 'Desconocido',
      duration: 0,
      filePath: '',
      artPath: '',
      format: ext,
      downloadDate: DateTime.now(),
      uri: file.uri,
      fileHash: hash.hash,
      hashKind: hash.kind,
      fileSize: file.length,
      modifiedAt: file.lastModified,
    );
    await _db.insertSong(song);

    if (playlistId != null) {
      final maxOrder = await _db.getMaxOrderForPlaylist(playlistId) ?? -1;
      await _db.addSongToPlaylist(playlistId, song.id, maxOrder + 1);
    }

    return _FileOutcome.inserted;
  }

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot == -1 ? '' : name.substring(dot + 1).toLowerCase();
  }

  String _titleFromFilename(String name) {
    final dot = name.lastIndexOf('.');
    return dot == -1 ? name : name.substring(0, dot);
  }

  /// Hashes the audio payload of [file], skipping tag blocks so ID3/APE
  /// edits don't change the identity of an otherwise-untouched file (D2).
  /// Falls back to hashing the whole file if the container can't be parsed.
  Future<_HashResult> _hashAudioPayload(SafDocumentFile file, String ext) async {
    try {
      if (ext == 'mp3') {
        final bounds = await _mp3PayloadBounds(file.uri, file.length);
        final hash = await _hashRange(file.uri, bounds);
        return _HashResult(hash, 'mp3-audio');
      }
      if (ext == 'mp4' || ext == 'm4a') {
        final bounds = await _mp4MdatBounds(file.uri, file.length);
        if (bounds != null) {
          final hash = await _hashRange(file.uri, bounds);
          return _HashResult(hash, 'mp4-mdat');
        }
      }
    } catch (e) {
      print('LibraryScanService: falling back to raw-file hash for ${file.name}: $e');
    }
    final hash = await _hashRange(file.uri, _ByteRange(0, file.length));
    return _HashResult(hash, 'raw-file');
  }

  Future<String> _hashRange(String uri, _ByteRange range) async {
    final builder = BytesBuilder();
    final lengthPrefix = ByteData(8)..setUint64(0, range.length, Endian.big);
    builder.add(lengthPrefix.buffer.asUint8List());

    if (range.length <= _headTailSize * 2) {
      builder.add(await _safStream.readFileBytes(uri, start: range.start, count: range.length));
    } else {
      builder.add(await _safStream.readFileBytes(uri, start: range.start, count: _headTailSize));
      builder.add(await _safStream.readFileBytes(
        uri,
        start: range.start + range.length - _headTailSize,
        count: _headTailSize,
      ));
    }

    return md5.convert(builder.toBytes()).toString();
  }

  /// ID3v2 header (start) + ID3v1/APEv2 (end) bounds around the raw MPEG
  /// audio frames.
  Future<_ByteRange> _mp3PayloadBounds(String uri, int fileLength) async {
    var headerSize = 0;
    if (fileLength >= 10) {
      final header = await _safStream.readFileBytes(uri, start: 0, count: 10);
      if (header.length == 10 && header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33) {
        // ID3v2: 4 syncsafe bytes (7 bits each), optional 10-byte footer.
        final size = ((header[6] & 0x7F) << 21) |
            ((header[7] & 0x7F) << 14) |
            ((header[8] & 0x7F) << 7) |
            (header[9] & 0x7F);
        final hasFooter = (header[5] & 0x10) != 0;
        headerSize = 10 + size + (hasFooter ? 10 : 0);
      }
    }

    var trailerSize = 0;
    final tailWindow = fileLength < 160 ? fileLength : 160;
    if (tailWindow >= 32) {
      final tail = await _safStream.readFileBytes(uri, start: fileLength - tailWindow, count: tailWindow);
      if (tail.length >= 128 &&
          tail[tail.length - 128] == 0x54 &&
          tail[tail.length - 127] == 0x41 &&
          tail[tail.length - 126] == 0x47) {
        trailerSize = 128; // ID3v1: literal "TAG" + 125 bytes
      }
      final beforeTrailer = tail.length - trailerSize;
      if (beforeTrailer >= 32) {
        final footer = tail.sublist(beforeTrailer - 32, beforeTrailer);
        if (_bytesStartWithAscii(footer, 'APETAGEX')) {
          // APEv2 footer: tag size at offset 12, little-endian, includes
          // the optional header but not this footer.
          final tagSize = footer[12] | (footer[13] << 8) | (footer[14] << 16) | (footer[15] << 24);
          trailerSize += 32 + tagSize;
        }
      }
    }

    final payloadLength = fileLength - headerSize - trailerSize;
    if (payloadLength <= 0) {
      throw StateError('mp3 tag bounds collapsed the payload (file=$fileLength header=$headerSize trailer=$trailerSize)');
    }
    return _ByteRange(headerSize, payloadLength);
  }

  /// Walks top-level MP4 boxes to find `mdat`'s payload, without reading
  /// the metadata boxes (`moov`/`udta`/`ilst`) that tag edits rewrite.
  Future<_ByteRange?> _mp4MdatBounds(String uri, int fileLength) async {
    var offset = 0;
    var iterations = 0;
    while (offset < fileLength && iterations < 64) {
      iterations++;
      final header = await _safStream.readFileBytes(uri, start: offset, count: 16);
      if (header.length < 8) return null;

      final size32 = _readUint32BE(header, 0);
      final type = String.fromCharCodes(header.sublist(4, 8));

      int boxSize;
      var headerLen = 8;
      if (size32 == 1) {
        if (header.length < 16) return null;
        boxSize = _readUint64BE(header, 8);
        headerLen = 16;
      } else if (size32 == 0) {
        boxSize = fileLength - offset;
      } else {
        boxSize = size32;
      }
      if (boxSize <= 0) return null;

      if (type == 'mdat') {
        final payloadStart = offset + headerLen;
        final payloadLength = boxSize - headerLen;
        return payloadLength > 0 ? _ByteRange(payloadStart, payloadLength) : null;
      }
      offset += boxSize;
    }
    return null;
  }

  bool _bytesStartWithAscii(Uint8List bytes, String ascii) {
    if (bytes.length < ascii.length) return false;
    for (var i = 0; i < ascii.length; i++) {
      if (bytes[i] != ascii.codeUnitAt(i)) return false;
    }
    return true;
  }

  int _readUint32BE(Uint8List bytes, int offset) {
    return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
  }

  int _readUint64BE(Uint8List bytes, int offset) {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    return value;
  }
}
