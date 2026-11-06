import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'file_layout.dart';

/// Decrypts the chunks of one file.
///
/// Each chunk is AES-256-GCM on its own: the key is the file key, the nonce
/// comes from the chunk's number, and the file's 28-byte header is the
/// additional data. A chunk that was changed, or is decrypted under another
/// number, fails and gives no bytes.
class ChunkCipher {
  ChunkCipher({
    required this.layout,
    required Uint8List fileKey,
    this.inBackground = true,
  }) : _fileKey = Uint8List.fromList(fileKey) {
    if (fileKey.length != 32) {
      throw ArgumentError('The file key must be 32 bytes.');
    }
  }

  final FileLayout layout;

  /// Decrypt in a background isolate, so the screen doesn't stutter while a
  /// chunk is opened. Tests turn this off.
  final bool inBackground;

  Uint8List? _fileKey;

  /// The PDF bytes of the chunks [indexes], given their stored bytes (each one
  /// its encrypted bytes followed by the 16-byte tag), in the same order.
  ///
  /// Throws [SecretBoxAuthenticationError] if any chunk doesn't open.
  Future<List<Uint8List>> decrypt(List<int> indexes, List<Uint8List> stored) {
    final key = _fileKey;
    if (key == null) throw StateError('The file key was dropped.');
    final nonces = [for (final index in indexes) layout.nonce(index)];
    final header = layout.header;
    if (!inBackground) return _decryptAll(key, header, nonces, stored);
    // Copies, so the closure sends only bytes to the other isolate.
    final chunks = [for (final chunk in stored) Uint8List.fromList(chunk)];
    return Isolate.run(() => _decryptAll(key, header, nonces, chunks));
  }

  /// Forget the key. The cipher can't be used afterwards.
  void dispose() {
    _fileKey?.fillRange(0, 32, 0);
    _fileKey = null;
  }
}

Future<List<Uint8List>> _decryptAll(
  Uint8List fileKey,
  Uint8List header,
  List<Uint8List> nonces,
  List<Uint8List> stored,
) async {
  final aes = AesGcm.with256bits();
  final secretKey = SecretKey(fileKey);
  final plain = <Uint8List>[];
  for (var i = 0; i < stored.length; i++) {
    final chunk = stored[i];
    final box = SecretBox(
      Uint8List.sublistView(chunk, 0, chunk.length - tagSize),
      nonce: nonces[i],
      mac: Mac(Uint8List.sublistView(chunk, chunk.length - tagSize)),
    );
    final bytes = await aes.decrypt(box, secretKey: secretKey, aad: header);
    plain.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  }
  return plain;
}
