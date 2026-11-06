import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';

import '../../core/network/api_service.dart';
import '../../data/services/chunk_store.dart';
import '../../data/services/reader_api.dart';
import '../../data/services/reader_key_store.dart';

/// App-wide services, put once at start-up and kept for the app's life.
/// Screen controllers are not put here: see ControllerScope.
abstract final class InitialBinding {
  /// Safe to call more than once (tests pump the app without main()).
  static void dependencies() {
    if (Get.isRegistered<ReaderApi>()) return;
    Get.put<FlutterSecureStorage>(
      const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      ),
      permanent: true,
    );
    Get.put<ReaderKeyStore>(ReaderKeyStore(Get.find<FlutterSecureStorage>()), permanent: true);
    Get.put<ApiService>(ApiService(), permanent: true);
    Get.put<ReaderApi>(ReaderApi(Get.find<ApiService>()), permanent: true);
    Get.put<ChunkStore>(ChunkStore(), permanent: true);
  }
}
