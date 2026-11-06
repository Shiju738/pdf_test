// The chunk source: what the PDF viewer reads through. Served here by a
// stand-in for the chunks endpoint that keeps the server's rules.

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_pdf_reader_test/src/chunk_cipher.dart';
import 'package:secure_pdf_reader_test/src/chunk_source.dart';
import 'package:secure_pdf_reader_test/src/file_layout.dart';
import 'package:secure_pdf_reader_test/src/reader_api.dart';

import 'support/sample.dart';

/// A file of [chunks] small chunks, its plain bytes, and a server for it.
class TestFile {
  TestFile(this.pdf, this.server, this.fileKey);

  static Future<TestFile> make({int size = 10000, int chunkSize = 1024}) async {
    final random = Random(size);
    final pdf = Uint8List.fromList(List.generate(size, (_) => random.nextInt(256)));
    final fileKey = Uint8List.fromList(List.generate(32, (i) => 200 - i));
    final stored = await encryptLikeTheServer(pdf, fileKey: fileKey, chunkSize: chunkSize);
    final layout = FileLayout(
      version: 'test',
      fileSize: size,
      chunkSize: chunkSize,
      totalChunks: size == 0 ? 1 : (size + chunkSize - 1) ~/ chunkSize,
      header: stored.sublist(0, headerSize),
    );
    return TestFile(pdf, FakeChunkServer(layout, stored), fileKey);
  }

  final Uint8List pdf;
  final FakeChunkServer server;
  final Uint8List fileKey;

  FileLayout get layout => server.layout;

  ChunkSource source({int maxCachedChunks = 128}) => ChunkSource(
    layout: layout,
    fetch: server.fetch,
    cipher: ChunkCipher(layout: layout, fileKey: fileKey, inBackground: false),
    maxCachedChunks: maxCachedChunks,
    firstRetryDelay: Duration.zero,
    failedReadDelay: Duration.zero,
    leavingGrace: const Duration(milliseconds: 50),
    isTemporary: ReaderApi.isTemporary,
  );

  /// Reads through [source] and checks the bytes against the plain file.
  Future<void> expectRead(ChunkSource source, int position, int size) async {
    final buffer = Uint8List(size);
    expect(await source.read(buffer, position, size), size, reason: 'read $position+$size');
    expect(buffer, pdf.sublist(position, position + size), reason: 'bytes $position+$size');
  }
}

void main() {
  test('the sample file reads correctly at any position', () async {
    final access = jsonFixture('access.json');
    final expected = jsonFixture('expected.json');
    final layout = layoutOf(access);
    final server = FakeChunkServer(layout, fixture('sample.pdf.enc').readAsBytesSync());
    final source = ChunkSource(
      layout: layout,
      fetch: server.fetch,
      cipher: ChunkCipher(layout: layout, fileKey: unhex(expected['file_key_hex'] as String)),
    );

    // Like pdfrx with a small file: everything in one read.
    final whole = Uint8List(layout.fileSize);
    expect(await source.read(whole, 0, layout.fileSize), layout.fileSize);
    expect(sha256(whole), expected['pdf_sha256']);
    expect(server.requests, ['0-2']);

    // Like PDFium: small pieces, anywhere, some across a chunk boundary.
    final random = Random(1);
    for (var i = 0; i < 300; i++) {
      final size = 1 + random.nextInt(3000);
      final position = random.nextInt(layout.fileSize - size);
      final piece = Uint8List(size);
      expect(await source.read(piece, position, size), size);
      expect(piece, Uint8List.sublistView(whole, position, position + size));
    }
    final end = Uint8List(700);
    expect(await source.read(end, layout.fileSize - 700, 700), 700);
    expect(end, whole.sublist(layout.fileSize - 700));
    expect(server.requests, hasLength(1), reason: 'everything else came from the cache');
    source.dispose();
  });

  test('opening fetches the first and last chunk in one request', () async {
    final file = await TestFile.make();
    final source = file.source();
    await source.prefetchEnds();
    expect(file.server.requests, ['0,9']);
    expect(source.loadedChunks, {0, 9});
    expect(source.plainBytesLoaded, 1024 + (10000 - 9 * 1024));

    await file.expectRead(source, 0, 100);
    await file.expectRead(source, 9990, 10);
    expect(file.server.requests, hasLength(1));
    source.dispose();
  });

  test('a file of one chunk asks for it once', () async {
    final file = await TestFile.make(size: 500);
    final source = file.source();
    await source.prefetchEnds();
    expect(file.server.requests, ['0']);
    await file.expectRead(source, 0, 500);
    source.dispose();
  });

  test('a read gets only the chunks it needs, as one request', () async {
    final file = await TestFile.make();
    final source = file.source();
    await file.expectRead(source, 2048, 10); // inside chunk 2
    await file.expectRead(source, 3000, 2000); // chunks 2 to 4: 2 is cached
    await file.expectRead(source, 4096 - 1, 2); // the boundary of 3 and 4
    expect(file.server.requests, ['2', '3-4']);
    expect(source.requests, 2);
    expect(source.reads, 3);
    expect(source.bytesRead, 2012);
    expect(source.bytesDownloaded, 3 * 1040);
    source.dispose();
  });

  test('a long read is split into requests the server accepts', () async {
    // 64 KB chunks: the server sends 64 of them at most (4 MB).
    final file = await TestFile.make(size: 100 * 65536, chunkSize: 65536);
    final source = file.source();
    final whole = Uint8List(file.pdf.length);
    expect(await source.read(whole, 0, whole.length), whole.length);
    expect(whole, file.pdf);
    expect(file.server.requests, ['0-63', '64-99']);
    source.dispose();
  });

  test('two reads that need the same chunk share one request', () async {
    final file = await TestFile.make();
    final source = file.source();
    await Future.wait([
      file.expectRead(source, 5000, 10),
      file.expectRead(source, 5100, 10),
      file.expectRead(source, 5000, 2000), // chunk 4 again, and 5 and 6
    ]);
    expect(file.server.requests, ['4', '5-6']);
    source.dispose();
  });

  test('the cache stays small but keeps the first and last chunk', () async {
    final file = await TestFile.make(size: 40 * 1024);
    final source = file.source(maxCachedChunks: 4);
    await source.prefetchEnds();
    for (var index = 1; index < 39; index++) {
      await file.expectRead(source, index * 1024 + 5, 20);
    }
    final before = file.server.requests.length;
    await file.expectRead(source, 0, 10); // never dropped
    await file.expectRead(source, 40 * 1024 - 10, 10); // never dropped
    await file.expectRead(source, 38 * 1024, 10); // still cached
    expect(file.server.requests, hasLength(before));
    await file.expectRead(source, 1024, 10); // dropped long ago: fetched again
    expect(file.server.requests.last, '1');
    expect(source.loadedChunks, hasLength(40));
    source.dispose();
  });

  group('when a request fails', () {
    test('trouble that may pass is waited out, however long it takes', () async {
      final file = await TestFile.make();
      final source = file.source();
      var failures = 7;
      file.server.beforeAnswer = (_) {
        if (failures-- > 0) throw Exception('connection reset');
      };
      final seen = <Object?>[];
      source.addListener(() => seen.add(source.waitingFor));

      await file.expectRead(source, 0, 100);
      expect(file.server.requests, hasLength(8));
      expect(seen.whereType<Exception>(), isNotEmpty, reason: 'the screen was told it is waiting');
      expect(source.waitingFor, isNull);
      expect(source.failure, isNull);
      expect(source.lastError, isNull);
      source.dispose();
    });

    test('a refusal from the server stops the source for good', () async {
      final file = await TestFile.make();
      final source = file.source();
      await file.expectRead(source, 0, 100); // chunk 0 is cached now
      file.server.beforeAnswer = (_) =>
          throw ApiException(409, 'version_changed', 'This file has changed. Open it again.');

      expect(await source.read(Uint8List(10), 2048, 10), 0);
      expect(file.server.requests, hasLength(2), reason: 'a refusal is not tried again');
      expect(source.failure, isA<ApiException>());
      expect((source.failure! as ApiException).code, 'version_changed');

      // Nothing is asked for or given out any more, cached or not.
      expect(await source.read(Uint8List(10), 5000, 10), 0);
      expect(await source.read(Uint8List(10), 0, 10), 0);
      expect(file.server.requests, hasLength(2));
      source.dispose();
    });

    test('one damaged answer is fetched again', () async {
      final file = await TestFile.make();
      final source = file.source();
      var damage = 1;
      file.server.tamper = (answer) => damage-- > 0 ? (answer..[20] ^= 0x40) : answer;
      await file.expectRead(source, 0, 100);
      expect(file.server.requests, ['0', '0']);
      expect(source.failure, isNull);
      source.dispose();
    });

    test('answers that keep arriving damaged never reach the viewer', () async {
      final file = await TestFile.make();
      final source = file.source();
      file.server.tamper = (answer) => answer..[20] ^= 0x40;
      final buffer = Uint8List(100);
      expect(await source.read(buffer, 0, 100), 0);
      expect(buffer, everyElement(0), reason: 'nothing was copied');
      expect(file.server.requests, hasLength(3));
      expect(source.failure, isNotNull);
      source.dispose();

      // An answer of the wrong length is refused the same way.
      final other = await TestFile.make();
      final cut = other.source();
      other.server.tamper = (answer) => answer.sublist(0, answer.length - 1);
      expect(await cut.read(buffer, 2048, 100), 0);
      expect(buffer, everyElement(0));
      expect(cut.failure, isA<FormatException>());
      cut.dispose();
    });

    test('a read outside the file fails', () async {
      final file = await TestFile.make();
      final source = file.source();
      expect(await source.read(Uint8List(10), 9995, 10), 0);
      expect(await source.read(Uint8List(10), -1, 10), 0);
      expect(file.server.requests, isEmpty);
      expect(source.failure, isNull, reason: 'the file itself is fine');
      await file.expectRead(source, 0, 100);
      source.dispose();
    });
  });

  group('when the screen goes away', () {
    test('reads are still answered until the document is closed', () async {
      final file = await TestFile.make();
      final source = file.source();
      await file.expectRead(source, 0, 100);
      source.leave();
      await file.expectRead(source, 50, 100); // from the cache
      await file.expectRead(source, 5000, 100); // needs a request: still made
      expect(file.server.requests, ['0', '4']);
      source.dispose();
    });

    test('a read that was waiting for the network ends', () async {
      final file = await TestFile.make();
      final source = file.source();
      file.server.beforeAnswer = (_) => throw Exception('no network');
      final pending = source.read(Uint8List(10), 0, 10);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(source.waitingFor, isNotNull);

      source.leave();
      expect(await pending.timeout(const Duration(seconds: 2)), 0);
      expect(source.failure, isNull);
      // After leaving, a failed request is not repeated.
      final before = file.server.requests.length;
      expect(await source.read(Uint8List(10), 5000, 10), 0);
      expect(file.server.requests, hasLength(before + 1));
      source.dispose();
    });

    test('a read does not outlast a request that hangs', () async {
      final file = await TestFile.make();
      final source = file.source();
      file.server.beforeAnswer = null;
      final hanging = ChunkSource(
        layout: file.layout,
        fetch: (_) => Future<Uint8List>.delayed(const Duration(seconds: 30), () => Uint8List(0)),
        cipher: ChunkCipher(layout: file.layout, fileKey: file.fileKey, inBackground: false),
        failedReadDelay: Duration.zero,
        leavingGrace: const Duration(milliseconds: 50),
      );
      final pending = hanging.read(Uint8List(10), 0, 10);
      hanging.leave();
      expect(await pending.timeout(const Duration(seconds: 2)), 0);
      hanging.dispose();
      source.dispose();
    });
  });

  test('a closed source gives nothing and forgets its chunks', () async {
    final file = await TestFile.make();
    final source = file.source();
    await file.expectRead(source, 0, 100);
    source.dispose();
    expect(await source.read(Uint8List(100), 0, 100), 0);
    expect(file.server.requests, hasLength(1));
    source.dispose(); // a second call does nothing
  });
}
