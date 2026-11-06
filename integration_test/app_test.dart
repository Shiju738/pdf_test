// Drives the real app on a phone or emulator: waits for the key pair, enters
// the access URL, opens the PDF and waits for the viewer.
//
//   flutter test integration_test/app_test.dart -d <device> \
//     --dart-define=ACCESS_URL=http://10.0.2.2:8000/api/v1/reader-test/access/
//
// Without ACCESS_URL the app's own default URL is used.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secure_pdf_reader_test/app/bindings/initial_binding.dart';
import 'package:secure_pdf_reader_test/main.dart';

const _accessUrl = String.fromEnvironment('ACCESS_URL');

/// Pumps frames until [finder] finds something, or fails after [timeout].
Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final clock = Stopwatch()..start();
  while (finder.evaluate().isEmpty) {
    if (clock.elapsed > timeout) {
      final steps = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .whereType<String>()
          .join('\n  ');
      fail('Nothing matched $finder after ${timeout.inSeconds} s. On screen:\n  $steps');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

String textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

/// The N in "Fetched N of M chunks: ...".
int fetchedChunks(WidgetTester tester) =>
    int.parse(textOf(tester, 'fetched').split(' ')[1]);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('makes a key pair, opens the PDF from the access URL and shows it', (
    tester,
  ) async {
    InitialBinding.dependencies();
    await tester.pumpWidget(const ReaderTestApp());

    // 1. The key pair: made on the first start, loaded afterwards.
    await waitFor(tester, find.textContaining('Fingerprint:'));
    debugPrint('KEY: ${textOf(tester, 'keyStatus')}');

    // 2. The access URL.
    if (_accessUrl.isNotEmpty) {
      await tester.enterText(find.byKey(const Key('accessUrl')), _accessUrl);
    }
    await tester.tap(find.byKey(const Key('openPdf')));

    // 3. Key exchange, unwrap, first chunks, then the viewer.
    await waitFor(tester, find.byKey(const Key('viewerReady')));
    debugPrint('READY: ${textOf(tester, 'viewerReady')}');
    debugPrint('PAGES: ${textOf(tester, 'pageNumber')}');
    final atReady = textOf(tester, 'fetched');
    debugPrint('AT READY: $atReady');
    expect(textOf(tester, 'pageNumber'), startsWith('Page 1 of '));
    expect(find.textContaining('Last failed read'), findsNothing);

    // 4. The switch on the first screen is off, so a page is fetched only
    // when it is shown: with page 1 on screen most of the file stays away.
    await tester.pump(const Duration(seconds: 5));
    final onPageOne = fetchedChunks(tester);
    debugPrint('ON PAGE 1: ${textOf(tester, 'fetched')}');
    expect(textOf(tester, 'fetched'), isNot(contains('(100%)')));

    // 5. A jump to the middle of the book (a tap on the middle of the page
    // slider) brings the chunks of that part, and still not the whole file.
    final jumpClock = Stopwatch()..start();
    await tester.tap(find.byKey(const Key('pageSlider')));
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (!textOf(tester, 'pageNumber').startsWith('Page 1 of ') &&
          fetchedChunks(tester) > onPageOne) {
        break;
      }
    }
    debugPrint('AFTER THE JUMP (${jumpClock.elapsedMilliseconds} ms): '
        '${textOf(tester, 'pageNumber')}; ${textOf(tester, 'fetched')}');
    expect(textOf(tester, 'pageNumber'), isNot(startsWith('Page 1 of ')));
    expect(fetchedChunks(tester), greaterThan(onPageOne));
    expect(textOf(tester, 'fetched'), isNot(contains('(100%)')));
    expect(find.textContaining('Last failed read'), findsNothing);

    // 6. Back to the first screen: the steps are still listed there.
    await tester.pageBack();
    await waitFor(tester, find.textContaining('Unwrapped the file key'));
    expect(find.textContaining('Failed'), findsNothing);
  });
}
