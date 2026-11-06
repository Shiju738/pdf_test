import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:secure_pdf_reader_test/app/bindings/initial_binding.dart';
import 'package:secure_pdf_reader_test/data/services/reader_api.dart';
import 'package:secure_pdf_reader_test/data/services/reader_key_store.dart';

void main() {
  test('registers the app-wide services', () {
    InitialBinding.dependencies();
    expect(Get.isRegistered<FlutterSecureStorage>(), isTrue);
    expect(Get.isRegistered<ReaderKeyStore>(), isTrue);
    expect(Get.isRegistered<ReaderApi>(), isTrue);
  });
}
