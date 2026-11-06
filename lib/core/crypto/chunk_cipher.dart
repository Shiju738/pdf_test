import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';

import '../../data/models/file_layout.dart';

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
    AesGcm? nativeAes,
  }) : _fileKey = Uint8List.fromList(fileKey),
       _nativeAes = nativeAes ?? platformAes {
    if (fileKey.length != 32) {
      throw ArgumentError('The file key must be 32 bytes.');
    }
  }

  final FileLayout layout;

  /// Decrypt in a background isolate, so the screen doesn't stutter while a
  /// chunk is opened. Tests turn this off.
  final bool inBackground;

  Uint8List? _fileKey;

  /// The operating system's AES-GCM (CryptoKit on iOS, javax.crypto on
  /// Android), or null where there is none (tests, desktop). It is hardware
  /// accelerated: a 256 KB chunk takes well under a millisecond, where the
  /// pure-Dart cipher takes tens of milliseconds, more on a phone. Opening a
  /// page far into a book decrypts many chunks in a row, so this is most of
  /// the wait.
  final AesGcm? _nativeAes;

  /// The platform's AES-GCM through the cryptography_flutter plugin, or null
  /// when the plugin isn't there. Only the main isolate has the plugin.
  static AesGcm? get platformAes {
    final aes = FlutterAesGcm.with256bits();
    return aes.isSupportedPlatform ? aes : null;
  }

  /// The PDF bytes of the chunks [indexes], given their stored bytes (each one
  /// its encrypted bytes followed by the 16-byte tag), in the same order.
  ///
  /// Throws [SecretBoxAuthenticationError] if any chunk doesn't open.
  Future<List<Uint8List>> decrypt(List<int> indexes, List<Uint8List> stored) {
    final key = _fileKey;
    if (key == null) throw StateError('The file key was dropped.');
    final nonces = [for (final index in indexes) layout.nonce(index)];
    final header = layout.header;
    final native = _nativeAes;
    // The plugin call is asynchronous: the screen goes on meanwhile.
    if (native != null) return _decryptAll(key, header, nonces, stored, native);
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
  List<Uint8List> stored, [
  AesGcm? cipher,
]) async {
  // In a background isolate this is the pure-Dart AES-GCM.
  final aes = cipher ?? AesGcm.with256bits();
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
