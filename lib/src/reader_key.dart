/// The phone's RSA key pair ("reader key").
///
/// The private key never leaves the phone. The server gets the public key and
/// uses it to wrap the key of each file this phone may read.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

import 'der.dart';

class ReaderKey {
  ReaderKey._(this._privateKey, this.publicExponent);

  /// How this app unwraps: RSA-OAEP with SHA-256 for both OAEP and MGF1. The
  /// server is told this name with the public key and wraps to match.
  static const algorithm = 'RSA-OAEP-SHA256';

  /// What a key held inside Android's own keystore would need. This app keeps
  /// its key in Dart, so it only unwraps this variant in tests.
  static const androidKeystoreAlgorithm = 'RSA-OAEP-SHA256-MGF1-SHA1';

  static const bits = 2048;

  final RSAPrivateKey _privateKey;
  final BigInt publicExponent;

  BigInt get modulus => _privateKey.modulus!;

  /// Makes a new key pair. This takes a moment in Dart, so it runs in a
  /// background isolate and the screen stays responsive.
  static Future<ReaderKey> generate() async =>
      ReaderKey.fromParts(await Isolate.run(_generateParts));

  static Map<String, String> _generateParts() {
    final secure = Random.secure();
    final seed = Uint8List.fromList(List.generate(32, (_) => secure.nextInt(256)));
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
          FortunaRandom()..seed(KeyParameter(seed)),
        ),
      );
    final private = generator.generateKeyPair().privateKey as RSAPrivateKey;
    return {
      'n': private.modulus!.toRadixString(16),
      'e': BigInt.from(65537).toRadixString(16),
      'd': private.privateExponent!.toRadixString(16),
      'p': private.p!.toRadixString(16),
      'q': private.q!.toRadixString(16),
    };
  }

  /// From the hex numbers `n`, `e`, `d`, `p`, `q`.
  factory ReaderKey.fromParts(Map<String, dynamic> parts) {
    BigInt number(String name) => BigInt.parse(parts[name] as String, radix: 16);
    return ReaderKey._(
      RSAPrivateKey(number('n'), number('d'), number('p'), number('q')),
      number('e'),
    );
  }

  /// The whole key pair as text, for secure storage only.
  String toSecret() => jsonEncode({
    'n': modulus.toRadixString(16),
    'e': publicExponent.toRadixString(16),
    'd': _privateKey.privateExponent!.toRadixString(16),
    'p': _privateKey.p!.toRadixString(16),
    'q': _privateKey.q!.toRadixString(16),
  });

  factory ReaderKey.fromSecret(String secret) =>
      ReaderKey.fromParts(jsonDecode(secret) as Map<String, dynamic>);

  /// The public key as DER (SubjectPublicKeyInfo).
  Uint8List get publicKeyDer => rsaPublicKeySpki(modulus, publicExponent);

  /// What is sent to the server as `public_key`.
  String get publicKeyBase64 => base64Encode(publicKeyDer);

  /// SHA-256 of the public key, in hex. The server calls the same value the
  /// key's fingerprint.
  String get fingerprint => SHA256Digest()
      .process(publicKeyDer)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  /// The file key inside [wrapped], which the server made with this pair's
  /// public key. [algorithm] is the `key_algorithm` that came with it.
  ///
  /// Throws when [wrapped] wasn't made for this key pair or [algorithm] isn't
  /// one this app can unwrap.
  Uint8List unwrap(Uint8List wrapped, {required String algorithm}) {
    if (algorithm != ReaderKey.algorithm && algorithm != androidKeystoreAlgorithm) {
      throw ArgumentError.value(algorithm, 'algorithm', 'Unknown key wrap');
    }
    final oaep = OAEPEncoding.withSHA256(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(_privateKey));
    // After init, which sets MGF1 back to the OAEP hash.
    if (algorithm == androidKeystoreAlgorithm) oaep.mgf1Hash = SHA1Digest();
    final fileKey = oaep.process(wrapped);
    if (fileKey.length != 32) {
      throw StateError('The unwrapped key is ${fileKey.length} bytes, not 32.');
    }
    return fileKey;
  }

  /// [unwrap] in a background isolate: the RSA step is slow in Dart.
  Future<Uint8List> unwrapInBackground(
    Uint8List wrapped, {
    required String algorithm,
  }) => Isolate.run(() => unwrap(wrapped, algorithm: algorithm));
}

/// Keeps the key pair in the phone's secure storage: the Keychain on iOS, and
/// preferences encrypted with a Keystore key on Android.
class ReaderKeyStore {
  ReaderKeyStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  static const _name = 'reader_key_v1';

  final FlutterSecureStorage _storage;

  /// The stored key pair, or null when there is none or it can't be read.
  Future<ReaderKey?> load() async {
    try {
      final secret = await _storage.read(key: _name);
      return secret == null ? null : ReaderKey.fromSecret(secret);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(ReaderKey key) =>
      _storage.write(key: _name, value: key.toSecret());

  Future<void> delete() => _storage.delete(key: _name);
}
