import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/app_routes.dart';
import '../../../core/crypto/chunk_cipher.dart';
import '../../../core/utils/format.dart';
import '../../../data/models/reader_key.dart';
import '../../../data/services/chunk_source.dart';
import '../../../data/services/chunk_store.dart';
import '../../../data/services/reader_api.dart';
import '../../../data/services/reader_key_store.dart';
import '../../reader/reader_args.dart';

// For automated runs: `--dart-define=ACCESS_URL=...` fills the URL field,
// `--dart-define=AUTO_OPEN=true` opens it as soon as the key pair is ready,
// and `--dart-define=LOAD_ALL_PAGES=true` starts with that switch on.
const _definedUrl = String.fromEnvironment('ACCESS_URL');
const _autoOpen = bool.fromEnvironment('AUTO_OPEN');
const _loadAllPagesAtStart = bool.fromEnvironment('LOAD_ALL_PAGES');

const _lastUrlName = 'last_access_url';

/// The first screen: the device's key pair, the access URL, and a log of
/// each step up to the moment the PDF opens.
class HomeController extends GetxController {
  HomeController({
    ReaderKeyStore? keyStore,
    FlutterSecureStorage? storage,
    ReaderApi? api,
    ChunkStore? chunkStore,
  }) : _keyStore = keyStore ?? Get.find<ReaderKeyStore>(),
       _storage = storage ?? Get.find<FlutterSecureStorage>(),
       _api = api ?? Get.find<ReaderApi>(),
       _chunkStore = chunkStore ?? Get.find<ChunkStore>();

  final ReaderKeyStore _keyStore;
  final FlutterSecureStorage _storage;
  final ReaderApi _api;
  final ChunkStore _chunkStore;

  final url = TextEditingController();
  final steps = <String>[].obs;
  final key = Rxn<ReaderKey>();
  final keyStatus = 'Looking for a stored key pair…'.obs;
  final busy = false.obs;
  final loadAllPages = _loadAllPagesAtStart.obs;

  /// Bytes of chunks saved on the device, or null while counting.
  final savedBytes = Rxn<int>();
  final clearingSaved = false.obs;

  bool get keyFailed => keyStatus.value.startsWith('Could not');

  @override
  void onInit() {
    super.onInit();
    _start();
  }

  @override
  void onClose() {
    url.dispose();
    super.onClose();
  }

  Future<void> _start() async {
    url.text = _definedUrl.isNotEmpty
        ? _definedUrl
        : await _readLastUrl() ?? _defaultUrl;
    unawaited(refreshSavedSize());
    await prepareKey();
    if (_autoOpen && !isClosed) await open();
  }

  /// The Android emulator reaches the computer it runs on at 10.0.2.2.
  String get _defaultUrl => Platform.isAndroid
      ? 'http://10.0.2.2:8000/api/v1/reader-test/access/'
      : 'http://127.0.0.1:8000/api/v1/reader-test/access/';

  Future<String?> _readLastUrl() async {
    try {
      return await _storage.read(key: _lastUrlName);
    } catch (_) {
      return null;
    }
  }

  /// Counts the chunks saved on the device.
  Future<void> refreshSavedSize() async {
    try {
      final bytes = await _chunkStore.size();
      if (!isClosed) savedBytes.value = bytes;
    } catch (_) {
      if (!isClosed) savedBytes.value = 0;
    }
  }

  /// Deletes every chunk saved on the device: the next open downloads again.
  Future<void> clearSaved() async {
    if (busy.value || clearingSaved.value) return;
    clearingSaved.value = true;
    try {
      await _chunkStore.clear();
      _step('Deleted the chunks saved on this device.');
    } catch (error) {
      _step('Failed to delete the saved chunks: $error');
    } finally {
      if (!isClosed) clearingSaved.value = false;
      await refreshSavedSize();
    }
  }

  void setLoadAllPages(bool value) => loadAllPages.value = value;

  /// Loads the key pair from secure storage, or makes and stores one.
  Future<void> prepareKey({bool makeNew = false}) async {
    key.value = null;
    keyStatus.value =
        makeNew ? 'Making a new key pair…' : 'Looking for a stored key pair…';
    try {
      var found = makeNew ? null : await _keyStore.load();
      final stored = found != null;
      if (found == null) {
        keyStatus.value = 'Making an RSA key pair…';
        final clock = Stopwatch()..start();
        found = await ReaderKey.generate();
        await _keyStore.save(found);
        keyStatus.value = 'New RSA-${ReaderKey.bits} key pair made in '
            '${clock.elapsedMilliseconds} ms. The private key is in secure storage.';
      } else {
        keyStatus.value =
            'RSA-${ReaderKey.bits} key pair loaded from secure storage.';
      }
      if (isClosed) return;
      key.value = found;
      _step(stored ? 'Key pair loaded.' : 'Key pair made and stored.');
    } catch (error) {
      if (!isClosed) keyStatus.value = 'Could not prepare a key pair: $error';
    }
  }

  void _step(String text) {
    if (!isClosed) steps.add(text);
  }

  /// The whole flow: send the public key, unwrap the file key, fetch the
  /// first chunks, then show the PDF.
  Future<void> open() async {
    final readerKey = key.value;
    final accessUrl = Uri.tryParse(url.text.trim());
    if (readerKey == null || busy.value) return;
    if (accessUrl == null ||
        !(accessUrl.isScheme('http') || accessUrl.isScheme('https')) ||
        accessUrl.host.isEmpty) {
      _step(
          'That is not a web address. It must start with http:// or https://');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    busy.value = true;
    steps.clear();
    final sinceOpen = Stopwatch()..start();
    ChunkSource? source;
    try {
      _step('Sending the public key to the server…');
      final access = await _api.requestAccess(
        accessUrl,
        publicKey: readerKey.publicKeyBase64,
        algorithm: ReaderKey.algorithm,
      );
      final layout = access.layout;
      _step(
        'Received the wrapped key (${access.wrappedKey.length} bytes, '
        '${access.keyAlgorithm}) and the file: ${megabytes(layout.fileSize)} in '
        '${layout.totalChunks} chunks of ${kilobytes(layout.chunkSize)}.',
      );
      _step('Streaming URL: ${access.streamUrl}');

      final fileKey = await readerKey.unwrapInBackground(
        access.wrappedKey,
        algorithm: access.keyAlgorithm,
      );
      _step(
          'Unwrapped the file key with the private key: ${fileKey.length} bytes.');

      final cipher = ChunkCipher(layout: layout, fileKey: fileKey);
      fileKey.fillRange(0, fileKey.length, 0); // the cipher holds its own copy
      final streamUrl = access.streamUrl;
      final api = _api;
      StoredChunks? stored;
      try {
        stored = await _chunkStore.open(streamUrl, layout);
      } catch (_) {
        // No cache folder: everything is fetched, as before.
      }
      source = ChunkSource(
        layout: layout,
        cipher: cipher,
        stored: stored,
        fetch: (chunks, cancelled) =>
            api.fetchChunks(streamUrl, chunks, cancelled: cancelled),
        // The server's page map, when it sends one: jumps then fetch exactly
        // the chunks of the page.
        pageChunks: access.pageChunks,
        isTemporary: ReaderApi.isTemporary,
      );
      // The source waits out network trouble for as long as it takes; this
      // first request is given 40 seconds, so a dead server shows up here.
      await source.prefetchEnds().timeout(const Duration(seconds: 40));
      _step(
        'Got and decrypted the first and last chunk '
        '(${source.chunksFromDevice} from this device, '
        '${kilobytes(source.bytesDownloaded)} downloaded) in '
        '${sinceOpen.elapsedMilliseconds} ms since Open.',
      );
      try {
        await _storage.write(key: _lastUrlName, value: accessUrl.toString());
      } catch (_) {
        // Remembering the URL is only a convenience.
      }
      if (isClosed) {
        source.dispose();
        return;
      }
      final opened = source;
      source = null; // the reader screen owns it from here
      await AppRouter.router.pushNamed<void>(
        AppRoutes.reader,
        extra: ReaderArgs(
          access: access,
          source: opened,
          sinceOpen: sinceOpen,
          loadAllPages: loadAllPages.value,
        ),
      );
    } catch (error) {
      source?.dispose();
      _step('Failed: $error');
    } finally {
      if (!isClosed) busy.value = false;
      unawaited(refreshSavedSize()); // the reader saved chunks meanwhile
    }
  }
}
