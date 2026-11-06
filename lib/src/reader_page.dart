import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'chunk_source.dart';
import 'format.dart';
import 'reader_api.dart';

/// Shows the PDF with pdfrx, fed from [source], and how much of the file has
/// been fetched so far.
class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.access,
    required this.source,
    required this.sinceOpen,
    required this.loadAllPages,
  });

  final PdfAccess access;

  /// This screen owns it from here: it is closed when pdfrx has closed the
  /// document.
  final ChunkSource source;

  /// Running since "Open PDF" was pressed.
  final Stopwatch sinceOpen;

  /// True: pdfrx's normal behaviour, which measures every page in the
  /// background after showing the first one, and so fetches the whole file
  /// within seconds. False: only the pages that are shown are fetched.
  final bool loadAllPages;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final _controller = PdfViewerController();
  late final Widget _viewer;
  late final Timer _refresh;

  bool _documentOpen = false;
  int? _page;
  int? _pageCount;
  int? _sliderPage;
  String? _readyNote;

  @override
  void initState() {
    super.initState();
    final source = widget.source;
    final layout = widget.access.layout;
    // Built once: the viewer must not be rebuilt each time the numbers below
    // it change.
    _viewer = PdfViewer(
      PdfDocumentRefCustom(
        fileSize: layout.fileSize,
        // pdfrx tells documents apart by this name, so every version of a
        // file needs its own.
        sourceName: 'np:${layout.version}',
        read: source.read,
        // Page 1 shows first; the other pages load afterwards.
        useProgressiveLoading: true,
        // pdfrx calls this once it has closed the document. Only then is it
        // safe to drop the chunks and the key: until then PDFium may still be
        // reading, and a read that fails can crash it.
        onDispose: source.dispose,
      ),
      controller: _controller,
      params: PdfViewerParams(
        behaviorControlParams: widget.loadAllPages
            ? const PdfViewerBehaviorControlParams()
            // pdfrx 2.4 has no setting for "measure a page only when it is
            // shown"; 2.5 added loadPageDimensionsOnDemand. Putting its
            // background pass off for a year has the same effect here. Pages
            // not measured yet are laid out with the last measured page's
            // size, and their text can't be selected.
            : const PdfViewerBehaviorControlParams(
                trailingPageLoadingDelay: Duration(days: 365),
              ),
        onDocumentChanged: (document) => _documentOpen = document != null,
        onViewerReady: (document, controller) => _onReady(document.pages.length),
        onPageChanged: (page) {
          if (mounted) setState(() => _page = page);
        },
        errorBannerBuilder: (context, error, stackTrace, documentRef) =>
            _Failure(error: source.lastError ?? error),
      ),
    );
    source.addListener(_onSourceChanged);
    // The read counters change far more often than the source reports.
    _refresh = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  void _onSourceChanged() {
    if (mounted) setState(() {});
  }

  void _onReady(int pageCount) {
    if (!mounted) return;
    final source = widget.source;
    setState(() {
      _pageCount = pageCount;
      _readyNote =
          'Viewer ready ${widget.sinceOpen.elapsedMilliseconds} ms after Open: '
          '${counted(source.requests, 'chunk request')}, '
          '${kilobytes(source.bytesDownloaded)} of '
          '${megabytes(widget.access.layout.fileSize)}.';
    });
  }

  @override
  void dispose() {
    _refresh.cancel();
    final source = widget.source;
    source.removeListener(_onSourceChanged);
    // Not dispose(): pdfrx closes the document after this, and PDFium may be
    // in the middle of a page. See ChunkSource.
    source.leave();
    if (!_documentOpen) source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final access = widget.access;
    final source = widget.source;
    final pageCount = _pageCount;
    final failure = source.failure;
    final waitingFor = source.waitingFor;
    return Scaffold(
      appBar: AppBar(
        title: Text(access.name.isEmpty ? 'PDF' : access.name),
        actions: [
          if (pageCount != null && failure == null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text('Page ${_page ?? 1} of $pageCount', key: const Key('pageNumber')),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (waitingFor != null && failure == null)
            Material(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              child: ListTile(
                key: const Key('waiting'),
                dense: true,
                leading: const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: const Text('Waiting for the network. Trying again…'),
                subtitle: Text('$waitingFor', maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ),
          // Once the file can't be read any more the viewer is taken away,
          // which makes pdfrx close the document.
          Expanded(child: failure == null ? _viewer : _Failure(error: failure)),
          if (pageCount != null && pageCount > 1 && failure == null)
            Slider(
              key: const Key('pageSlider'),
              min: 1,
              max: pageCount.toDouble(),
              divisions: pageCount - 1,
              value: (_sliderPage ?? _page ?? 1).clamp(1, pageCount).toDouble(),
              label: 'Page ${_sliderPage ?? _page ?? 1}',
              onChanged: (value) => setState(() => _sliderPage = value.round()),
              onChangeEnd: (value) {
                setState(() => _sliderPage = null);
                _controller.goToPage(pageNumber: value.round());
              },
            ),
          _Progress(
            source: source,
            readyNote: _readyNote,
            loadAllPages: widget.loadAllPages,
          ),
        ],
      ),
    );
  }
}

/// How much of the file is on the phone so far.
class _Progress extends StatelessWidget {
  const _Progress({
    required this.source,
    required this.readyNote,
    required this.loadAllPages,
  });

  final ChunkSource source;
  final String? readyNote;
  final bool loadAllPages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layout = source.layout;
    final loaded = source.loadedChunks;
    final fetched = source.plainBytesLoaded;
    final percent = layout.fileSize == 0 ? 100 : fetched * 100 ~/ layout.fileSize;
    final error = source.lastError;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Fetched ${loaded.length} of ${layout.totalChunks} chunks: '
                '${megabytes(fetched)} of ${megabytes(layout.fileSize)} ($percent%)',
                key: const Key('fetched'),
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              _ChunkMap(total: layout.totalChunks, loaded: loaded),
              const SizedBox(height: 4),
              Text(
                '${counted(source.requests, 'request')} · network '
                '${source.fetchTime.inMilliseconds} ms · decrypt '
                '${source.decryptTime.inMilliseconds} ms · the viewer made '
                '${counted(source.reads, 'read')} (${kilobytes(source.bytesRead)})',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                loadAllPages
                    ? 'The other pages load in the background.'
                    : 'A page is fetched only when it is shown.',
                style: theme.textTheme.bodySmall,
              ),
              if (readyNote != null)
                Text(readyNote!, key: const Key('viewerReady'), style: theme.textTheme.bodySmall),
              if (error != null)
                Text(
                  'Last failed read: $error',
                  key: const Key('failedRead'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One small square per chunk, filled once the chunk has been fetched.
class _ChunkMap extends StatelessWidget {
  const _ChunkMap({required this.total, required this.loaded});

  final int total;
  final Set<int> loaded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 44),
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [
            for (var index = 0; index < total; index++)
              Container(
                width: 8,
                height: 8,
                color: loaded.contains(index) ? scheme.primary : scheme.outlineVariant,
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown in place of the viewer when the PDF can't be opened or read.
class _Failure extends StatelessWidget {
  const _Failure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'This PDF can\'t be read.\n\n$error',
            key: const Key('failure'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Back'),
          ),
        ],
      ),
    ),
  );
}
