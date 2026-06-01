import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final bytes = File('Heardy_icon.png').readAsBytesSync();
  final image = img.decodeImage(bytes);
  if (image == null) {
    print('Failed to decode image');
    return;
  }
  
  // Calculate new size with padding (e.g. increase canvas size by 40%)
  final newWidth = (image.width * 1.4).toInt();
  final newHeight = (image.height * 1.4).toInt();
  
  // Create new image filled with the background color from top-left pixel
  final bgPixel = image.getPixel(0, 0); 
  final newImage = img.Image(width: newWidth, height: newHeight);
  img.fill(newImage, color: bgPixel);
  
  // Draw the original image in the center
  final dstX = (newWidth - image.width) ~/ 2;
  final dstY = (newHeight - image.height) ~/ 2;
  img.compositeImage(newImage, image, dstX: dstX, dstY: dstY);
  
  final outDir = Directory('assets/icon');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  
  File('assets/icon/app_icon_padded.png').writeAsBytesSync(img.encodePng(newImage));
  print('Padded icon saved');
}
