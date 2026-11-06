/// The sample set from `document/samples/encrypted-reading`, and a stand-in
/// for the chunks endpoint that serves an encrypted file from memory.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart';
import 'package:secure_pdf_reader_test/src/file_layout.dart';
import 'package:secure_pdf_reader_test/src/reader_key.dart';

File fixture(String name) => File('test/fixtures/$name');

Map<String, dynamic> jsonFixture(String name) =>
    jsonDecode(fixture(name).readAsStringSync()) as Map<String, dynamic>;

String hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16),
]);

String sha256(List<int> bytes) => hex(SHA256Digest().process(Uint8List.fromList(bytes)));

/// The layout an `access` answer describes.
FileLayout layoutOf(Map<String, dynamic> access) => FileLayout(
  version: access['version'] as String,
  fileSize: access['file_size'] as int,
  chunkSize: access['chunk_size'] as int,
  totalChunks: access['total_chunks'] as int,
  header: base64Decode(access['header'] as String),
);

/// The test phone's key pair, from its PKCS#8 PEM file.
ReaderKey samplePhoneKey() {
  final pem = fixture('phone_private_key.pem').readAsStringSync();
  final der = base64Decode(
    const LineSplitter()
        .convert(pem)
        .map((line) => line.trim())
        .where((line) => !line.startsWith('-----'))
        .join(),
  );
  // PrivateKeyInfo { version, algorithm, OCTET STRING { RSAPrivateKey } }
  final info = _Der(_Der(der).next()); // inside the outer SEQUENCE
  info.next(); // version
  info.next(); // algorithm
  // RSAPrivateKey { version, n, e, d, p, q, ... }
  final key = _Der(_Der(info.next()).next());
  key.next(); // version
  final numbers = [for (var i = 0; i < 5; i++) hex(key.next())];
  return ReaderKey.fromParts({
    'n': numbers[0],
    'e': numbers[1],
    'd': numbers[2],
    'p': numbers[3],
    'q': numbers[4],
  });
}

/// Reads DER values one after another: just enough for the key file above.
class _Der {
  _Der(this._bytes);

  final Uint8List _bytes;
  int _at = 0;

  /// The contents of the next value, whatever its tag.
  Uint8List next() {
    _at++; // the tag
    var length = _bytes[_at++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | _bytes[_at++];
      }
    }
    final value = Uint8List.sublistView(_bytes, _at, _at + length);
    _at += length;
    return value;
  }
}

/// Encrypts [pdf] the way the server stores it, so tests can make files of
/// any shape. Returns the whole stored file: header, then every chunk.
Future<Uint8List> encryptLikeTheServer(
  Uint8List pdf, {
  required Uint8List fileKey,
  required int chunkSize,
}) async {
  final header = Uint8List.fromList([
    ...'NPENC1\n'.codeUnits, 0, // the format's mark
    (chunkSize >> 24) & 0xff, (chunkSize >> 16) & 0xff, (chunkSize >> 8) & 0xff, chunkSize & 0xff,
    ...List.filled(16, 7), // the salt: only the server uses it
  ]);
  final total = pdf.isEmpty ? 1 : (pdf.length + chunkSize - 1) ~/ chunkSize;
  final layout = FileLayout(
    version: 'test',
    fileSize: pdf.length,
    chunkSize: chunkSize,
    totalChunks: total,
    header: header,
  );
  final aes = AesGcm.with256bits();
  final out = BytesBuilder()..add(header);
  for (var index = 0; index < total; index++) {
    final start = index * chunkSize;
    final box = await aes.encrypt(
      Uint8List.sublistView(pdf, start, start + layout.plainLength(index)),
      secretKey: SecretKey(fileKey),
      nonce: layout.nonce(index),
      aad: header,
    );
    out
      ..add(box.cipherText)
      ..add(box.mac.bytes);
  }
  return out.toBytes();
}

/// Answers chunk requests from a stored file in memory, with the server's
/// rules: at most 4 runs and 4 MB a request, chunks in the order asked.
class FakeChunkServer {
  FakeChunkServer(this.layout, this.stored);

  final FileLayout layout;
  final Uint8List stored;

  /// The `chunks` value of every request so far.
  final requests = <String>[];

  /// Called before each answer; a test makes requests fail by throwing here.
  void Function(String chunks)? beforeAnswer;

  /// Changes the answer's bytes; a test damages an answer with this.
  Uint8List Function(Uint8List answer)? tamper;

  Future<Uint8List> fetch(String chunks) async {
    requests.add(chunks);
    await Future<void>.delayed(Duration.zero); // answers are never instant
    beforeAnswer?.call(chunks);
    final runs = chunks.split(',');
    if (runs.length > maxRunsPerRequest) {
      throw StateError('The server takes $maxRunsPerRequest runs, not ${runs.length}.');
    }
    final indexes = <int>[];
    for (final run in runs) {
      final ends = run.split('-').map(int.parse).toList();
      for (var index = ends.first; index <= ends.last; index++) {
        if (index >= layout.totalChunks) throw StateError('No chunk $index.');
        indexes.add(index);
      }
    }
    if (indexes.length > layout.maxChunksPerRequest) {
      throw StateError('The server sends ${layout.maxChunksPerRequest} chunks at most.');
    }
    final answer = BytesBuilder();
    for (final index in indexes) {
      final start = layout.storedOffset(index);
      answer.add(Uint8List.sublistView(stored, start, start + layout.storedLength(index)));
    }
    final bytes = answer.toBytes();
    return tamper == null ? bytes : tamper!(bytes);
  }
}
