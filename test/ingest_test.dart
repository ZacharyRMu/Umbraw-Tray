import 'dart:convert';
import 'dart:io';

import 'package:umbraw_tray/src/ingest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures.dart';

void main() {
  late Directory tmp;
  late String card;
  late String repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('umbraw_test');
    card = p.join(tmp.path, 'card', 'DCIM');
    repo = p.join(tmp.path, 'repo');
    final folder = Directory(p.join(card, '100CANON'));
    await folder.create(recursive: true);
    await Directory(repo).create();

    await File(p.join(folder.path, 'IMG_0001.JPG'))
        .writeAsBytes(jpegWithDate('2025:07:04 12:00:00'));
    final video = File(p.join(folder.path, 'MVI_0002.MP4'));
    await video.writeAsString('video');
    await video.setLastModified(DateTime(2024, 3, 15, 10));
    // macOS AppleDouble junk and hidden folders must be ignored.
    await File(p.join(folder.path, '._IMG_0001.JPG')).writeAsString('junk');
    await Directory(p.join(card, '.Trashes')).create();
    await File(p.join(card, '.Trashes', 'IMG_9999.JPG')).writeAsString('x');
  });

  tearDown(() => tmp.delete(recursive: true));

  test('imports into YYYY/MM and writes a portable ledger', () async {
    final s = await runIngest(sources: [card], destRoot: repo);
    expect(s.total, 2);
    expect(s.imported, 2);
    expect(s.fallbackDates, 1);
    expect(File(p.join(repo, '2025', '07', 'IMG_0001.JPG')).existsSync(), isTrue);
    expect(File(p.join(repo, '2024', '03', 'MVI_0002.MP4')).existsSync(), isTrue);

    final ledger = jsonDecode(
        File(p.join(repo, ledgerName)).readAsStringSync()) as Map;
    expect(ledger.values.toSet(),
        {'2025/07/IMG_0001.JPG', '2024/03/MVI_0002.MP4'});
  });

  test('a second run skips everything', () async {
    await runIngest(sources: [card], destRoot: repo);
    final s = await runIngest(sources: [card], destRoot: repo);
    expect(s.imported, 0);
    expect(s.skipped, 2);
  });

  test('preview writes nothing', () async {
    final s = await runIngest(sources: [card], destRoot: repo, dryRun: true);
    expect(s.imported, 2);
    expect(Directory(repo).listSync(), isEmpty);
  });

  test('a different file with the same name gets a suffix', () async {
    await runIngest(sources: [card], destRoot: repo);
    final other = p.join(tmp.path, 'card2', 'DCIM');
    await Directory(other).create(recursive: true);
    await File(p.join(other, 'IMG_0001.JPG')).writeAsBytes(
        jpegWithDate('2025:07:20 09:00:00', payload: [9, 9, 9]));

    final s = await runIngest(sources: [other], destRoot: repo);
    expect(s.imported, 1);
    expect(File(p.join(repo, '2025', '07', 'IMG_0001_1.JPG')).existsSync(),
        isTrue);
  });

  test('move removes originals after verified copies', () async {
    final s = await runIngest(sources: [card], destRoot: repo, move: true);
    expect(s.imported, 2);
    expect(File(p.join(card, '100CANON', 'IMG_0001.JPG')).existsSync(), isFalse);
    expect(File(p.join(card, '100CANON', 'MVI_0002.MP4')).existsSync(), isFalse);
  });

  test('refuses a destination inside the source', () async {
    final inside = p.join(card, 'out');
    await Directory(inside).create();
    expect(runIngest(sources: [card], destRoot: inside),
        throwsA(isA<IngestError>()));
  });

  test('reads ledgers written with Windows separators', () async {
    await runIngest(sources: [card], destRoot: repo);
    final file = File(p.join(repo, ledgerName));
    final ledger = (jsonDecode(file.readAsStringSync()) as Map)
        .map((k, v) => MapEntry(k, (v as String).replaceAll('/', r'\')));
    file.writeAsStringSync(jsonEncode(ledger));

    final s = await runIngest(sources: [card], destRoot: repo);
    expect(s.skipped, 2);
  });
}
