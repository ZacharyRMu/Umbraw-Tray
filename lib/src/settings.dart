// Remembers the destination folder and options between launches, in a small
// JSON file in the platform's usual settings location.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class AppSettings {
  const AppSettings({this.destination, this.deleteAfterImport = false});

  final String? destination;
  final bool deleteAfterImport;

  AppSettings withDestination(String? value) =>
      AppSettings(destination: value, deleteAfterImport: deleteAfterImport);

  AppSettings withDeleteAfterImport(bool value) =>
      AppSettings(destination: destination, deleteAfterImport: value);

  Map<String, Object?> toJson() => {
        'destination': destination,
        'deleteAfterImport': deleteAfterImport,
      };

  factory AppSettings.fromJson(Object? json) {
    if (json is! Map) return const AppSettings();
    final dest = json['destination'];
    final delete = json['deleteAfterImport'];
    return AppSettings(
      destination: dest is String && dest.isNotEmpty ? dest : null,
      deleteAfterImport: delete is bool && delete,
    );
  }
}

/// [legacy] is the folder the app used when it was called "EOS Ingest".
File _settingsFile({bool legacy = false}) {
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
  final String dir;
  if (Platform.isWindows) {
    dir = p.join(env['APPDATA'] ?? home, legacy ? 'EOS Ingest' : 'Umbraw Tray');
  } else if (Platform.isMacOS) {
    dir = p.join(home, 'Library', 'Application Support',
        legacy ? 'EOS Ingest' : 'Umbraw Tray');
  } else {
    final xdg = env['XDG_CONFIG_HOME'];
    dir = p.join(
        (xdg != null && xdg.isNotEmpty) ? xdg : p.join(home, '.config'),
        legacy ? 'eos-ingest' : 'umbraw-tray');
  }
  return File(p.join(dir, 'settings.json'));
}

Future<AppSettings> loadSettings() async {
  for (final legacy in [false, true]) {
    try {
      return AppSettings.fromJson(
          jsonDecode(await _settingsFile(legacy: legacy).readAsString()));
    } on FileSystemException {
      continue;
    } on FormatException {
      continue;
    }
  }
  return const AppSettings();
}

Future<void> saveSettings(AppSettings settings) async {
  try {
    final file = _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  } on FileSystemException {
    // Not being able to remember settings shouldn't block an import.
  }
}
