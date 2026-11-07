// Finds mounted camera cards: volumes with a DCIM folder at their root.
//
//   Windows  removable drive letters
//   macOS    volumes in /Volumes (the startup disk is a symlink and skipped)
//   Linux    mounts under /media, /run/media or /mnt

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows_drives.dart';

class CardVolume {
  const CardVolume({required this.volume, required this.dcim});

  /// Mount point or drive root, e.g. `E:\` or `/Volumes/EOS_DIGITAL`.
  final String volume;

  /// The card's DCIM folder; this is what gets imported.
  final String dcim;

  String get label {
    final trimmed = volume.replaceAll(RegExp(r'[\\/]+$'), '');
    if (trimmed.isEmpty) return volume;
    return p.basename(trimmed);
  }
}

Future<List<CardVolume>> findCards() async {
  final cards = <CardVolume>[];
  for (final volume in await _candidateVolumes()) {
    final dcim = await _childDir(volume, 'DCIM');
    if (dcim != null) cards.add(CardVolume(volume: volume, dcim: dcim));
  }
  return cards;
}

String noCardTip() {
  if (Platform.isWindows) {
    return 'Connected over USB, the camera appears as a media device rather '
        'than a drive. Use a card reader, or add the folder by hand.';
  }
  if (Platform.isMacOS) {
    return 'Connected over USB, the camera is handed to Photos/Image Capture '
        'instead of being mounted. Use a card reader, or add the folder by hand.';
  }
  return 'Connected over USB, the camera appears as a PTP device, not a disk. '
      'Use a card reader. If the card is inserted but not mounted, open it in '
      'your file manager first.';
}

Future<List<String>> _candidateVolumes() async {
  try {
    if (Platform.isWindows) return windowsRemovableDrives();
    if (Platform.isMacOS) return await _macVolumes();
    if (Platform.isLinux) return await _linuxVolumes();
  } catch (_) {
    // Detection is best-effort; the user can always add a folder.
  }
  return const [];
}

Future<List<String>> _macVolumes() async {
  final found = <String>[];
  try {
    await for (final entry in Directory('/Volumes').list(followLinks: false)) {
      if (p.basename(entry.path).startsWith('.')) continue;
      // "Macintosh HD" is a symlink back to /, so Link entries are skipped.
      if (entry is Directory) found.add(entry.path);
    }
  } on FileSystemException {
    return const [];
  }
  found.sort();
  return found;
}

final _mountEscape = RegExp(r'\\([0-7]{3})');

Future<List<String>> _linuxVolumes() async {
  const prefixes = ['/media/', '/run/media/', '/mnt/'];
  final lines = await File('/proc/mounts')
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .toList();

  final found = <String>{};
  for (final line in lines) {
    final fields = line.split(' ');
    if (fields.length < 2) continue;
    // /proc/mounts escapes spaces and tabs in paths as \040, \011, ...
    final mount = fields[1].replaceAllMapped(
        _mountEscape, (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)));
    if (prefixes.any(mount.startsWith)) found.add(mount);
  }
  return found.toList()..sort();
}

/// Find a subfolder by name, ignoring case (cards are FAT/exFAT).
Future<String?> _childDir(String parent, String name) async {
  final wanted = name.toUpperCase();
  try {
    await for (final entry in Directory(parent).list(followLinks: false)) {
      if (entry is Directory && p.basename(entry.path).toUpperCase() == wanted) {
        return entry.path;
      }
    }
  } on FileSystemException {
    // Empty card-reader slot, permission denied, etc.
  }
  return null;
}
