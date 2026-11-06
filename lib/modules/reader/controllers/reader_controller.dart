import 'dart:async';

import 'package:get/get.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/utils/format.dart';
import '../../../data/services/chunk_source.dart';
import '../../../data/services/reader_api.dart';
import '../reader_args.dart';

/// The reader screen: the PDF fed from [source], and how much of the file has
/// been fetched so far.
class ReaderController extends GetxController {
  ReaderController(this.args);

  final ReaderArgs args;

  PdfAccess get access => args.access;
  ChunkSource get source => args.source;
  bool get loadAllPages => args.loadAllPages;

  final pdfController = PdfViewerController();

  final page = RxnInt();
  final pageCount = RxnInt();

  /// The page under the slider's thumb while it is being dragged.
  final sliderPage = RxnInt();

  /// The page the user jumped to, until it is drawn: the screen shows
  /// "Loading page N…" meanwhile. Null when no jump is waiting.
  final loadingPage = RxnInt();
  final readyNote = RxnString();

  /// Bumped whenever the source's counters may have changed. The progress
  /// panel reads it so that it rebuilds; the counters live on [source].
  final tick = 0.obs;

  bool _documentOpen = false;
  Timer? _refresh;

  /// Checks, while [loadingPage] is set, whether that page is drawn yet.
  Timer? _loadingCheck;

  /// PDFium is taken to be done drawing once it has asked for no bytes for
  /// this long, with no read waiting for a chunk.
  static const _drawnQuiet = Duration(milliseconds: 150);

  /// If PDFium asks for no bytes at all this long after a jump, the page was
  /// drawn earlier and is on screen already.
  static const _notStartedLimit = Duration(milliseconds: 600);

  @override
  void onInit() {
    super.onInit();
    source.addListener(_onSourceChanged);
    // The read counters change far more often than the source reports.
    _refresh = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => tick.value++,
    );
  }

  @override
  void onClose() {
    _refresh?.cancel();
    _loadingCheck?.cancel();
    source.removeListener(_onSourceChanged);
    // Not dispose(): pdfrx closes the document after this, and PDFium may be
    // in the middle of a page. See ChunkSource.
    source.leave();
    if (!_documentOpen) source.dispose();
    super.onClose();
  }

  void _onSourceChanged() => tick.value++;

  // pdfrx callbacks, wired up in PdfPane.

  void onDocumentChanged(PdfDocument? document) =>
      _documentOpen = document != null;

  void onViewerReady(int count) {
    if (isClosed) return;
    pageCount.value = count;
    readyNote.value =
        'Viewer ready ${args.sinceOpen.elapsedMilliseconds} ms after Open: '
        '${counted(source.requests, 'chunk request')}, '
        '${source.chunksFromDevice} chunks from this device, '
        '${kilobytes(source.bytesDownloaded)} downloaded of '
        '${megabytes(access.layout.fileSize)}.';
  }

  void onPageChanged(int? value) {
    if (isClosed) return;
    final previous = page.value ?? 1;
    // A fast scroll skipped pages: get ahead of PDFium for the page it lands on.
    if (value != null && (value - previous).abs() > 2) _prepareJump(value);
    page.value = value;
    // The user scrolled away from the page they jumped to: stop waiting for it.
    final loading = loadingPage.value;
    if (loading != null && value != null && previous == loading && value != loading) {
      _stopLoading();
    }
  }

  /// Starts fetching the chunks of [target] before the viewer asks for them.
  /// See ChunkSource.prepareJump.
  void _prepareJump(int target) {
    if (const bool.fromEnvironment('NO_JUMP_HINT')) return;
    final count = pageCount.value;
    if (count == null || target == (page.value ?? 1)) return;
    source.prepareJump(target, count);
  }

  // Slider.

  /// While dragging, only the page number shown changes. Nothing is fetched
  /// and the viewer stays where it is, so the pages under the thumb on the
  /// way don't take the network from the page the user lets go on.
  void onSliderChanged(double value) => sliderPage.value = value.round();

  /// The finger lifts: go straight to that page.
  void onSliderChangeEnd(double value) {
    final target = value.round();
    sliderPage.value = null;
    if (target == (page.value ?? 1)) return;
    _prepareJump(target);
    _startLoading(target);
    // No animation: with one, every page between here and there scrolls past
    // for a moment, and PDFium (which draws one page at a time) would draw
    // them first. Duration.zero puts the viewer on the page in one step.
    pdfController.goToPage(pageNumber: target, duration: Duration.zero);
  }

  // "Loading page N…"

  void _startLoading(int target) {
    loadingPage.value = target;
    _loadingCheck?.cancel();
    final readsBefore = source.reads;
    final clock = Stopwatch()..start();
    var started = false;
    _loadingCheck = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (page.value != target) return; // not on the page yet
      // 1. PDFium starts on the page: it asks for bytes.
      started = started || source.reads > readsBefore || source.readsWaiting > 0;
      if (!started) {
        // Nothing asked for at all: the page was drawn before, and is shown.
        if (clock.elapsed > _notStartedLimit) _stopLoading();
        return;
      }
      // 2. Drawn: no read is waiting for a chunk, and PDFium has stopped
      // asking for bytes.
      if (source.readsWaiting == 0 && source.sinceLastRead >= _drawnQuiet) {
        _stopLoading();
      }
    });
  }

  void _stopLoading() {
    _loadingCheck?.cancel();
    _loadingCheck = null;
    if (!isClosed) loadingPage.value = null;
  }
}
