// The key steps, checked against the sample set the server made
// (document/samples/encrypted-reading): the public key's encoding, the unwrap,
// and the decryption of every chunk.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:secure_pdf_reader_test/core/crypto/chunk_cipher.dart';
import 'package:secure_pdf_reader_test/core/crypto/der.dart';
import 'package:secure_pdf_reader_test/data/models/file_layout.dart';
import 'package:secure_pdf_reader_test/data/models/reader_key.dart';

import 'support/sample.dart';

void main() {
  late ReaderKey phone;
  late Map<String, dynamic> expected;
  late Uint8List stored;

  setUpAll(() {
    phone = samplePhoneKey();
    expected = jsonFixture('expected.json');
    stored = fixture('sample.pdf.enc').readAsBytesSync();
  });

  Uint8List storedChunk(FileLayout layout, int index) {
    final start = layout.storedOffset(index);
    return Uint8List.sublistView(stored, start, start + layout.storedLength(index));
  }

  group('the public key', () {
    test('is sent in the layout the server made for the same key', () {
      final sent = fixture('phone_public_key.b64').readAsStringSync().trim();
      expect(phone.publicKeyBase64, sent);
    });

    test('has the fingerprint the server would give it', () {
      expect(phone.fingerprint, sha256(base64Decode(phone.publicKeyBase64)));
      expect(phone.fingerprint, hasLength(64));
    });

    test('PKCS#1 is the same numbers without the wrapper', () {
      final pkcs1 = rsaPublicKeyPkcs1(phone.modulus, phone.publicExponent);
      final spki = phone.publicKeyDer;
      expect(spki.sublist(spki.length - pkcs1.length), pkcs1);
    });
  });

  group('unwrapping', () {
    for (final name in ['access.json', 'access-android-keystore.json']) {
      test('$name gives the file key', () {
        final access = jsonFixture(name);
        final fileKey = phone.unwrap(
          base64Decode(access['wrapped_key'] as String),
          algorithm: access['key_algorithm'] as String,
        );
        expect(hex(fileKey), expected['file_key_hex']);
      });
    }

    test('in the background gives the same key', () async {
      final access = jsonFixture('access.json');
      final fileKey = await phone.unwrapInBackground(
        base64Decode(access['wrapped_key'] as String),
        algorithm: access['key_algorithm'] as String,
      );
      expect(hex(fileKey), expected['file_key_hex']);
    });

    test('with the wrong algorithm name fails', () {
      final access = jsonFixture('access.json');
      final wrapped = base64Decode(access['wrapped_key'] as String);
      expect(
        () => phone.unwrap(wrapped, algorithm: ReaderKey.androidKeystoreAlgorithm),
        throwsA(anything),
      );
      expect(() => phone.unwrap(wrapped, algorithm: 'RSA-PKCS1'), throwsArgumentError);
    });

    test('a key wrapped for another phone does not open', () async {
      final other = await ReaderKey.generate();
      final access = jsonFixture('access.json');
      expect(
        () => other.unwrap(
          base64Decode(access['wrapped_key'] as String),
          algorithm: access['key_algorithm'] as String,
        ),
        throwsA(anything),
      );
    });
  });

  group('a new key pair', () {
    test('unwraps what its own public key wrapped, and survives storage', () async {
      final key = await ReaderKey.generate();
      expect(key.modulus.bitLength, ReaderKey.bits);
      expect(key.publicExponent, BigInt.from(65537));

      // What the server does with the public key it is sent.
      final fileKey = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));
      final oaep = OAEPEncoding.withSHA256(RSAEngine())
        ..init(
          true,
          PublicKeyParameter<RSAPublicKey>(RSAPublicKey(key.modulus, key.publicExponent)),
        );
      final wrapped = oaep.process(fileKey);
      expect(wrapped, hasLength(256));

      expect(key.unwrap(wrapped, algorithm: ReaderKey.algorithm), fileKey);
      final restored = ReaderKey.fromSecret(key.toSecret());
      expect(restored.unwrap(wrapped, algorithm: ReaderKey.algorithm), fileKey);
      expect(restored.fingerprint, key.fingerprint);
    });
  });

  group('decrypting', () {
    late FileLayout layout;
    late Uint8List fileKey;

    setUpAll(() {
      layout = layoutOf(jsonFixture('access.json'));
      fileKey = unhex(expected['file_key_hex'] as String);
    });

    test('the header is the stored file\'s first 28 bytes', () {
      expect(layout.header, stored.sublist(0, headerSize));
      expect(stored.length, headerSize + layout.fileSize + layout.totalChunks * tagSize);
    });

    for (final inBackground in [false, true]) {
      test('every chunk gives the expected bytes (background: $inBackground)', () async {
        final cipher = ChunkCipher(layout: layout, fileKey: fileKey, inBackground: inBackground);
        final indexes = [for (var i = 0; i < layout.totalChunks; i++) i];
        final chunks = await cipher.decrypt(indexes, [
          for (final index in indexes) storedChunk(layout, index),
        ]);
        final hashes = expected['chunk_sha256'] as List<dynamic>;
        for (final index in indexes) {
          expect(sha256(chunks[index]), hashes[index], reason: 'chunk $index');
          expect(chunks[index], hasLength(layout.plainLength(index)));
        }
        final pdf = [for (final chunk in chunks) ...chunk];
        expect(pdf, hasLength(layout.fileSize));
        expect(sha256(pdf), expected['pdf_sha256']);
        expect(ascii.decode(pdf.sublist(0, 5)), '%PDF-');
      });
    }

    test('a chunk under the wrong number is refused', () async {
      final cipher = ChunkCipher(layout: layout, fileKey: fileKey, inBackground: false);
      expect(
        cipher.decrypt([1], [storedChunk(layout, 0)]),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('a changed byte is refused', () async {
      final cipher = ChunkCipher(layout: layout, fileKey: fileKey, inBackground: false);
      final damaged = Uint8List.fromList(storedChunk(layout, 0))..[100] ^= 1;
      expect(cipher.decrypt([0], [damaged]), throwsA(isA<SecretBoxAuthenticationError>()));
    });

    test('the last chunk is not accepted as a middle one', () async {
      // The last chunk's nonce differs, so a cut-off file can't pass as whole.
      final cut = FileLayout(
        version: layout.version,
        fileSize: layout.chunkSize * 2,
        chunkSize: layout.chunkSize,
        totalChunks: 2,
        header: layout.header,
      );
      final cipher = ChunkCipher(layout: cut, fileKey: fileKey, inBackground: false);
      expect(cipher.decrypt([0], [storedChunk(layout, 0)]), completes);
      expect(
        cipher.decrypt([1], [storedChunk(layout, 1)]),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('a dropped key can\'t be used', () {
      final cipher = ChunkCipher(layout: layout, fileKey: fileKey, inBackground: false)..dispose();
      expect(() => cipher.decrypt([0], [storedChunk(layout, 0)]), throwsStateError);
    });
  });
}
