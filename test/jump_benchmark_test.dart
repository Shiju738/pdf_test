// How long a jump to the middle of a book takes through the chunk source,
// with a slow network simulated. Not a check: it prints numbers.
//
//   python3 tool/make_bench_pdf.py /tmp/book.pdf 100
//   flutter test test/jump_benchmark_test.dart \
//     --dart-define=BENCH_PDF=/tmp/book.pdf \
//     --dart-define=PDFIUM_PATH=/path/to/libpdfium.dylib
//
// Optional: LATENCY_MS (150), MB_PER_S (5), READ_AHEAD (8), PIECE (2),
// JUMP_HINT (1). On a Mac, PDFium
// is under .dart_tool/hooks_runner/shared/pdfium_dart/build/ after a build.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:secure_pdf_reader_test/core/crypto/chunk_cipher.dart';
import 'package:secure_pdf_reader_test/data/models/file_layout.dart';
import 'package:secure_pdf_reader_test/data/services/chunk_source.dart';

import 'support/sample.dart';

const _pdfPath = String.fromEnvironment('BENCH_PDF');
const _pdfiumPath = String.fromEnvironment('PDFIUM_PATH');

/// Default: a phone on mobile data, 150 ms to answer, then 5 MB/s.
const _latency = Duration(
  milliseconds: int.fromEnvironment('LATENCY_MS', defaultValue: 150),
);
const _bytesPerSecond =
    int.fromEnvironment('MB_PER_S', defaultValue: 5) * 1024 * 1024;
const _readAhead = int.fromEnvironment('READ_AHEAD', defaultValue: 8);
const _piece = int.fromEnvironment('PIECE', defaultValue: 2);
/// 1: tell the source about the jump, as the page slider does.
const _jumpHint = int.fromEnvironment('JUMP_HINT', defaultValue: 1);

void main() {
  final skip = _pdfPath.isEmpty || _pdfiumPath.isEmpty
      ? 'needs BENCH_PDF and PDFIUM_PATH'
      : null;

  test('jump to the middle page', () async {
    HttpOverrides.global = null;
    Pdfrx.pdfiumModulePath = _pdfiumPath;
    await pdfrxInitialize(tmpPath: Directory.systemTemp.createTempSync('pdfrx').path);

    final pdf = File(_pdfPath).readAsBytesSync();
    const chunkSize = 256 * 1024;
    final fileKey = Uint8List.fromList(List.generate(32, (i) => i));
    final stored = await encryptLikeTheServer(pdf, fileKey: fileKey, chunkSize: chunkSize);
    final layout = FileLayout(
      version: 'bench',
      fileSize: pdf.length,
      chunkSize: chunkSize,
      totalChunks: (pdf.length + chunkSize - 1) ~/ chunkSize,
      header: stored.sublist(0, headerSize),
    );
    final server = FakeChunkServer(layout, stored);
    final source = ChunkSource(
      layout: layout,
      cipher: ChunkCipher(layout: layout, fileKey: fileKey),
      maxReadAhead: _readAhead,
      readAheadPiece: _piece,
      fetch: (chunks) async {
        final answer = await server.fetch(chunks);
        await Future<void>.delayed(
          _latency + Duration(microseconds: answer.length * 1000000 ~/ _bytesPerSecond),
        );
        return answer;
      },
    );

    await source.prefetchEnds();
    final document = await PdfDocument.openCustom(
      read: source.read,
      fileSize: layout.fileSize,
      sourceName: 'np:bench',
      useProgressiveLoading: true,
    );
    final first = document.pages.first;
    (await first.render(fullWidth: first.width, fullHeight: first.height))?.dispose();
    final before = server.requests.length;
    final fetchBefore = source.fetchTime, decryptBefore = source.decryptTime;
    // ignore: avoid_print
    print('${document.pages.length} pages, ${layout.totalChunks} chunks; '
        'page 1 shown after ${server.requests}');

    final target = document.pages.length ~/ 2;
    final clock = Stopwatch()..start();
    if (_jumpHint == 1) source.prepareJump(target, document.pages.length);
    final page = document.pages[target - 1];
    final image = await page.render(fullWidth: page.width, fullHeight: page.height);
    expect(image, isNotNull);
    image!.dispose();
    // ignore: avoid_print
    print('JUMP to page $target: ${clock.elapsedMilliseconds} ms, '
        'requests ${server.requests.sublist(before)}; network '
        '${(source.fetchTime - fetchBefore).inMilliseconds} ms, decrypt '
        '${(source.decryptTime - decryptBefore).inMilliseconds} ms, '
        '${source.loadedChunks.length} chunks fetched in all');

    await document.dispose();
    source.dispose();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
