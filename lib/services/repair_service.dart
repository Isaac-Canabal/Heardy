import 'dart:io';
import '../services/database_helper.dart';
import '../services/audio_player_handler.dart';
import '../providers/music_provider.dart';

/// Servicio para reparación de problemas de corrupción en el reproductor
class RepairService {
  /// Ejecuta una reparación completa del sistema
  static Future<RepairResult> performFullRepair({
    required AudioPlayerHandler audioHandler,
    required MusicProvider musicProvider,
  }) async {
    final result = RepairResult();
    
    try {
      print('=== INICIANDO REPARACIÓN COMPLETA ===');
      
      // 1. Verificar y reparar archivos de audio corruptos
      await _repairCorruptedAudioFiles(result);
      
      // 2. Limpiar archivos temporales incompletos
      await _cleanTemporaryFiles(result);
      
      // 3. Verificar consistencia de la base de datos
      await _repairDatabaseConsistency(result);
      
      // 4. Reiniciar completamente el reproductor
      await _restartPlayer(audioHandler, result);
      
      // 5. Limpiar estado del proveedor de música
      _cleanMusicProviderState(musicProvider, result);
      
      print('=== REPARACIÓN COMPLETA FINALIZADA ===');
      print(result.summary);
      
    } catch (e) {
      result.addError('Error general en reparación: $e');
    }
    
    return result;
  }
  
  /// Verifica y repara archivos de audio corruptos
  static Future<void> _repairCorruptedAudioFiles(RepairResult result) async {
    try {
      print('Verificando archivos de audio...');
      
      final songs = await DatabaseHelper.instance.getSongs();
      int corruptedFiles = 0;
      int repairedFiles = 0;
      
      for (final song in songs) {
        final file = File(song.filePath);
        
        // Verificar si el archivo existe
        if (!file.existsSync()) {
          print('Archivo no encontrado: ${song.filePath}');
          corruptedFiles++;
          
          // Opcional: Eliminar registro de base de datos
          // await DatabaseHelper.instance.deleteSong(song.id);
          
          continue;
        }
        
        // Verificar tamaño del archivo (archivos muy pequeños probablemente corruptos)
        final fileSize = await file.length();
        if (fileSize < 1024) { // Menos de 1KB probablemente corrupto
          print('Archivo demasiado pequeño (${fileSize} bytes): ${song.filePath}');
          corruptedFiles++;
          
          // Intentar eliminar archivo corrupto
          try {
            await file.delete();
            repairedFiles++;
            print('Archivo corrupto eliminado: ${song.filePath}');
          } catch (e) {
            print('Error eliminando archivo corrupto: $e');
          }
        }
      }
      
      result.addDetail('Verificación de archivos completada');
      result.addDetail('Archivos corruptos encontrados: $corruptedFiles');
      result.addDetail('Archivos reparados/eliminados: $repairedFiles');
      
    } catch (e) {
      result.addError('Error verificando archivos de audio: $e');
    }
  }
  
  /// Limpia archivos temporales incompletos
  static Future<void> _cleanTemporaryFiles(RepairResult result) async {
    try {
      print('Limpiando archivos temporales...');
      
      // Obtener directorio de aplicación
      final tempDir = Directory.systemTemp;
      if (await tempDir.exists()) {
        int deletedFiles = 0;
        
        await for (final entity in tempDir.list()) {
          if (entity is File) {
            try {
              // Eliminar archivos temporales de audio
              if (entity.path.contains('.temp') || 
                  entity.path.contains('.download') ||
                  entity.path.contains('.part')) {
                await entity.delete();
                deletedFiles++;
              }
            } catch (e) {
              print('Error eliminando archivo temporal: $e');
            }
          }
        }
        
        result.addDetail('Archivos temporales eliminados: $deletedFiles');
      }
      
    } catch (e) {
      result.addError('Error limpiando archivos temporales: $e');
    }
  }
  
  /// Verifica y repara consistencia de la base de datos
  static Future<void> _repairDatabaseConsistency(RepairResult result) async {
    try {
      print('Verificando consistencia de base de datos...');
      
      // Verificar que todas las canciones tengan archivos válidos
      final songs = await DatabaseHelper.instance.getSongs();
      int inconsistentRecords = 0;
      
      for (final song in songs) {
        // Verificar que el archivo de audio exista
        final audioFile = File(song.filePath);
        if (!audioFile.existsSync()) {
          inconsistentRecords++;
          print('Registro inconsistente (audio no existe): ${song.id}');
          
          // Marcar para eliminación o reparación
          // Por ahora solo contamos
        }
        
        // Verificar que el arte de la portada exista si está especificado
        if (song.artPath.isNotEmpty) {
          final artFile = File(song.artPath);
          if (!artFile.existsSync()) {
            inconsistentRecords++;
            print('Registro inconsistente (arte no existe): ${song.id}');
          }
        }
      }
      
      // Verificar que todas las playlists tengan canciones válidas
      final playlists = await DatabaseHelper.instance.getPlaylists();
      int emptyPlaylists = 0;
      
      for (final playlist in playlists) {
        final playlistSongs = await DatabaseHelper.instance.getSongsForPlaylist(playlist.id);
        if (playlistSongs.isEmpty) {
          emptyPlaylists++;
        }
      }
      
      result.addDetail('Registros inconsistentes: $inconsistentRecords');
      result.addDetail('Playlists vacías: $emptyPlaylists');
      
      if (inconsistentRecords > 0) {
        result.addWarning('Se encontraron registros inconsistentes en la base de datos');
      }
      
    } catch (e) {
      result.addError('Error verificando base de datos: $e');
    }
  }
  
  /// Reinicia completamente el reproductor
  static Future<void> _restartPlayer(AudioPlayerHandler audioHandler, RepairResult result) async {
    try {
      print('Reiniciando reproductor...');
      
      final repairResult = await audioHandler.fullRepair();
      result.addDetail('Resultado del reproductor: $repairResult');
      
    } catch (e) {
      result.addError('Error reiniciando reproductor: $e');
    }
  }
  
  /// Limpia el estado del proveedor de música
  static void _cleanMusicProviderState(MusicProvider musicProvider, RepairResult result) {
    try {
      print('Limpiando estado del proveedor de música...');
      
      musicProvider.clearPlaybackState();
      
      // Recargar playlists desde la base de datos
      musicProvider.loadPlaylists();
      
      result.addDetail('Estado del proveedor limpiado y recargado');
      
    } catch (e) {
      result.addError('Error limpiando estado del proveedor: $e');
    }
  }
}

/// Resultado de una operación de reparación
class RepairResult {
  final List<String> _details = [];
  final List<String> _warnings = [];
  final List<String> _errors = [];
  
  void addDetail(String detail) {
    _details.add(detail);
    print('✓ $detail');
  }
  
  void addWarning(String warning) {
    _warnings.add(warning);
    print('⚠ $warning');
  }
  
  void addError(String error) {
    _errors.add(error);
    print('✗ $error');
  }
  
  bool get hasErrors => _errors.isNotEmpty;
  bool get hasWarnings => _warnings.isNotEmpty;
  bool get success => _errors.isEmpty;
  
  String get summary {
    final buffer = StringBuffer();
    buffer.writeln('RESUMEN DE REPARACIÓN:');
    buffer.writeln('Detalles: ${_details.length}');
    buffer.writeln('Advertencias: ${_warnings.length}');
    buffer.writeln('Errores: ${_errors.length}');
    
    if (_warnings.isNotEmpty) {
      buffer.writeln('\nADVERTENCIAS:');
      for (final warning in _warnings) {
        buffer.writeln('  • $warning');
      }
    }
    
    if (_errors.isNotEmpty) {
      buffer.writeln('\nERRORES:');
      for (final error in _errors) {
        buffer.writeln('  • $error');
      }
    }
    
    return buffer.toString();
  }
  
  String getUserMessage() {
    if (hasErrors) {
      return 'La reparación encontró errores: ${_errors.first}';
    } else if (hasWarnings) {
      return 'Reparación completada con advertencias: ${_warnings.first}';
    } else {
      return 'Reparación completada exitosamente';
    }
  }
}