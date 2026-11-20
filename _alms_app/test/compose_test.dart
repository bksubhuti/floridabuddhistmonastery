import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:alms_tracker/main.dart';

void main() {
  test('compose head shot onto body', () {
    final src = Platform.environment['HEAD_PNG']!;
    final cut = img.trim(img.decodePng(File(src).readAsBytesSync())!, mode: img.TrimMode.transparent);
    final out = composeFace(cut, img.decodePng(File('assets/guest_body.png').readAsBytesSync())!);
    File(Platform.environment['OUT_PNG']!).writeAsBytesSync(img.encodePng(out));
    expect(out.width, 108);
  });
}
