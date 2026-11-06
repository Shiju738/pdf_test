import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/reader_key.dart';

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
