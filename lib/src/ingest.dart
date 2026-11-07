// The ingest engine: scan sources, file each item into <repo>/YYYY/MM,
// verify every copy by SHA-1, and keep a ledger of what has been imported.
//
// The ledger (_ingest-ledger.json) uses the same format as the Python
// eos_ingest.py script, so existing repositories carry straight over.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'exif.dart';

const ledgerName = '_ingest-ledger.json';

/// Everything a T7 can write, plus a couple of neighbours.
const defaultExtensions = {
  '.jpg', '.jpeg', // JPEG stills
  '.cr2', // Canon raw
  '.mp4', '.mov', '.avi', // video
  '.wav', // sound memo
};

class IngestError implements Exception {
  const IngestError(this.message);
  final String message;
  @override
  String toString() => message;
}

class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

enum Outcome { copied, skipped, failed }

const videoExtensions = {'.mp4', '.mov', '.avi'};

class FileResult {
  const FileResult(
    this.name,
    this.outcome,
    this.detail, {
    this.thumbnail,
    this.quarterTurns = 0,
  });

  final String name;
  final Outcome outcome;
  final String detail;

  /// The camera's embedded preview JPEG, when the file has one.
  final Uint8List? thumbnail;

  /// Clockwise quarter turns to show [thumbnail] upright.
  final int quarterTurns;

  bool get isVideo => videoExtensions.contains(p.extension(name).toLowerCase());
}

class SourceStats {
  const SourceStats(this.files, this.bytes);
  final int files;
  final int bytes;
}

/// Count the media files under [path] and their total size.
Future<SourceStats> measureSource(String path,
    {Set<String> extensions = defaultExtensions}) async {
  final files = <File>[];
  if (await FileSystemEntity.isFile(path)) {
    files.add(File(path));
  } else {
    await _walk(Directory(path), files, extensions);
  }
  var bytes = 0;
  for (final f in files) {
    try {
      bytes += await f.length();
    } on FileSystemException {
      // Unreadable files still count; their size just isn't known.
    }
  }
  return SourceStats(files.length, bytes);
}

enum IngestPhase { scanning, working }

class IngestProgress {
  const IngestProgress({
    required this.phase,
    this.filesDone = 0,
    this.filesTotal = 0,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.bytesCopied = 0,
    this.current,
  });

  final IngestPhase phase;
  final int filesDone;
  final int filesTotal;

  /// Bytes of files finished (copied, skipped or failed) plus the current copy.
  final int bytesDone;
  final int bytesTotal;

  /// Bytes actually written so far; use this for transfer speed.
  final int bytesCopied;
  final String? current;
}

class IngestSummary {
  IngestSummary({required this.dryRun});
  final bool dryRun;
  int total = 0;
  int imported = 0;
  int skipped = 0;
  int failed = 0;
  int fallbackDates = 0;
  bool cancelled = false;
}

/// SHA-1 of a file, computed on a background isolate so the UI stays smooth.
Future<String> sha1OfFile(String path) => Isolate.run(() => _sha1(path));

Future<String> _sha1(String path) async =>
    (await sha1.bind(File(path).openRead()).first).toString();

Future<IngestSummary> runIngest({
  required List<String> sources,
  required String destRoot,
  Set<String> extensions = defaultExtensions,
  bool move = false,
  bool dryRun = false,
  CancelToken? cancel,
  void Function(IngestProgress progress)? onProgress,
  void Function(FileResult result)? onResult,
}) async {
  final token = cancel ?? CancelToken();
  final summary = IngestSummary(dryRun: dryRun);

  if (sources.isEmpty) throw const IngestError('No source selected.');
  if (!await Directory(destRoot).exists()) {
    throw IngestError('Destination folder not found: $destRoot\n'
        'Is its drive connected?');
  }
  final root = await _realPath(destRoot);

  for (final source in sources) {
    if (await FileSystemEntity.type(source) == FileSystemEntityType.notFound) {
      throw IngestError('Source not found: $source');
    }
    final src = await _realPath(source);
    if (p.equals(src, root) || p.isWithin(src, root)) {
      throw IngestError('The destination is inside the card ($source). '
          'Pick a destination somewhere else.');
    }
  }

  // ---- Scan --------------------------------------------------------------
  onProgress?.call(const IngestProgress(phase: IngestPhase.scanning));
  final files = <File>[];
  for (final source in sources) {
    if (await FileSystemEntity.isFile(source)) {
      files.add(File(source));
    } else {
      await _walk(Directory(source), files, extensions);
    }
  }
  final sizes = <int>[];
  for (final f in files) {
    try {
      sizes.add(await f.length());
    } on FileSystemException {
      sizes.add(0);
    }
  }
  final bytesTotal = sizes.fold<int>(0, (a, b) => a + b);
  summary.total = files.length;
  if (files.isEmpty) return summary;

  // ---- Import ------------------------------------------------------------
  final ledger = await _loadLedger(root);
  var ledgerDirty = false;
  var sinceSave = 0;
  var bytesDone = 0;
  var bytesCopied = 0;
  var filesDone = 0;
  String? current;
  final clock = Stopwatch()..start();

  void emit({bool force = false}) {
    if (!force && clock.elapsedMilliseconds < 80) return;
    clock.reset();
    onProgress?.call(IngestProgress(
      phase: IngestPhase.working,
      filesDone: filesDone,
      filesTotal: files.length,
      bytesDone: bytesDone,
      bytesTotal: bytesTotal,
      bytesCopied: bytesCopied,
      current: current,
    ));
  }

  void report(String name, Outcome outcome, String detail, CaptureInfo? info) {
    switch (outcome) {
      case Outcome.copied:
        summary.imported++;
      case Outcome.skipped:
        summary.skipped++;
      case Outcome.failed:
        summary.failed++;
    }
    onResult?.call(FileResult(
      name,
      outcome,
      detail,
      thumbnail: info?.thumbnail,
      quarterTurns: info?.quarterTurns ?? 0,
    ));
  }

  Future<String> removeSource(File src) async {
    if (!move || dryRun) return '';
    try {
      await src.delete();
      return ', removed from card';
    } on FileSystemException catch (e) {
      return ', but could not remove from card (${_describe(e)})';
    }
  }

  try {
    for (var i = 0; i < files.length; i++) {
      if (token.isCancelled) {
        summary.cancelled = true;
        break;
      }
      final src = files[i];
      final name = p.basename(src.path);
      final bytesBefore = bytesDone;
      current = name;
      emit(force: true);
      CaptureInfo? info;

      try {
        final date = await readCaptureInfo(src);
        info = date;
        final digest = await sha1OfFile(src.path);

        final known = ledger[digest];
        if (known != null && await File(_fromLedger(root, known)).exists()) {
          report(name, Outcome.skipped,
              'already imported ($known)${await removeSource(src)}', info);
          continue;
        }

        if (!date.fromExif) summary.fallbackDates++;
        final yyyy = date.date.year.toString().padLeft(4, '0');
        final mm = date.date.month.toString().padLeft(2, '0');
        final destDir = p.join(root, yyyy, mm);
        var dest = p.join(destDir, name);

        // A file of the same name is already there: identical, or a clash?
        if (await File(dest).exists()) {
          if (await sha1OfFile(dest) == digest) {
            ledger[digest] = '$yyyy/$mm/$name';
            ledgerDirty = true;
            report(name, Outcome.skipped,
                'already in $yyyy/$mm${await removeSource(src)}', info);
            continue;
          }
          dest = await _uniquePath(dest);
        }

        final rel = '$yyyy/$mm/${p.basename(dest)}';
        final dateNote = date.fromExif ? '' : ' (date from file timestamp)';

        if (dryRun) {
          report(name, Outcome.copied, '→ $rel$dateNote', info);
          continue;
        }

        await Directory(destDir).create(recursive: true);
        await _copyVerified(src, dest, digest, token, (n) {
          bytesDone += n;
          bytesCopied += n;
          emit();
        });
        ledger[digest] = rel;
        ledgerDirty = true;
        report(name, Outcome.copied,
            '→ $rel$dateNote${await removeSource(src)}', info);

        if (++sinceSave >= 25) {
          await _saveLedger(root, ledger);
          sinceSave = 0;
          ledgerDirty = false;
        }
      } on _Cancelled {
        summary.cancelled = true;
        break;
      } on FileSystemException catch (e) {
        report(name, Outcome.failed, _describe(e), info);
      } on IngestError catch (e) {
        report(name, Outcome.failed, e.message, info);
      } finally {
        bytesDone = bytesBefore + sizes[i];
        filesDone = i + 1;
      }
    }
  } finally {
    if (!dryRun && ledgerDirty) await _saveLedger(root, ledger);
  }

  current = null;
  emit(force: true);
  return summary;
}

// ---------------------------------------------------------------------------

Future<void> _walk(Directory dir, List<File> out, Set<String> exts) async {
  var entries = <FileSystemEntity>[];
  try {
    entries = await dir.list(followLinks: false).toList();
  } on FileSystemException {
    return;
  }
  entries.sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    final name = p.basename(entry.path);
    // macOS litters cards with "._IMG_0001.JPG" files and hidden folders
    // like .Trashes and .Spotlight-V100; they are never media.
    if (name.startsWith('.')) continue;
    if (entry is Directory) {
      await _walk(entry, out, exts);
    } else if (entry is File && exts.contains(p.extension(name).toLowerCase())) {
      out.add(entry);
    }
  }
}

Future<void> _copyVerified(File src, String dest, String digest,
    CancelToken token, void Function(int bytes) onBytes) async {
  // Copy to a .part file first so an interrupted copy never looks finished.
  final part = File('$dest.part');
  final modified = await src.lastModified();
  final sink = part.openWrite();
  var done = false;
  try {
    await sink.addStream(src.openRead().map((chunk) {
      if (token.isCancelled) throw const _Cancelled();
      onBytes(chunk.length);
      return chunk;
    }));
    await sink.close();
    await part.setLastModified(modified);
    if (await sha1OfFile(part.path) != digest) {
      throw const IngestError('checksum mismatch after copy');
    }
    await part.rename(dest);
    done = true;
  } finally {
    if (!done) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await part.delete();
      } catch (_) {}
    }
  }
}

Future<String> _uniquePath(String path) async {
  final stem = p.withoutExtension(path);
  final ext = p.extension(path);
  for (var n = 1;; n++) {
    final candidate = '${stem}_$n$ext';
    if (!await File(candidate).exists()) return candidate;
  }
}

Future<String> _realPath(String path) async {
  try {
    return await Directory(path).resolveSymbolicLinks();
  } on FileSystemException {
    return p.normalize(p.absolute(path));
  }
}

/// Ledger paths are stored with '/', but older Windows ledgers may use '\'.
String _fromLedger(String root, String stored) => p.joinAll([
      root,
      ...stored.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty),
    ]);

Future<Map<String, String>> _loadLedger(String root) async {
  try {
    final data =
        jsonDecode(await File(p.join(root, ledgerName)).readAsString());
    if (data is Map) {
      return {
        for (final e in data.entries)
          if (e.value is String) e.key.toString(): e.value as String,
      };
    }
  } on FileSystemException {
    // No ledger yet.
  } on FormatException {
    // Corrupt ledger: start fresh; the same-name check still prevents dupes.
  }
  return {};
}

Future<void> _saveLedger(String root, Map<String, String> ledger) async {
  final keys = ledger.keys.toList()..sort();
  final text = const JsonEncoder.withIndent(' ')
      .convert({for (final k in keys) k: ledger[k]});
  final path = p.join(root, ledgerName);
  final tmp = File('$path.tmp');
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(path);
}

String _describe(FileSystemException e) {
  final os = e.osError?.message;
  return (os == null || os.isEmpty) ? e.message : '${e.message}: $os';
}
