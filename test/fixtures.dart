import 'dart:convert';
import 'dart:typed_data';

/// A minimal TIFF block holding one date tag.
///
/// Layout: header (8) | IFD0 at 8 (18 bytes) | [Exif IFD at 26 (18 bytes)]
/// | date string.
Uint8List tiffWithDate(String stamp,
    {Endian endian = Endian.little, bool inExifIfd = true}) {
  final str = [...ascii.encode(stamp), 0];
  final strAt = inExifIfd ? 44 : 26;
  final data = ByteData(strAt + str.length);
  final mark = endian == Endian.little ? 0x49 : 0x4D;

  data
    ..setUint8(0, mark)
    ..setUint8(1, mark)
    ..setUint16(2, 42, endian)
    ..setUint32(4, 8, endian);

  void entry(int at, int tag, int type, int count, int value) {
    data
      ..setUint16(at, tag, endian)
      ..setUint16(at + 2, type, endian)
      ..setUint32(at + 4, count, endian)
      ..setUint32(at + 8, value, endian);
  }

  data.setUint16(8, 1, endian);
  if (inExifIfd) {
    entry(10, 0x8769, 4, 1, 26); // pointer to Exif IFD
    data.setUint32(22, 0, endian);
    data.setUint16(26, 1, endian);
    entry(28, 0x9003, 2, str.length, strAt); // DateTimeOriginal
    data.setUint32(40, 0, endian);
  } else {
    entry(10, 0x0132, 2, str.length, strAt); // DateTime
    data.setUint32(22, 0, endian);
  }

  final bytes = data.buffer.asUint8List();
  bytes.setAll(strAt, str);
  return bytes;
}

/// A TIFF block with orientation, a date and an IFD1 preview thumbnail.
///
/// Layout (little-endian): header | IFD0 at 8 (2 entries, 30 bytes)
/// | Exif IFD at 38 (18) | date at 56 (20) | IFD1 at 76 (30) | thumb at 106.
Uint8List tiffWithThumbnail(String stamp, List<int> thumb,
    {int orientation = 1}) {
  const e = Endian.little;
  final str = [...ascii.encode(stamp), 0];
  assert(str.length == 20);
  final data = ByteData(106 + thumb.length);

  void entry(int at, int tag, int type, int count, int value) {
    data
      ..setUint16(at, tag, e)
      ..setUint16(at + 2, type, e)
      ..setUint32(at + 4, count, e)
      ..setUint32(at + 8, value, e);
  }

  data
    ..setUint8(0, 0x49)
    ..setUint8(1, 0x49)
    ..setUint16(2, 42, e)
    ..setUint32(4, 8, e);

  data.setUint16(8, 2, e);
  entry(10, 0x0112, 3, 1, 0); // Orientation, SHORT stored inline
  data.setUint16(18, orientation, e);
  entry(22, 0x8769, 4, 1, 38); // Exif IFD
  data.setUint32(34, 76, e); // next IFD -> IFD1

  data.setUint16(38, 1, e);
  entry(40, 0x9003, 2, str.length, 56);
  data.setUint32(52, 0, e);

  data.setUint16(76, 2, e);
  entry(78, 0x0201, 4, 1, 106); // thumbnail offset
  entry(90, 0x0202, 4, 1, thumb.length); // thumbnail length
  data.setUint32(102, 0, e);

  final bytes = data.buffer.asUint8List();
  bytes.setAll(56, str);
  bytes.setAll(106, thumb);
  return bytes;
}

/// A JPEG wrapping [tiff] in its APP1 segment.
Uint8List wrapJpeg(Uint8List tiff) {
  final app1 = [...ascii.encode('Exif'), 0, 0, ...tiff];
  final len = app1.length + 2;
  return Uint8List.fromList([
    0xFF, 0xD8, 0xFF, 0xE1, len >> 8, len & 0xFF, ...app1,
    0xFF, 0xDA, 0x00, 0x02, 7, 7, 7,
  ]);
}

/// A tiny JPEG: SOI, APP1/Exif, a start-of-scan marker and some "image" data.
Uint8List jpegWithDate(String stamp, {List<int> payload = const [1, 2, 3]}) {
  final app1 = [...ascii.encode('Exif'), 0, 0, ...tiffWithDate(stamp)];
  final len = app1.length + 2;
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE1, len >> 8, len & 0xFF, ...app1,
    0xFF, 0xDA, 0x00, 0x02, ...payload,
  ]);
}
