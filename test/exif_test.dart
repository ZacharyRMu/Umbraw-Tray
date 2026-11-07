import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:umbraw_tray/src/exif.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  test('reads DateTimeOriginal from a JPEG', () {
    final jpeg = jpegWithDate('2025:07:04 12:34:56');
    expect(parseExifDate(jpeg), DateTime(2025, 7, 4, 12, 34, 56));
  });

  test('reads a big-endian TIFF/CR2 header', () {
    final tiff = tiffWithDate('2024:03:09 08:00:00', endian: Endian.big);
    expect(parseExifDate(tiff), DateTime(2024, 3, 9, 8));
  });

  test('falls back to IFD0 DateTime when there is no Exif IFD', () {
    final tiff = tiffWithDate('2023:12:31 23:59:59', inExifIfd: false);
    expect(parseExifDate(tiff), DateTime(2023, 12, 31, 23, 59, 59));
  });

  group('embedded preview', () {
    const thumb = [0xFF, 0xD8, 1, 2, 3, 4, 5, 6, 0xFF, 0xD9];
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('umbraw'));
    tearDown(() => tmp.delete(recursive: true));

    test('is read from a JPEG, with its orientation', () async {
      final file = File('${tmp.path}/IMG_0001.JPG');
      await file.writeAsBytes(wrapJpeg(
          tiffWithThumbnail('2025:07:04 12:00:00', thumb, orientation: 6)));
      final info = await readCaptureInfo(file);
      expect(info.date, DateTime(2025, 7, 4, 12));
      expect(info.thumbnail, thumb);
      expect(info.quarterTurns, 1);
    });

    test('is read from a raw (TIFF-based) file', () async {
      final file = File('${tmp.path}/IMG_0002.CR2');
      await file.writeAsBytes(tiffWithThumbnail('2025:07:05 09:30:00', thumb));
      final info = await readCaptureInfo(file);
      expect(info.thumbnail, thumb);
      expect(info.quarterTurns, 0);
    });

    test('is absent when there is no IFD1', () async {
      final file = File('${tmp.path}/IMG_0003.JPG');
      await file.writeAsBytes(jpegWithDate('2025:07:06 10:00:00'));
      final info = await readCaptureInfo(file);
      expect(info.fromExif, isTrue);
      expect(info.thumbnail, isNull);
    });
  });

  test('rejects zeroed and garbage dates', () {
    expect(parseExifDate(jpegWithDate('0000:00:00 00:00:00')), isNull);
    expect(parseExifDate(Uint8List.fromList(utf8.encode('not an image'))),
        isNull);
    expect(parseExifDate(Uint8List(0)), isNull);
  });
}
