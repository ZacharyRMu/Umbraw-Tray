import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'src/cards.dart';
import 'src/ingest.dart';
import 'src/settings.dart';
import 'src/theme.dart';

const appName = 'Umbraw Tray';

void main() => runApp(const UmbrawTrayApp());

class UmbrawTrayApp extends StatelessWidget {
  const UmbrawTrayApp({super.key, this.autoScan = true});

  /// Off in widget tests, which shouldn't touch the disk or start timers.
  final bool autoScan;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: TrayPage(autoScan: autoScan),
    );
  }
}

/// A selectable source: a detected card or a folder the user added.
class _Source {
  const _Source({required this.path, required this.title, this.card = false});
  final String path;
  final String title;
  final bool card;
}

class TrayPage extends StatefulWidget {
  const TrayPage({super.key, this.autoScan = true});

  final bool autoScan;

  @override
  State<TrayPage> createState() => _TrayPageState();
}

class _TrayPageState extends State<TrayPage> {
  // Sources
  List<CardVolume> _cards = const [];
  final Set<String> _unticked = {};
  final List<String> _folders = [];
  final Map<String, SourceStats?> _stats = {};
  Timer? _poll;
  bool _scanBusy = false;

  // Destination and options
  AppSettings _settings = const AppSettings();
  bool _destMissing = false;

  // Run state
  bool _running = false;
  bool _preview = false;
  CancelToken? _cancel;
  IngestProgress? _progress;
  final Stopwatch _runClock = Stopwatch();
  final List<FileResult> _log = [];
  IngestSummary? _summary;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.autoScan) {
      _loadSettings();
      _rescan();
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _rescan());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _cancel?.cancel();
    super.dispose();
  }

  // ---- Data ---------------------------------------------------------------

  List<_Source> get _allSources => [
        for (final c in _cards) _Source(path: c.dcim, title: c.label, card: true),
        for (final f in _folders) _Source(path: f, title: p.basename(f)),
      ];

  List<String> get _selected => [
        for (final s in _allSources)
          if (!_unticked.contains(s.path)) s.path,
      ];

  SourceStats? get _selectedStats {
    var files = 0, bytes = 0;
    for (final path in _selected) {
      final s = _stats[path];
      if (s == null) return null; // still measuring
      files += s.files;
      bytes += s.bytes;
    }
    return SourceStats(files, bytes);
  }

  bool get _canStart =>
      !_running &&
      _selected.isNotEmpty &&
      _settings.destination != null &&
      !_destMissing;

  Future<void> _loadSettings() async {
    final loaded = await loadSettings();
    if (!mounted) return;
    setState(() => _settings = loaded);
    await _checkDestination();
  }

  Future<void> _checkDestination() async {
    final dest = _settings.destination;
    final missing = dest != null && !await Directory(dest).exists();
    if (mounted && missing != _destMissing) {
      setState(() => _destMissing = missing);
    }
  }

  Future<void> _rescan() async {
    if (_running || _scanBusy) return;
    _scanBusy = true;
    try {
      final found = await findCards();
      if (!mounted) return;
      final same = found.length == _cards.length &&
          Iterable<int>.generate(found.length)
              .every((i) => found[i].dcim == _cards[i].dcim);
      if (!same) {
        setState(() => _cards = found);
        _measureMissing();
      }
      await _checkDestination();
    } finally {
      _scanBusy = false;
    }
  }

  /// Count files and bytes for any source not measured yet.
  void _measureMissing() {
    for (final source in _allSources) {
      if (_stats.containsKey(source.path)) continue;
      _stats[source.path] = null;
      measureSource(source.path).then((stats) {
        if (mounted) setState(() => _stats[source.path] = stats);
      }, onError: (Object _) {
        if (mounted) setState(() => _stats.remove(source.path));
      });
    }
  }

  // ---- Actions ------------------------------------------------------------

  Future<void> _pickDestination() async {
    final current = _settings.destination;
    final picked = await getDirectoryPath(
      initialDirectory: (current != null && !_destMissing) ? current : null,
      confirmButtonText: 'Use this folder',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _settings = _settings.withDestination(picked);
      _destMissing = false;
      _error = null;
    });
    await saveSettings(_settings);
  }

  Future<void> _addFolder() async {
    final picked = await getDirectoryPath(confirmButtonText: 'Import from here');
    if (picked == null || !mounted) return;
    if (!_folders.contains(picked)) {
      setState(() => _folders.add(picked));
      _measureMissing();
    }
  }

  void _toggleSource(String path, bool on) {
    setState(() => on ? _unticked.remove(path) : _unticked.add(path));
  }

  void _setDeleteAfterImport(bool value) {
    setState(() => _settings = _settings.withDeleteAfterImport(value));
    saveSettings(_settings);
  }

  Future<void> _start({required bool preview}) async {
    final dest = _settings.destination;
    if (dest == null) return;
    final move = _settings.deleteAfterImport && !preview;

    if (move) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete from card after import?'),
          content: const Text(
            'Each file is removed from the card only after its copy has been '
            'verified by checksum. Files already in your library are removed '
            'from the card too.',
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Import and delete'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    final token = CancelToken();
    setState(() {
      _running = true;
      _preview = preview;
      _cancel = token;
      _progress = null;
      _log.clear();
      _summary = null;
      _error = null;
    });
    _runClock
      ..reset()
      ..start();

    try {
      final summary = await runIngest(
        sources: _selected,
        destRoot: dest,
        move: move,
        dryRun: preview,
        cancel: token,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
        onResult: (result) {
          if (mounted) setState(() => _log.add(result));
        },
      );
      if (mounted) setState(() => _summary = summary);
    } on IngestError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Something went wrong: $e');
    } finally {
      _runClock.stop();
      if (mounted) {
        setState(() {
          _running = false;
          _cancel = null;
          // Files may have been removed from the card: count again.
          if (move) _stats.clear();
        });
        _measureMissing();
      }
    }
    _rescan();
  }

  void _stop() {
    _cancel?.cancel();
    setState(() {});
  }

  // ---- Derived display values ----------------------------------------------

  /// Bytes per second actually written in this run.
  double? get _speed {
    final pr = _progress;
    final secs = _runClock.elapsedMilliseconds / 1000;
    if (pr == null || secs < 1 || pr.bytesCopied == 0) return null;
    return pr.bytesCopied / secs;
  }

  String get _headerStatus {
    if (_running) {
      final pr = _progress;
      if (pr == null || pr.phase == IngestPhase.scanning) return 'Scanning…';
      if (_preview) return 'Previewing';
      final speed = _speed;
      if (speed == null || speed <= 0) return 'Importing';
      final secsLeft = (pr.bytesTotal - pr.bytesDone) / speed;
      return 'Importing · ${_duration(secsLeft)} left';
    }
    if (_summary != null) return _summary!.dryRun ? 'Preview ready' : 'Done';
    return 'Ready';
  }

  // ---- UI -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(status: _headerStatus),
          const Divider(height: 1, thickness: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final sideWidth =
                    (constraints.maxWidth * 0.3).clamp(270.0, 340.0);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: sideWidth, child: _buildSidebar()),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(child: _buildMain()),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    final sources = _allSources;
    final dest = _settings.destination;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('SOURCES', style: labelStyle()),
        const SizedBox(height: 14),
        if (sources.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('No card detected.'),
                const SizedBox(height: 6),
                Text(noCardTip(), style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        for (final source in sources) ...[
          _SourceTile(
            source: source,
            selected: !_unticked.contains(source.path),
            stats: _stats[source.path],
            enabled: !_running,
            onChanged: (on) => _toggleSource(source.path, on),
            onRemove: source.card
                ? null
                : () => setState(() {
                      _folders.remove(source.path);
                      _unticked.remove(source.path);
                    }),
          ),
          const SizedBox(height: 10),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _running ? null : _addFolder,
            child: const Text('+ Add folder…'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Divider(height: 1, thickness: 1),
        ),
        Text('DESTINATION', style: labelStyle()),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                decoration: BoxDecoration(
                  color: Tone.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: _destMissing ? Border.all(color: Tone.bad) : null,
                ),
                child: Tooltip(
                  message: dest ?? '',
                  child: Text(
                    dest == null ? 'Not chosen' : _shortPath(dest),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(color: dest == null ? Tone.muted : Tone.text),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _running ? null : _pickDestination,
              child: Text(dest == null ? 'Choose…' : 'Change…'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _destMissing
              ? "Can't find this folder. Is its drive connected?"
              : 'Sorted into YYYY/MM by capture date',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: _destMissing ? Tone.bad : Tone.muted),
        ),
        const SizedBox(height: 18),
        _CheckRow(
          label: 'Delete from card after verified copy',
          value: _settings.deleteAfterImport,
          onChanged: _running ? null : _setDeleteAfterImport,
        ),
      ],
    );
  }

  Widget _buildMain() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTopRow(),
          const SizedBox(height: 20),
          _ProgressLine(value: _progressValue),
          const SizedBox(height: 12),
          Text(_statusLine, style: mono(color: Tone.muted)),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _ErrorBox(message: _error!),
          ],
          const SizedBox(height: 20),
          Expanded(child: _ResultTable(rows: _log, preview: _preview)),
        ],
      ),
    );
  }

  double? get _progressValue {
    if (_running) {
      final pr = _progress;
      if (pr == null || pr.phase == IngestPhase.scanning) return null;
      return pr.bytesTotal == 0
          ? 0
          : (pr.bytesDone / pr.bytesTotal).clamp(0.0, 1.0);
    }
    return _summary == null ? 0 : 1;
  }

  String get _statusLine {
    if (_running) {
      final pr = _progress;
      if (pr == null || pr.phase == IngestPhase.scanning) {
        return 'Looking for photos and videos…';
      }
      final current = pr.current;
      if (current == null) return 'Finishing…';
      if (_preview) return 'Checking $current';
      return 'Copying $current';
    }
    final s = _summary;
    if (s != null) {
      final notes = <String>[
        if (s.cancelled) 'Stopped early',
        if (s.dryRun) 'Preview only, nothing was copied',
        if (s.fallbackDates > 0)
          '${s.fallbackDates} dated from file timestamp',
      ];
      return notes.isEmpty ? 'Finished' : notes.join(' · ');
    }
    if (_selected.isEmpty) return 'Insert a card or add a folder to begin';
    if (_settings.destination == null) return 'Choose a destination folder';
    return 'Ready to import';
  }

  Widget _buildTopRow() {
    final String number;
    final String caption;
    String? detail;
    final s = _summary;
    final pr = _progress;

    if (_running && pr != null && pr.phase == IngestPhase.working) {
      number = '${pr.filesDone}';
      caption = 'of ${pr.filesTotal} files';
      final speed = _speed;
      detail = '${formatBytes(pr.bytesDone)} of ${formatBytes(pr.bytesTotal)}'
          '${speed == null ? '' : ' · ${formatBytes(speed.round())}/s'}';
    } else if (_running) {
      number = '—';
      caption = 'scanning';
    } else if (s != null) {
      number = '${s.imported}';
      caption = s.dryRun ? 'to import' : 'imported';
      detail = [
        '${s.skipped} skipped',
        if (s.failed > 0) '${s.failed} failed',
      ].join(' · ');
    } else {
      final stats = _selectedStats;
      number = stats == null ? '…' : '${stats.files}';
      caption = 'files ready';
      if (stats != null && stats.files > 0) detail = formatBytes(stats.bytes);
    }

    final failed = s != null && s.failed > 0;

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.end,
      spacing: 24,
      runSpacing: 16,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(number,
                style: mono(size: 64, color: Tone.accent, weight: FontWeight.w500)
                    .copyWith(height: 1)),
            const SizedBox(width: 12),
            Text(caption,
                style: const TextStyle(fontSize: 18, color: Tone.muted)),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (detail != null) ...[
              Text(detail,
                  style: mono(color: failed ? Tone.bad : Tone.muted)),
              const SizedBox(width: 16),
            ],
            if (_running)
              OutlinedButton(
                onPressed: (_cancel?.isCancelled ?? false) ? null : _stop,
                child: Text(
                    (_cancel?.isCancelled ?? false) ? 'Stopping…' : 'Stop'),
              )
            else ...[
              OutlinedButton(
                onPressed: _canStart ? () => _start(preview: true) : null,
                child: const Text('Preview'),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _canStart ? () => _start(preview: false) : null,
                child: const Text('Import'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        children: [
          const Icon(Icons.camera_outlined, color: Tone.accent, size: 22),
          const SizedBox(width: 12),
          const Text(
            appName,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.6),
          ),
          const Spacer(),
          Text(status, style: mono(size: 12, color: Tone.muted)),
        ],
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.selected,
    required this.stats,
    required this.enabled,
    required this.onChanged,
    this.onRemove,
  });

  final _Source source;
  final bool selected;
  final SourceStats? stats;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    return Material(
      color: selected ? Tone.surface : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: selected ? Tone.accent : Tone.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? () => onChanged(!selected) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: selected,
                onChanged: enabled ? (v) => onChanged(v ?? false) : null,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            source.card ? Icons.sd_card_outlined : Icons.folder_outlined,
                            size: 16,
                            color: Tone.muted,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(source.title,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w500)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(_shortPath(source.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono(size: 12, color: Tone.muted)),
                      const SizedBox(height: 4),
                      Text(
                        s == null
                            ? 'Counting…'
                            : '${s.files} files · ${formatBytes(s.bytes)}',
                        style: const TextStyle(fontSize: 12, color: Tone.muted),
                      ),
                    ],
                  ),
                ),
              ),
              if (onRemove != null)
                IconButton(
                  tooltip: 'Remove folder',
                  onPressed: enabled ? onRemove : null,
                  icon: const Icon(Icons.close, size: 18, color: Tone.muted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.value, this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final change = onChanged;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: change == null ? null : () => change(!value),
      child: Row(
        children: [
          Checkbox(
            value: value,
            onChanged: change == null ? null : (v) => change(v ?? false),
          ),
          const SizedBox(width: 4),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.value});
  final double? value;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 6,
        backgroundColor: Tone.line,
        color: Tone.accent,
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Tone.bad),
      ),
      child: Text(message, style: const TextStyle(color: Tone.bad)),
    );
  }
}

class _ResultTable extends StatelessWidget {
  const _ResultTable({required this.rows, required this.preview});
  final List<FileResult> rows;
  final bool preview;

  static const _statusWidth = 104.0;
  static const _thumbWidth = 60.0;
  static const _gap = 14.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Tone.line),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: Tone.surface,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                SizedBox(
                    width: _statusWidth,
                    child: Text('STATUS', style: labelStyle())),
                const SizedBox(width: _gap),
                SizedBox(
                    width: _thumbWidth,
                    child: Text('PREVIEW', style: labelStyle())),
                const SizedBox(width: _gap),
                Expanded(flex: 10, child: Text('FILE', style: labelStyle())),
                const SizedBox(width: _gap),
                Expanded(flex: 13, child: Text('RESULT', style: labelStyle())),
              ],
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text('Imported files will appear here.',
                        style: Theme.of(context).textTheme.bodySmall),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemExtent: 57,
                    itemBuilder: (context, index) =>
                        _row(rows[rows.length - 1 - index]), // newest first
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(FileResult r) {
    final (label, color) = switch (r.outcome) {
      Outcome.copied =>
        preview ? ('◇ new', Tone.accent) : ('● copied', Tone.accent),
      Outcome.skipped => ('○ skipped', Tone.muted),
      Outcome.failed => ('✕ failed', Tone.bad),
    };
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Tone.lineSoft)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: _statusWidth,
            child: Text(label, style: mono(size: 12, color: color)),
          ),
          const SizedBox(width: _gap),
          _Thumb(result: r),
          const SizedBox(width: _gap),
          Expanded(
            flex: 10,
            child: Text(r.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: mono()),
          ),
          const SizedBox(width: _gap),
          Expanded(
            flex: 13,
            child: Text(
              _friendlyDetail(r.detail),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Tone.muted),
            ),
          ),
        ],
      ),
    );
  }

  /// "→ 2025/07/IMG_0412.CR2" reads better in the table without the arrow.
  static String _friendlyDetail(String detail) =>
      detail.startsWith('→ ') ? detail.substring(2) : detail;
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.result});
  final FileResult result;

  static const _w = 60.0, _h = 40.0;

  @override
  Widget build(BuildContext context) {
    final bytes = result.thumbnail;
    final radius = BorderRadius.circular(4);

    if (bytes != null) {
      return ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          width: _w,
          height: _h,
          child: RotatedBox(
            quarterTurns: result.quarterTurns,
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, __, ___) => _placeholder(radius),
            ),
          ),
        ),
      );
    }
    return _placeholder(radius);
  }

  Widget _placeholder(BorderRadius radius) {
    final failed = result.outcome == Outcome.failed;
    final video = result.isVideo;
    return Container(
      width: _w,
      height: _h,
      decoration: BoxDecoration(
        color: failed ? Colors.transparent : Tone.line,
        borderRadius: radius,
        border: failed ? Border.all(color: Tone.outline) : null,
      ),
      alignment: Alignment.center,
      child: video
          ? const Icon(Icons.play_arrow_rounded, size: 20, color: Tone.text)
          : Text(
              failed ? '?' : p.extension(result.name).replaceFirst('.', ''),
              style: mono(size: 10, color: Tone.muted),
            ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Show home-relative paths as ~/...
String _shortPath(String path) {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home != null && home.isNotEmpty && p.isWithin(home, path)) {
    return p.join('~', p.relative(path, from: home));
  }
  return path;
}

String _duration(double seconds) {
  if (seconds < 60) return 'under a minute';
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  return '${hours}h ${minutes % 60}m';
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '$bytes B';
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}
