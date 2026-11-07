// Minimal EXIF reader for JPEG (APP1) and TIFF-based raw files (CR2).
//
// Reads just what the app needs: the capture date, the small preview JPEG
// the camera embeds (IFD1, about 160x120), and the orientation so portrait
// shots show the right way up.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const _tagOrientation = 0x0112; // IFD0
const _tagDateTime = 0x0132; // IFD0: DateTime (last modified, per camera)
const _tagExifIfd = 0x8769; // IFD0: pointer to the Exif sub-IFD
const _tagDateTimeOriginal = 0x9003;
const _tagDateTimeDigitized = 0x9004;
const _tagThumbOffset = 0x0201; // IFD1: JPEGInterchangeFormat
const _tagThumbLength = 0x0202; // IFD1: JPEGInterchangeFormatLength

const _typeSize = {
  1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, //
};

/// EXIF always lives near the start of the file.
const _headerBytes = 512 * 1024;
const _maxThumbBytes = 2 * 1024 * 1024;

class CaptureInfo {
  const CaptureInfo(
    this.date, {
    required this.fromExif,
    this.thumbnail,
    this.quarterTurns = 0,
  });

  final DateTime date;

  /// False when no EXIF date was found and the file timestamp was used.
  final bool fromExif;

  /// The camera's embedded preview JPEG, if there is one.
  final Uint8List? thumbnail;

  /// Clockwise quarter turns needed to show [thumbnail] upright.
  final int quarterTurns;
}

/// Capture date (EXIF, else file modification time) plus preview thumbnail.
Future<CaptureInfo> readCaptureInfo(File file) async {
  DateTime? date;
  Uint8List? thumb;
  var turns = 0;

  try {
    final raf = await file.open();
    try {
      final head = await raf.read(_headerBytes);
      final tiff = _locateTiff(head);
      if (tiff != null) {
        final meta = _parseTiff(tiff.bytes);
        date = meta.date;
        turns = meta.quarterTurns;
        final offset = meta.thumbOffset, length = meta.thumbLength;
        if (offset != null && length != null) {
          final at = tiff.start + offset;
          Uint8List bytes;
          if (at + length <= head.length) {
            bytes = Uint8List.fromList(Uint8List.sublistView(head, at, at + length));
          } else {
            await raf.setPosition(at);
            bytes = await raf.read(length);
          }
          if (bytes.length == length && bytes[0] == 0xFF && bytes[1] == 0xD8) {
            thumb = bytes;
          }
        }
      }
    } finally {
      await raf.close();
    }
  } on FileSystemException {
    // Fall through to the file timestamp.
  }

  if (date != null) {
    return CaptureInfo(date,
        fromExif: true, thumbnail: thumb, quarterTurns: turns);
  }
  return CaptureInfo(await file.lastModified(),
      fromExif: false, thumbnail: thumb, quarterTurns: turns);
}

/// Parse the capture date out of the first bytes of a JPEG or TIFF/CR2 file.
DateTime? parseExifDate(Uint8List head) {
  final tiff = _locateTiff(head);
  return tiff == null ? null : _parseTiff(tiff.bytes).date;
}

/// The embedded preview's (offset, length) relative to the file start.
({int offset, int length})? parseThumbnailLocation(Uint8List head) {
  final tiff = _locateTiff(head);
  if (tiff == null) return null;
  final meta = _parseTiff(tiff.bytes);
  final offset = meta.thumbOffset, length = meta.thumbLength;
  if (offset == null || length == null) return null;
  return (offset: tiff.start + offset, length: length);
}

// ---------------------------------------------------------------------------

class _Tiff {
  const _Tiff(this.start, this.bytes);

  /// Where the TIFF block starts in the file; IFD offsets are relative to it.
  final int start;
  final Uint8List bytes;
}

class _Meta {
  DateTime? date;
  int quarterTurns = 0;
  int? thumbOffset;
  int? thumbLength;
}

_Tiff? _locateTiff(Uint8List h) {
  // JPEG: walk marker segments looking for APP1 "Exif\0\0".
  if (h.length >= 2 && h[0] == 0xFF && h[1] == 0xD8) {
    var i = 2;
    while (i + 4 <= h.length) {
      if (h[i] != 0xFF) return null;
      final marker = h[i + 1];
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      if (marker == 0xDA) return null; // start of scan: no metadata past here
      final segLen = (h[i + 2] << 8) | h[i + 3];
      if (marker == 0xE1 &&
          i + 10 <= h.length &&
          h[i + 4] == 0x45 && // E
          h[i + 5] == 0x78 && // x
          h[i + 6] == 0x69 && // i
          h[i + 7] == 0x66 && // f
          h[i + 8] == 0 &&
          h[i + 9] == 0) {
        final end = math.min(i + 2 + segLen, h.length);
        if (end <= i + 10) return null;
        return _Tiff(i + 10, Uint8List.sublistView(h, i + 10, end));
      }
      i += 2 + segLen;
    }
    return null;
  }

  // CR2 and plain TIFF are already TIFF containers.
  if (h.length >= 4 &&
      ((h[0] == 0x49 && h[1] == 0x49 && h[2] == 0x2A && h[3] == 0) ||
          (h[0] == 0x4D && h[1] == 0x4D && h[2] == 0 && h[3] == 0x2A))) {
    return _Tiff(0, h);
  }
  return null;
}

_Meta _parseTiff(Uint8List tiff) {
  final meta = _Meta();
  if (tiff.length < 8) return meta;

  final Endian e;
  if (tiff[0] == 0x49 && tiff[1] == 0x49) {
    e = Endian.little; // "II"
  } else if (tiff[0] == 0x4D && tiff[1] == 0x4D) {
    e = Endian.big; // "MM"
  } else {
    return meta;
  }

  final data = ByteData.sublistView(tiff);
  final len = data.lengthInBytes;

  try {
    final ifd0Offset = data.getUint32(4, e);
    final ifd0 = _readIfd(data, ifd0Offset, e,
        {_tagExifIfd, _tagDateTime, _tagOrientation});

    // Date: DateTimeOriginal, then DateTimeDigitized, then IFD0 DateTime.
    final candidates = <Object?>[];
    final exifPointer = ifd0[_tagExifIfd];
    if (exifPointer is int) {
      final sub = _readIfd(data, exifPointer, e,
          {_tagDateTimeOriginal, _tagDateTimeDigitized});
      candidates
        ..add(sub[_tagDateTimeOriginal])
        ..add(sub[_tagDateTimeDigitized]);
    }
    candidates.add(ifd0[_tagDateTime]);
    for (final value in candidates) {
      meta.date = _parseStamp(value);
      if (meta.date != null) break;
    }

    meta.quarterTurns = switch (ifd0[_tagOrientation]) {
      3 => 2, // upside down
      6 => 1, // rotate 90 clockwise
      8 => 3, // rotate 90 counter-clockwise
      _ => 0,
    };

    // Thumbnail: IFD1 follows IFD0 via IFD0's "next IFD" pointer.
    if (ifd0Offset > 0 && ifd0Offset + 2 <= len) {
      final count = data.getUint16(ifd0Offset, e);
      final nextAt = ifd0Offset + 2 + count * 12;
      if (nextAt + 4 <= len) {
        final ifd1 = _readIfd(data, data.getUint32(nextAt, e), e,
            {_tagThumbOffset, _tagThumbLength});
        final offset = ifd1[_tagThumbOffset];
        final length = ifd1[_tagThumbLength];
        if (offset is int &&
            length is int &&
            offset > 0 &&
            length > 2 &&
            length <= _maxThumbBytes) {
          meta
            ..thumbOffset = offset
            ..thumbLength = length;
        }
      }
    }
  } on RangeError {
    // Truncated or corrupt block: keep whatever was found.
  }
  return meta;
}

/// Read one IFD, returning {tag: value} for the wanted tags.
Map<int, Object> _readIfd(ByteData d, int offset, Endian e, Set<int> wanted) {
  final out = <int, Object>{};
  final len = d.lengthInBytes;
  if (offset <= 0 || offset + 2 > len) return out;

  final entries = d.getUint16(offset, e);
  var pos = offset + 2;
  for (var n = 0; n < entries; n++) {
    if (pos + 12 > len) break;
    final tag = d.getUint16(pos, e);
    final type = d.getUint16(pos + 2, e);
    final count = d.getUint32(pos + 4, e);
    if (wanted.contains(tag)) {
      final size = (_typeSize[type] ?? 0) * count;
      var at = pos + 8;
      if (size > 4) at = d.getUint32(pos + 8, e);
      if (at > 0 && at < len) {
        if (type == 2) {
          // ASCII, NUL-terminated
          final end = math.min(at + count, len);
          final bytes = d.buffer.asUint8List(d.offsetInBytes + at, end - at);
          final nul = bytes.indexOf(0);
          out[tag] = String.fromCharCodes(nul < 0 ? bytes : bytes.sublist(0, nul));
        } else if (type == 4 && at + 4 <= len) {
          out[tag] = d.getUint32(at, e);
        } else if (type == 3 && at + 2 <= len) {
          out[tag] = d.getUint16(at, e);
        }
      }
    }
    pos += 12;
  }
  return out;
}

final _stampPattern = RegExp(
    r'^(\d{4})[:\-](\d{2})[:\-](\d{2})(?:[ T](\d{2}):(\d{2}):(\d{2}))?');

DateTime? _parseStamp(Object? value) {
  if (value is! String) return null;
  final m = _stampPattern.firstMatch(value.trim());
  if (m == null) return null;

  int part(int i) => int.parse(m.group(i) ?? '0');
  final year = part(1), month = part(2), day = part(3);
  final hour = part(4), minute = part(5), second = part(6);
  if (year == 0 || month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;
  return DateTime(year, month, day, hour, minute, second);
}
