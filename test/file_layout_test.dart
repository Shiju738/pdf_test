import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_pdf_reader_test/src/file_layout.dart';

FileLayout layout({required int fileSize, int chunkSize = 262144}) => FileLayout(
  version: 'v',
  fileSize: fileSize,
  chunkSize: chunkSize,
  totalChunks: fileSize == 0 ? 1 : (fileSize + chunkSize - 1) ~/ chunkSize,
  header: Uint8List(headerSize),
);

void main() {
  group('layout', () {
    test('lengths and offsets match the server\'s file', () {
      // The sample: 772,341 bytes of PDF stored as 772,417.
      final file = layout(fileSize: 772341);
      expect(file.totalChunks, 3);
      expect(file.storedLength(0), 262160);
      expect(file.storedLength(1), 262160);
      expect(file.storedLength(2), 772341 - 2 * 262144 + 16);
      expect(file.storedOffset(0), 28);
      expect(file.storedOffset(2), 28 + 2 * 262160);
      expect(file.storedOffset(2) + file.storedLength(2), 772417);
      expect(file.maxChunksPerRequest, 16);
    });

    test('a file that ends on a chunk boundary, and an empty one', () {
      final exact = layout(fileSize: 2 * 262144);
      expect(exact.totalChunks, 2);
      expect(exact.plainLength(1), 262144);
      final empty = layout(fileSize: 0);
      expect(empty.totalChunks, 1);
      expect(empty.storedLength(0), 16);
    });

    test('the nonce is the chunk number, then 1 only for the last chunk', () {
      final file = layout(fileSize: 772341);
      expect(file.nonce(0), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(file.nonce(1), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0]);
      expect(file.nonce(2), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1]);
      final big = layout(fileSize: 70000 * 1024, chunkSize: 1024);
      expect(big.nonce(66000), [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 208, 0]);
    });

    test('an answer is cut in the order asked, and must fit exactly', () {
      final file = layout(fileSize: 2500, chunkSize: 1024);
      final body = Uint8List(file.storedLength(2) + file.storedLength(0));
      final parts = file.split([2, 0], body);
      expect(parts.map((part) => part.length), [2500 - 2048 + 16, 1040]);
      expect(() => file.split([2, 0], Uint8List(body.length - 1)), throwsFormatException);
      expect(() => file.split([0], body), throwsFormatException);
    });

    test('values that don\'t fit together are refused', () {
      FileLayout make({int total = 3, int header = headerSize}) => FileLayout(
        version: 'v',
        fileSize: 772341,
        chunkSize: 262144,
        totalChunks: total,
        header: Uint8List(header),
      );
      expect(make, returnsNormally);
      expect(() => make(total: 4), throwsFormatException);
      expect(() => make(header: 27), throwsFormatException);
    });
  });

  group('requests', () {
    test('chunk numbers are written as runs', () {
      expect(chunksSpec([7]), '7');
      expect(chunksSpec([0, 1]), '0-1');
      expect(chunksSpec([0, 22]), '0,22');
      expect(chunksSpec([0, 1, 2, 5, 9, 10]), '0-2,5,9-10');
    });

    test('neighbours share a request', () {
      expect(planRequests([3, 1, 2, 3], maxChunks: 16), [
        [1, 2, 3],
      ]);
    });

    test('at most 4 runs a request', () {
      expect(planRequests([0, 2, 4, 6, 8, 10], maxChunks: 16), [
        [0, 2, 4, 6],
        [8, 10],
      ]);
      expect(planRequests([0, 1, 5, 6, 9, 20, 21, 30], maxChunks: 16), [
        [0, 1, 5, 6, 9, 20, 21],
        [30],
      ]);
    });

    test('at most the server\'s chunk count a request', () {
      final forty = [for (var i = 0; i < 40; i++) i];
      final plan = planRequests(forty, maxChunks: 16);
      expect(plan.map((request) => request.length), [16, 16, 8]);
      expect(plan.expand((request) => request), forty);
      expect(planRequests([0, 1, 2], maxChunks: 1), [
        [0],
        [1],
        [2],
      ]);
    });
  });
}
