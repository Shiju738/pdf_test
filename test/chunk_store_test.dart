// Chunks kept on the device: a second open of the same file reads them from
// there instead of the network.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_pdf_reader_test/core/crypto/chunk_cipher.dart';
import 'package:secure_pdf_reader_test/data/models/file_layout.dart';
import 'package:secure_pdf_reader_test/data/services/chunk_source.dart';
import 'package:secure_pdf_reader_test/data/services/chunk_store.dart';

import 'support/sample.dart';

void main() {
  late Uint8List pdf;
  late Uint8List fileKey;
  late FileLayout layout;
  late Uint8List encrypted;

  setUpAll(() async {
    const size = 10000, chunkSize = 1024;
    final random = Random(7);
    pdf = Uint8List.fromList(List.generate(size, (_) => random.nextInt(256)));
    fileKey = Uint8List.fromList(List.generate(32, (i) => 100 + i));
    encrypted = await encryptLikeTheServer(pdf, fileKey: fileKey, chunkSize: chunkSize);
    layout = FileLayout(
      version: 'v1',
      fileSize: size,
      chunkSize: chunkSize,
      totalChunks: (size + chunkSize - 1) ~/ chunkSize,
      header: encrypted.sublist(0, headerSize),
    );
  });

  ChunkSource sourceWith(FakeChunkServer server, StoredChunks stored) => ChunkSource(
    layout: layout,
    fetch: server.fetch,
    stored: stored,
    maxReadAhead: 0,
    cipher: ChunkCipher(layout: layout, fileKey: fileKey, inBackground: false),
    firstRetryDelay: Duration.zero,
    failedReadDelay: Duration.zero,
  );

  Future<void> readAll(ChunkSource source) async {
    final buffer = Uint8List(layout.fileSize);
    expect(await source.read(buffer, 0, layout.fileSize), layout.fileSize);
    expect(buffer, pdf);
  }

  test('a second open reads every chunk from the device', () async {
    final stored = MemoryChunks();
    final first = FakeChunkServer(layout, encrypted);
    final a = sourceWith(first, stored);
    await readAll(a);
    a.dispose();
    await Future<void>.delayed(Duration.zero); // writes finish
    expect(stored.chunks.keys.toSet(), {for (var n = 0; n < layout.totalChunks; n++) n});

    final second = FakeChunkServer(layout, encrypted);
    final b = sourceWith(second, stored);
    await readAll(b);
    expect(second.requests, isEmpty);
    expect(b.bytesDownloaded, 0);
    expect(b.chunksFromDevice, layout.totalChunks);
    b.dispose();
  });

  test('only the chunks missing on the device are fetched', () async {
    final stored = MemoryChunks();
    final a = sourceWith(FakeChunkServer(layout, encrypted), stored);
    expect(await a.read(Uint8List(100), 0, 100), 100); // chunk 0
    a.dispose();
    await Future<void>.delayed(Duration.zero);

    final server = FakeChunkServer(layout, encrypted);
    final b = sourceWith(server, stored);
    await readAll(b);
    expect(server.requests, ['1-9']);
    b.dispose();
  });

  test('a damaged stored chunk is dropped and fetched again', () async {
    final stored = MemoryChunks();
    final a = sourceWith(FakeChunkServer(layout, encrypted), stored);
    await readAll(a);
    a.dispose();
    await Future<void>.delayed(Duration.zero);
    stored.chunks[3]![5] ^= 0xff;

    final server = FakeChunkServer(layout, encrypted);
    final b = sourceWith(server, stored);
    final buffer = Uint8List(1024);
    expect(await b.read(buffer, 3 * 1024, 1024), 1024);
    expect(buffer, pdf.sublist(3 * 1024, 4 * 1024));
    expect(server.requests, ['3']);
    expect(b.failure, isNull);
    b.dispose();
  });

  group('ChunkStore on disk', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('chunk_store_'));
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('keeps chunks per file version, not per token', () async {
      final store = ChunkStore(root: () async => root);
      final url = Uri.parse('http://host/chunks/?version=v1&token=A');
      final chunk = encrypted.sublist(headerSize, headerSize + layout.storedLength(0));

      await (await store.open(url, layout)).write(0, chunk);
      // A new token on the next access call: the same file.
      final again = await store.open(url.replace(queryParameters: {'token': 'B'}), layout);
      expect(await again.read(0), chunk);
      expect(await again.read(1), isNull);

      final replaced = FileLayout(
        version: 'v2',
        fileSize: layout.fileSize,
        chunkSize: layout.chunkSize,
        totalChunks: layout.totalChunks,
        header: layout.header,
      );
      expect(await (await store.open(url, replaced)).read(0), isNull);
    });

    test('size counts the saved chunks and clear deletes them', () async {
      final store = ChunkStore(root: () async => root);
      final chunks = await store.open(Uri.parse('http://host/c/'), layout);
      final chunk = encrypted.sublist(headerSize, headerSize + layout.storedLength(0));
      await chunks.write(0, chunk);
      expect(await store.size(), chunk.length);
      await store.clear();
      expect(await store.size(), 0);
      expect(await chunks.read(0), isNull);
    });

    test('a chunk of the wrong length is ignored', () async {
      final store = ChunkStore(root: () async => root);
      final chunks = await store.open(Uri.parse('http://host/c/'), layout);
      await chunks.write(0, Uint8List(10));
      expect(await chunks.read(0), isNull);
    });
  });
}
