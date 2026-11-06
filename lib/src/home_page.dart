import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'chunk_cipher.dart';
import 'chunk_source.dart';
import 'format.dart';
import 'reader_api.dart';
import 'reader_key.dart';
import 'reader_page.dart';

// For automated runs: `--dart-define=ACCESS_URL=...` fills the URL field,
// `--dart-define=AUTO_OPEN=true` opens it as soon as the key pair is ready,
// and `--dart-define=LOAD_ALL_PAGES=true` starts with that switch on.
const _definedUrl = String.fromEnvironment('ACCESS_URL');
const _autoOpen = bool.fromEnvironment('AUTO_OPEN');
const _loadAllPagesAtStart = bool.fromEnvironment('LOAD_ALL_PAGES');

const _lastUrlName = 'last_access_url';

/// The first screen: the device's key pair, the access URL, and a log of
/// each step up to the moment the PDF opens.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _keyStore = ReaderKeyStore();
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final _api = ReaderApi();
  final _url = TextEditingController();
  final _steps = <String>[];

  ReaderKey? _key;
  String _keyStatus = 'Looking for a stored key pair…';
  bool _busy = false;
  bool _loadAllPages = _loadAllPagesAtStart;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _url.dispose();
    _api.close();
    super.dispose();
  }

  Future<void> _start() async {
    _url.text = _definedUrl.isNotEmpty
        ? _definedUrl
        : await _readLastUrl() ?? _defaultUrl;
    await _prepareKey();
    if (_autoOpen && mounted) await _open();
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

  /// Loads the key pair from secure storage, or makes and stores one.
  Future<void> _prepareKey({bool makeNew = false}) async {
    setState(() {
      _key = null;
      _keyStatus =
          makeNew ? 'Making a new key pair…' : 'Looking for a stored key pair…';
    });
    try {
      var key = makeNew ? null : await _keyStore.load();
      final stored = key != null;
      if (key == null) {
        if (mounted) setState(() => _keyStatus = 'Making an RSA key pair…');
        final clock = Stopwatch()..start();
        key = await ReaderKey.generate();
        await _keyStore.save(key);
        _keyStatus = 'New RSA-${ReaderKey.bits} key pair made in '
            '${clock.elapsedMilliseconds} ms. The private key is in secure storage.';
      } else {
        _keyStatus =
            'RSA-${ReaderKey.bits} key pair loaded from secure storage.';
      }
      if (!mounted) return;
      setState(() => _key = key);
      _step(stored ? 'Key pair loaded.' : 'Key pair made and stored.');
    } catch (error) {
      if (mounted)
        setState(() => _keyStatus = 'Could not prepare a key pair: $error');
    }
  }

  void _step(String text) {
    if (mounted) setState(() => _steps.add(text));
  }

  /// The whole flow: send the public key, unwrap the file key, fetch the
  /// first chunks, then show the PDF.
  Future<void> _open() async {
    final key = _key;
    final url = Uri.tryParse(_url.text.trim());
    if (key == null || _busy) return;
    if (url == null ||
        !(url.isScheme('http') || url.isScheme('https')) ||
        url.host.isEmpty) {
      _step(
          'That is not a web address. It must start with http:// or https://');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _steps.clear();
    });
    final sinceOpen = Stopwatch()..start();
    ChunkSource? source;
    try {
      _step('Sending the public key to the server…');
      final access = await _api.requestAccess(
        url,
        publicKey: key.publicKeyBase64,
        algorithm: ReaderKey.algorithm,
      );
      final layout = access.layout;
      _step(
        'Received the wrapped key (${access.wrappedKey.length} bytes, '
        '${access.keyAlgorithm}) and the file: ${megabytes(layout.fileSize)} in '
        '${layout.totalChunks} chunks of ${kilobytes(layout.chunkSize)}.',
      );
      _step('Streaming URL: ${access.streamUrl}');

      final fileKey = await key.unwrapInBackground(
        access.wrappedKey,
        algorithm: access.keyAlgorithm,
      );
      _step(
          'Unwrapped the file key with the private key: ${fileKey.length} bytes.');

      final cipher = ChunkCipher(layout: layout, fileKey: fileKey);
      fileKey.fillRange(0, fileKey.length, 0); // the cipher holds its own copy
      final streamUrl = access.streamUrl;
      final api = _api;
      source = ChunkSource(
        layout: layout,
        cipher: cipher,
        fetch: (chunks) => api.fetchChunks(streamUrl, chunks),
        isTemporary: ReaderApi.isTemporary,
      );
      // The source waits out network trouble for as long as it takes; this
      // first request is given 40 seconds, so a dead server shows up here.
      await source.prefetchEnds().timeout(const Duration(seconds: 40));
      _step(
        'Fetched and decrypted the first and last chunk: '
        '${kilobytes(source.bytesDownloaded)} in ${sinceOpen.elapsedMilliseconds} ms '
        'since Open.',
      );
      try {
        await _storage.write(key: _lastUrlName, value: url.toString());
      } catch (_) {
        // Remembering the URL is only a convenience.
      }
      if (!mounted) {
        source.dispose();
        return;
      }
      final opened = source;
      source = null; // the reader screen owns it from here
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            access: access,
            source: opened,
            sinceOpen: sinceOpen,
            loadAllPages: _loadAllPages,
          ),
        ),
      );
    } catch (error) {
      source?.dispose();
      _step('Failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = _key;
    return Scaffold(
      appBar: AppBar(title: const Text('Secure PDF reader test')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('1. This device\'s key pair',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(_keyStatus, key: const Key('keyStatus')),
          if (key != null) ...[
            const SizedBox(height: 8),
            Text('Fingerprint: ${key.fingerprint.substring(0, 16)}…'),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Public key: ${key.publicKeyBase64}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy the public key',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: key.publicKeyBase64),
                  ),
                ),
              ],
            ),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed:
                  _busy || (key == null && !_keyStatus.startsWith('Could not'))
                      ? null
                      : () => _prepareKey(makeNew: true),
              child: const Text('Make a new key pair'),
            ),
          ),
          const Divider(height: 32),
          Text('2. PDF access URL', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            key: const Key('accessUrl'),
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'http://…/api/v1/reader-test/access/',
            ),
          ),
          SwitchListTile(
            key: const Key('loadAllPages'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Load the other pages in the background'),
            subtitle: Text(
              _loadAllPages
                  ? 'What pdfrx does by default: the whole file arrives within seconds.'
                  : 'Off: a page is fetched only when it is shown.',
            ),
            value: _loadAllPages,
            onChanged:
                _busy ? null : (value) => setState(() => _loadAllPages = value),
          ),
          const SizedBox(height: 4),
          FilledButton.icon(
            key: const Key('openPdf'),
            onPressed: key == null || _busy ? null : _open,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.lock_open),
            label: Text(_busy ? 'Opening…' : 'Open PDF'),
          ),
          const Divider(height: 32),
          Text('Steps', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final (index, step) in _steps.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${index + 1}. $step',
                style: step.startsWith('Failed')
                    ? TextStyle(color: theme.colorScheme.error)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}
