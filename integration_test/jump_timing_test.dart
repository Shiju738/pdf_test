// Times direct jumps in the reader against the real backend: release the
// page slider on page N, then wait until page N is drawn. The chunks saved on
// the device are deleted first, so every chunk comes from the server.
//
//   flutter test integration_test/jump_timing_test.dart -d <device> \
//     --dart-define=ACCESS_URL=https://…/api/v1/reader-test/access/ \
//     --dart-define=JUMPS=25
//
// "Drawn" means: the viewer is on page N, no read from PDFium is waiting for
// a chunk, and PDFium has asked for nothing for 150 ms. PDFium only stops
// asking once it has finished drawing. Chunks still arriving that nothing
// waits for (read-ahead) are not counted.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secure_pdf_reader_test/app/bindings/initial_binding.dart';
import 'package:secure_pdf_reader_test/data/services/chunk_store.dart';
import 'package:secure_pdf_reader_test/main.dart';
import 'package:secure_pdf_reader_test/modules/reader/controllers/reader_controller.dart';

const _accessUrl = String.fromEnvironment('ACCESS_URL');
const _jumps = String.fromEnvironment('JUMPS', defaultValue: '25');
const _quiet = Duration(milliseconds: 150);

Future<void> waitUntil(WidgetTester tester, bool Function() done, {int seconds = 60}) async {
  final clock = Stopwatch()..start();
  while (!done()) {
    if (clock.elapsed.inSeconds > seconds) fail('timed out');
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('direct jumps', (tester) async {
    InitialBinding.dependencies();
    await Get.find<ChunkStore>().clear(); // a book not on the device
    await tester.pumpWidget(const ReaderTestApp());
    await waitUntil(tester, () => find.textContaining('Fingerprint:').evaluate().isNotEmpty);
    if (_accessUrl.isNotEmpty) {
      await tester.enterText(find.byKey(const Key('accessUrl')), _accessUrl);
    }
    await tester.tap(find.byKey(const Key('openPdf')));
    await waitUntil(tester, () => find.byKey(const Key('viewerReady')).evaluate().isNotEmpty);
    final reader = Get.find<ReaderController>();
    final source = reader.source;
    // Page 1 is drawn and the network is quiet, as when a user starts reading.
    await tester.pump(const Duration(seconds: 3));
    await waitUntil(tester, () => !source.isFetching && source.readsWaiting == 0);
    debugPrint('JUMP-START: ${source.loadedChunks.length} chunks here before the jump: '
        '${source.loadedChunks.toList()}');

    for (final target in _jumps.split(',').map(int.parse)) {
      final requests = source.requests, bytes = source.bytesDownloaded;
      final readsBefore = source.reads;
      debugPrint('JUMP-RELEASE on page $target');
      final clock = Stopwatch()..start();
      reader.onSliderChangeEnd(target.toDouble()); // the finger lifts
      await waitUntil(tester, () => reader.page.value == target);
      final onPage = clock.elapsedMilliseconds;
      // PDFium starts on the page (asks for bytes), then finishes: no read
      // waiting and nothing asked for 150 ms.
      await waitUntil(tester, () => source.reads > readsBefore || source.readsWaiting > 0);
      await waitUntil(
        tester,
        () => source.readsWaiting == 0 && source.sinceLastRead >= _quiet,
      );
      final drawn = clock.elapsedMilliseconds - _quiet.inMilliseconds;
      // The "Loading page N…" label (Step 1 and later) goes away by itself.
      var label = 'no label';
      try {
        await waitUntil(tester, () => (reader as dynamic).loadingPage.value == null, seconds: 5);
        label = '${clock.elapsedMilliseconds} ms';
      } on NoSuchMethodError {
        // Before Step 1 there was no label.
      }
      debugPrint('JUMP $target: on the page after $onPage ms, drawn after ~$drawn ms, '
          'label gone after $label; '
          '${source.requests - requests} requests, '
          '${((source.bytesDownloaded - bytes) / 1024).round()} KB downloaded meanwhile');
      await tester.pump(const Duration(seconds: 2));
    }
  });
}
