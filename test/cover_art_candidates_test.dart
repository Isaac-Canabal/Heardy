import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/download_service.dart';

/// Qué URLs de carátula se intentan, y en qué orden.
///
/// El servidor mandaba `maxresdefault.webp` (la "mejor" según yt-dlp) y
/// `audio_metadata_reader` descarta un WebP al escribir el `covr` de un .m4a
/// en silencio: las canciones descargadas quedaban sin carátula en disco.
void main() {
  test('un WebP de i.ytimg.com se cambia por su gemela JPEG', () {
    expect(
      coverArtCandidates('https://i.ytimg.com/vi_webp/abc123/maxresdefault.webp', 'abc123'),
      [
        'https://i.ytimg.com/vi/abc123/maxresdefault.jpg',
        'https://i.ytimg.com/vi/abc123/hqdefault.jpg',
      ],
    );
  });

  test('una JPEG se respeta tal cual, con su query, y hqdefault queda de respaldo', () {
    expect(
      coverArtCandidates('https://i.ytimg.com/vi/abc123/hq720.jpg?sqp=xyz&rs=1', 'abc123'),
      [
        'https://i.ytimg.com/vi/abc123/hq720.jpg?sqp=xyz&rs=1',
        'https://i.ytimg.com/vi/abc123/hqdefault.jpg',
      ],
    );
  });

  test('si la URL ya es hqdefault no se duplica', () {
    expect(
      coverArtCandidates('https://i.ytimg.com/vi/abc123/hqdefault.jpg', 'abc123'),
      ['https://i.ytimg.com/vi/abc123/hqdefault.jpg'],
    );
  });

  test('sin URL pero con id, se intenta hqdefault', () {
    expect(coverArtCandidates('', 'abc123'), ['https://i.ytimg.com/vi/abc123/hqdefault.jpg']);
  });

  test('sin URL ni id no hay nada que intentar', () {
    expect(coverArtCandidates('', ''), isEmpty);
  });

  test('una URL de otro dominio se intenta sin tocar, y luego el respaldo por id', () {
    expect(
      coverArtCandidates('https://example.com/cover.webp', 'abc123'),
      ['https://example.com/cover.webp', 'https://i.ytimg.com/vi/abc123/hqdefault.jpg'],
    );
  });
}
