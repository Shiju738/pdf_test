// The whole flow against a real server, without the screens: make a key
// pair, send the public key, unwrap the file key, and let pdfrx's engine read
// the PDF through the chunk source.
//
// Skipped unless a server is named:
//
//   flutter test test/live_backend_test.dart \
//     --dart-define=READER_TEST_URL=http://127.0.0.1:8000/api/v1/reader-test/access/
//
// The engine part needs PDFium for this computer. Give its path with
// --dart-define=PDFIUM_PATH=C:\path\to\pdfium.dll to run it.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:secure_pdf_reader_test/src/chunk_cipher.dart';
import 'package:secure_pdf_reader_test/src/chunk_source.dart';
import 'package:secure_pdf_reader_test/src/format.dart';
import 'package:secure_pdf_reader_test/src/reader_api.dart';
import 'package:secure_pdf_reader_test/src/reader_key.dart';

const _accessUrl = String.fromEnvironment('READER_TEST_URL');
const _pdfiumPath = String.fromEnvironment('PDFIUM_PATH');

void main() {
  final skip = _accessUrl.isEmpty ? 'no READER_TEST_URL given' : null;
  late ReaderKey key;
  late ReaderApi api;

  setUpAll(() async {
    if (skip != null) return;
    // flutter_test answers every HTTP call with 400 unless told otherwise.
    HttpOverrides.global = null;
    key = await ReaderKey.generate();
    api = ReaderApi();
  });

  tearDownAll(() {
    if (skip == null) api.close();
  });

  Future<(PdfAccess, ChunkSource)> open() async {
    final access = await api.requestAccess(
      Uri.parse(_accessUrl),
      publicKey: key.publicKeyBase64,
      algorithm: ReaderKey.algorithm,
    );
    final fileKey = await key.unwrapInBackground(
      access.wrappedKey,
      algorithm: access.keyAlgorithm,
    );
    final source = ChunkSource(
      layout: access.layout,
      cipher: ChunkCipher(layout: access.layout, fileKey: fileKey),
      fetch: (chunks) => api.fetchChunks(access.streamUrl, chunks),
      isTemporary: ReaderApi.isTemporary,
    );
    return (access, source);
  }

  String progress(ChunkSource source) =>
      '${source.requests} requests, ${source.loadedChunks.length} of '
      '${source.layout.totalChunks} chunks, ${kilobytes(source.bytesDownloaded)}';

  test('the PDF arrives whole and correct through the chunk source', () async {
    final (access, source) = await open();
    final layout = access.layout;
    // ignore: avoid_print
    print('file: "${access.name}", ${access.pages} pages, ${megabytes(layout.fileSize)}, '
        '${layout.totalChunks} chunks of ${kilobytes(layout.chunkSize)}; '
        'stream: ${access.streamUrl.path}');

    await source.prefetchEnds();
    expect(source.requests, 1);
    final start = Uint8List(1024);
    expect(await source.read(start, 0, 1024), 1024);
    expect(ascii.decode(start.sublist(0, 5)), '%PDF-');
    final tail = Uint8List(1024);
    expect(await source.read(tail, layout.fileSize - 1024, 1024), 1024);
    expect(latin1.decode(tail), contains('%%EOF'));
    expect(source.requests, 1, reason: 'both ends came with the first request');

    // The rest, in odd-sized pieces.
    final pdf = BytesBuilder();
    for (var position = 0; position < layout.fileSize;) {
      final size = (position + 300007 > layout.fileSize) ? layout.fileSize - position : 300007;
      final piece = Uint8List(size);
      expect(await source.read(piece, position, size), size, reason: '${source.lastError}');
      pdf.add(piece);
      position += size;
    }
    expect(pdf.length, layout.fileSize);
    expect(source.loadedChunks, hasLength(layout.totalChunks));
    // ignore: avoid_print
    print('whole file: ${progress(source)}; network ${source.fetchTime.inMilliseconds} ms, '
        'decrypt ${source.decryptTime.inMilliseconds} ms');
    source.dispose();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

  test('a key pair the server has not seen gets its own wrapped key', () async {
    final (first, firstSource) = await open();
    final (second, secondSource) = await open();
    expect(second.layout.version, first.layout.version);
    expect(second.wrappedKey, isNot(first.wrappedKey), reason: 'OAEP wraps afresh each time');
    firstSource.dispose();
    secondSource.dispose();
  }, skip: skip);

  test('pdfrx opens it through the read function and draws page 1', () async {
    Pdfrx.pdfiumModulePath = _pdfiumPath;
    await pdfrxInitialize(tmpPath: Directory.systemTemp.createTempSync('pdfrx').path);
    final (access, source) = await open();
    final clock = Stopwatch()..start();
    await source.prefetchEnds();

    final document = await PdfDocument.openCustom(
      read: source.read,
      fileSize: access.layout.fileSize,
      sourceName: 'np:${access.layout.version}',
      useProgressiveLoading: true,
    );
    expect(source.lastError, isNull);
    // The book's record and its PDF can disagree on the page count, so the
    // count is only reported.
    expect(document.pages, isNotEmpty);
    // ignore: avoid_print
    print('opened in ${clock.elapsedMilliseconds} ms: ${document.pages.length} pages in the PDF '
        '(the server says ${access.pages}); ${progress(source)}, '
        '${source.reads} reads from PDFium');

    final page = document.pages.first;
    final image = await page.render(fullWidth: page.width, fullHeight: page.height);
    expect(image, isNotNull);
    expect(image!.width, greaterThan(100));
    expect(image.pixels.any((byte) => byte != 0xff && byte != 0), isTrue, reason: 'not blank');
    image.dispose();
    // ignore: avoid_print
    print('page 1 drawn after ${clock.elapsedMilliseconds} ms: ${progress(source)}, '
        '${source.reads} reads from PDFium');

    // What the viewer does next, in the background: measure every page.
    await document.loadPagesProgressively();
    expect(document.pages.every((page) => page.isLoaded), isTrue);
    // ignore: avoid_print
    print('every page loaded after ${clock.elapsedMilliseconds} ms: ${progress(source)}, '
        '${source.reads} reads from PDFium');

    await document.dispose();
    source.dispose();
  }, skip: skip ?? (_pdfiumPath.isEmpty ? 'no PDFIUM_PATH given' : null),
      timeout: const Timeout(Duration(minutes: 5)));
}
