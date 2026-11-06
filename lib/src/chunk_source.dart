import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'chunk_cipher.dart';
import 'file_layout.dart';

/// Gets stored (still encrypted) chunks: [chunks] is the `chunks` value of a
/// request, such as `0-1,22`, and the answer is those chunks one after
/// another. Online this is a call to the chunks endpoint; for a downloaded
/// file it would read the same bytes from disk.
typedef ChunkFetcher = Future<Uint8List> Function(String chunks);

/// Tells a failure that may pass (the network dropped, the server is busy)
/// from one that won't (the server refused).
typedef TemporaryTest = bool Function(Object error);

/// Feeds a PDF viewer from the encrypted chunks of one file.
///
/// The viewer asks for bytes of the PDF with [read]. This works out which
/// chunks hold them, fetches the ones it doesn't have, decrypts them, keeps
/// them in memory, and copies the bytes out. PDFium asks in tiny pieces, so
/// almost every read is answered from the cache.
///
/// ## When a request fails
///
/// A failed read is dangerous, not just unhelpful. pdfrx 2.4 carries on
/// loading the next pages after one page failed to load, and PDFium can then
/// abort the whole app. So this class does everything it can not to fail a
/// read while the viewer is open:
///
/// - Trouble that may pass (no network, a timeout, a busy server) is waited
///   out: the request is repeated, with growing pauses, for as long as the
///   viewer is open. [waitingFor] says what it is waiting for.
/// - A refusal from the server, or answers that keep arriving damaged, can't
///   be waited out. The source then stops for good: [failure] is set, no
///   further request is sent, and the screen must close the viewer.
/// - A read that does fail takes [failedReadDelay] to say so. That is longer
///   than the time pdfrx gives one round of page loading, so the round ends
///   after that page instead of failing page after page.
///
/// ## Closing
///
/// When the screen goes away it calls [leave], not [dispose]: PDFium may be
/// in the middle of loading a page, and must be given the bytes it asks for
/// until pdfrx has closed the document. pdfrx reports that through
/// `PdfDocumentRefCustom.onDispose`, which is where [dispose] belongs.
class ChunkSource extends ChangeNotifier {
  ChunkSource({
    required this.layout,
    required ChunkFetcher fetch,
    required ChunkCipher cipher,
    this.maxCachedChunks = 128,
    this.firstRetryDelay = const Duration(milliseconds: 400),
    this.maxRetryDelay = const Duration(seconds: 5),
    this.failedReadDelay = const Duration(milliseconds: 300),
    this.leavingGrace = const Duration(seconds: 2),
    this.maxDamagedAnswers = 3,
    TemporaryTest? isTemporary,
  }) : _fetch = fetch,
       _cipher = cipher,
       _isTemporary = isTemporary ?? ((_) => true) {
    // Fails any read still waiting [leavingGrace] after [leave].
    _gone = _left.future
        .then((_) => Future<void>.delayed(leavingGrace))
        .then<Never>((_) => throw StateError('The reader is closing.'))
      ..ignore();
  }

  final FileLayout layout;

  /// Decrypted chunks kept in memory: 128 chunks of 256 KB is 32 MB. The
  /// first and last chunk are never dropped, because every open needs them.
  final int maxCachedChunks;

  /// The pause before a request is repeated: it doubles each time, up to
  /// [maxRetryDelay].
  final Duration firstRetryDelay;
  final Duration maxRetryDelay;

  /// How long a failed read takes to fail. See the class notes.
  final Duration failedReadDelay;

  /// After [leave], how long a read may still wait for its chunks.
  final Duration leavingGrace;

  /// How many answers in a row may fail to decrypt before the source gives up
  /// on the file.
  final int maxDamagedAnswers;

  final ChunkFetcher _fetch;
  final ChunkCipher _cipher;
  final TemporaryTest _isTemporary;

  // In the order last used, least recent first.
  final _cache = <int, Uint8List>{};
  final _loading = <int, Future<Uint8List>>{};
  final _left = Completer<void>();
  late final Future<Never> _gone;
  bool _closed = false;

  /// Set once the file can't be read any more: the server refused (the file
  /// changed, access ended) or its answers keep arriving damaged. Every read
  /// fails from then on, and the screen must close the viewer.
  Object? failure;

  /// The trouble a request is being repeated for right now, or null. Reads
  /// wait meanwhile.
  Object? waitingFor;

  /// Why the last failed [read] failed.
  Object? lastError;

  // ── What happened so far, for the screen ────────────────────────────────

  /// Chunk requests sent, counting repeats.
  int requests = 0;

  /// Encrypted bytes received.
  int bytesDownloaded = 0;

  /// Time spent waiting for the network, and decrypting.
  Duration fetchTime = Duration.zero;
  Duration decryptTime = Duration.zero;

  /// Read calls from the viewer that were answered, and the bytes they got.
  int reads = 0;
  int bytesRead = 0;

  /// Every chunk fetched so far, including ones the cache dropped since.
  final loadedChunks = SplayTreeSet<int>();

  /// How much of the PDF has been fetched, in bytes.
  int get plainBytesLoaded =>
      loadedChunks.fold(0, (sum, index) => sum + layout.plainLength(index));

  // ── Reading ─────────────────────────────────────────────────────────────

  /// Fetches the first and the last chunk in one request. Every PDF open
  /// reads both, so doing it up front saves a round trip.
  Future<void> prefetchEnds() => _chunks({0, layout.lastChunk});

  /// The viewer's read function: copies the PDF's bytes [position] to
  /// `position + size - 1` into [buffer].
  ///
  /// Returns [size], or 0 when the bytes can't be delivered. It never throws:
  /// pdfrx hands a thrown error to PDFium as -1, which PDFium takes for a
  /// successful read.
  Future<int> read(Uint8List buffer, int position, int size) async {
    try {
      _check();
      if (position < 0 || size <= 0 || position + size > layout.fileSize) {
        throw RangeError('Bytes $position+$size are outside the file.');
      }
      final first = position ~/ layout.chunkSize;
      final last = (position + size - 1) ~/ layout.chunkSize;
      final wanted = {for (var n = first; n <= last; n++) n};
      // What is in the cache is given out whatever else is going on. Only a
      // read that has to wait for a request can be cut short by [leave].
      final chunks = wanted.every(_cache.containsKey)
          ? {for (final n in wanted) n: _cached(n)! as Uint8List}
          : await Future.any([_chunks(wanted), _gone]);
      var written = 0;
      for (var n = first; n <= last; n++) {
        final chunk = chunks[n]!;
        final from = n == first ? position - n * layout.chunkSize : 0;
        final to = min(chunk.length, position + size - n * layout.chunkSize);
        buffer.setRange(written, written + to - from, chunk, from);
        written += to - from;
      }
      if (written != size) throw StateError('Only $written of $size bytes.');
      reads++;
      bytesRead += size;
      return size;
    } catch (error) {
      lastError = error;
      _changed();
      await Future<void>.delayed(failedReadDelay);
      return 0;
    }
  }

  void _check() {
    if (_closed) throw StateError('The reader was closed.');
    final failure = this.failure;
    if (failure != null) throw failure;
  }

  /// The decrypted chunks [indexes], from the cache or fetched now.
  Future<Map<int, Uint8List>> _chunks(Set<int> indexes) async {
    final missing = [
      for (final index in indexes)
        if (!_cache.containsKey(index) && !_loading.containsKey(index)) index,
    ];
    if (missing.isNotEmpty) _load(missing);
    // Taken before the first await: the cache may drop a chunk meanwhile.
    final waiting = {
      for (final index in indexes)
        index: _cached(index) ?? _loading[index]!,
    };
    return {
      for (final entry in waiting.entries) entry.key: await entry.value,
    };
  }

  FutureOr<Uint8List>? _cached(int index) {
    final chunk = _cache.remove(index);
    if (chunk != null) _cache[index] = chunk; // now the most recently used
    return chunk;
  }

  /// Starts fetching [indexes]. Each gets a future in [_loading], so a second
  /// read that needs the same chunk waits for this fetch instead of sending
  /// its own.
  void _load(List<int> indexes) {
    final done = {for (final index in indexes) index: Completer<Uint8List>()};
    for (final entry in done.entries) {
      // A failure nobody is waiting for must not count as unhandled.
      _loading[entry.key] = entry.value.future..ignore();
    }
    () async {
      try {
        for (final batch in planRequests(
          indexes,
          maxChunks: layout.maxChunksPerRequest,
        )) {
          final chunks = await _fetchAndDecrypt(batch);
          for (var i = 0; i < batch.length; i++) {
            _keep(batch[i], chunks[i]);
            _loading.remove(batch[i]);
            done[batch[i]]!.complete(chunks[i]);
          }
          _changed();
        }
      } catch (error, stack) {
        for (final entry in done.entries) {
          _loading.remove(entry.key);
          if (!entry.value.isCompleted) entry.value.completeError(error, stack);
        }
      }
    }();
  }

  /// One request: fetch, split, decrypt, repeated until it works. It gives up
  /// only when the server refuses, when [maxDamagedAnswers] answers in a row
  /// don't decrypt, or when the screen has gone ([leave]).
  Future<List<Uint8List>> _fetchAndDecrypt(List<int> batch) async {
    var pause = firstRetryDelay;
    var damaged = 0;
    for (;;) {
      _check();
      final clock = Stopwatch()..start();
      final Uint8List body;
      try {
        requests++;
        body = await _fetch(chunksSpec(batch));
      } catch (error) {
        if (!_isTemporary(error)) {
          _fail(error);
          rethrow;
        }
        if (_left.isCompleted) rethrow;
        _waitFor(error);
        await Future.any([Future<void>.delayed(pause), _left.future]);
        pause = pause * 2 > maxRetryDelay ? maxRetryDelay : pause * 2;
        continue;
      }
      fetchTime += clock.elapsed;
      bytesDownloaded += body.length;
      try {
        final stored = layout.split(batch, body);
        clock.reset();
        final plain = await _cipher.decrypt(batch, stored);
        decryptTime += clock.elapsed;
        _waitFor(null);
        return plain;
      } catch (error) {
        // The answer has the wrong length or doesn't decrypt: it was damaged
        // on the way, or it isn't this file at all.
        if (_closed || _left.isCompleted) rethrow;
        if (++damaged >= maxDamagedAnswers) {
          _fail(error);
          rethrow;
        }
        _waitFor(error);
      }
    }
  }

  void _waitFor(Object? trouble) {
    if (identical(waitingFor, trouble)) return;
    waitingFor = trouble;
    _changed();
  }

  void _fail(Object error) {
    failure ??= error;
    waitingFor = null;
    _changed();
  }

  void _keep(int index, Uint8List chunk) {
    loadedChunks.add(index);
    if (_closed) return;
    _cache[index] = chunk;
    while (_cache.length > maxCachedChunks) {
      final oldest = _cache.keys.firstWhere(
        (index) => index != 0 && index != layout.lastChunk,
        orElse: () => -1,
      );
      if (oldest < 0) break;
      _cache.remove(oldest);
    }
  }

  void _changed() {
    if (!_closed) notifyListeners();
  }

  // ── Closing ─────────────────────────────────────────────────────────────

  /// The screen is going away. Reads are still answered, because PDFium may
  /// be in the middle of a page, but nothing is waited out any more: a request
  /// that fails now fails its read, and no read waits longer than
  /// [leavingGrace].
  void leave() {
    if (!_left.isCompleted) _left.complete();
  }

  /// Forgets the decrypted chunks and the file key. Call it when pdfrx has
  /// closed the document (`onDispose`), or when no document was ever opened.
  @override
  void dispose() {
    if (_closed) return;
    leave();
    _closed = true;
    _cache.clear();
    _cipher.dispose();
    super.dispose();
  }
}
