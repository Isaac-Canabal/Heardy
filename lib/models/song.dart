import 'dart:convert';

class Song {
  final String id;
  final String title;
  final String artist;
  final int duration; // in seconds
  final String filePath;
  final String artPath; // local file path to downloaded thumbnail
  final String format; // e.g. 'm4a'
  final DateTime downloadDate;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.filePath,
    required this.artPath,
    required this.format,
    required this.downloadDate,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'duration': duration,
      'filePath': filePath,
      'artPath': artPath,
      'format': format,
      'downloadDate': downloadDate.toIso8601String(),
    };
  }

  factory Song.fromMap(Map<String, dynamic> map) {
    return Song(
      id: map['id'] as String,
      title: map['title'] as String,
      artist: map['artist'] as String,
      duration: map['duration'] as int,
      filePath: map['filePath'] as String,
      artPath: map['artPath'] as String? ?? '',
      format: map['format'] as String,
      downloadDate: DateTime.parse(map['downloadDate'] as String),
    );
  }

  String toJson() => json.encode(toMap());

  factory Song.fromJson(String source) => Song.fromMap(json.decode(source) as Map<String, dynamic>);
}
