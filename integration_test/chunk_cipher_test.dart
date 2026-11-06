// On a phone or simulator: the platform's AES-GCM (through
// cryptography_flutter) opens chunks exactly as the pure-Dart one does, and
// how much faster it is.
//
//   flutter test integration_test/chunk_cipher_test.dart -d <device>

import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secure_pdf_reader_test/core/crypto/chunk_cipher.dart';
import 'package:secure_pdf_reader_test/data/models/file_layout.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const chunkSize = 256 * 1024;
  const count = 8;
  final random = Random(1);
  final fileKey = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
  final header = Uint8List.fromList(List.generate(headerSize, (_) => random.nextInt(256)));
  final layout = FileLayout(
    version: 'native-test',
    fileSize: chunkSize * count,
    chunkSize: chunkSize,
    totalChunks: count,
    header: header,
  );
  final plain = [
    for (var i = 0; i < count; i++)
      Uint8List.fromList(List.generate(chunkSize, (_) => random.nextInt(256))),
  ];
  final indexes = List.generate(count, (i) => i);

  Future<List<Uint8List>> encrypt() async {
    final aes = DartAesGcm.with256bits();
    return [
      for (final i in indexes)
        await () async {
          final box = await aes.encrypt(
            plain[i],
            secretKey: SecretKey(fileKey),
            nonce: layout.nonce(i),
            aad: header,
          );
          return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
        }(),
    ];
  }

  test('the platform AES-GCM is there and opens chunks like the Dart one', () async {
    expect(ChunkCipher.platformAes, isNotNull, reason: 'cryptography_flutter is not active');
    final stored = await encrypt();

    final native = ChunkCipher(layout: layout, fileKey: fileKey);
    var clock = Stopwatch()..start();
    final fromNative = await native.decrypt(indexes, stored);
    final nativeMs = clock.elapsedMilliseconds;

    final dart = ChunkCipher(
      layout: layout,
      fileKey: fileKey,
      nativeAes: DartAesGcm.with256bits(),
    );
    clock = Stopwatch()..start();
    final fromDart = await dart.decrypt(indexes, stored);
    final dartMs = clock.elapsedMilliseconds;

    for (final i in indexes) {
      expect(fromNative[i], plain[i], reason: 'native chunk $i');
      expect(fromDart[i], plain[i], reason: 'Dart chunk $i');
    }
    debugPrint('DECRYPT $count chunks of 256 KB: native $nativeMs ms, pure Dart $dartMs ms');

    // A changed byte, or the wrong chunk number, must not open.
    final damaged = Uint8List.fromList(stored[3])..[100] ^= 1;
    await expectLater(native.decrypt([3], [damaged]), throwsA(isA<SecretBoxAuthenticationError>()));
    await expectLater(native.decrypt([4], [stored[3]]), throwsA(isA<SecretBoxAuthenticationError>()));
    native.dispose();
    dart.dispose();
  });
}
