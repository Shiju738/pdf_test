import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/crypto/chunk_cipher.dart';
import '../models/file_layout.dart';
import 'chunk_store.dart';

/// Gets stored (still encrypted) chunks: [chunks] is the `chunks` value of a
/// request, such as `0-1,22`, and the answer is those chunks one after
/// another. Online this is a call to the chunks endpoint; for a downloaded
/// file it would read the same bytes from disk.
///
/// [cancelled] completes when the answer isn't wanted any more (the user
/// jumped elsewhere): the fetcher may then abort the request and throw.
typedef ChunkFetcher =
    Future<Uint8List> Function(String chunks, Future<void> cancelled);

/// How urgent a chunk request is. The lower the level, the sooner it is sent.
enum ChunkPriority {
  /// 1: PDFium is waiting for this chunk right now, and can draw nothing else
  /// meanwhile. Sent at once, whatever else is going on.
  needed(1, 'needed now'),

  /// 2: chunks of the page the user just jumped to.
  jump(2, 'jump target'),

  /// 3: read-ahead, chunks that will probably be needed soon. Sent only when
  /// nothing more urgent is waiting, and dropped when the user jumps.
  ahead(3, 'read-ahead');

  const ChunkPriority(this.level, this.label);

  final int level;
  final String label;

  bool isMoreUrgentThan(ChunkPriority other) => level < other.level;
}

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
    this.stored,
    this.maxCachedChunks = 128,
    this.firstRetryDelay = const Duration(milliseconds: 400),
    this.maxRetryDelay = const Duration(seconds: 5),
    this.failedReadDelay = const Duration(milliseconds: 300),
    this.leavingGrace = const Duration(seconds: 2),
    this.maxDamagedAnswers = 3,
    this.maxReadAhead = 8,
    this.readAheadPiece = 2,
    this.maxJumpAhead = 16,
    this.maxInFlight = 3,
    this.pageChunks,
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

  /// Chunks kept on the device from an earlier open, still encrypted. A chunk
  /// found there is decrypted instead of fetched, and every chunk fetched is
  /// added to it. Null: nothing is kept.
  final StoredChunks? stored;

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

  /// At most this many requests at once at levels 2 and 3. Over a slow link,
  /// requests sent together share its speed: fewer at once means the most
  /// urgent one arrives sooner. Level 1 doesn't wait for this.
  final int maxInFlight;

  /// The chunks each page needs, from the server (`page_chunks`), or null.
  /// When there, a jump fetches exactly these; otherwise it guesses.
  final Map<int, List<int>>? pageChunks;

  /// Prints each request (sent, raised, dropped, cancelled) with its level,
  /// in debug builds. A test can turn it off.
  static bool log = kDebugMode;

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

  /// Chunks read from the device ([stored]) instead of the network.
  int chunksFromDevice = 0;

  /// Time spent waiting for the network, and decrypting.
  Duration fetchTime = Duration.zero;
  Duration decryptTime = Duration.zero;

  /// Read calls from the viewer that were answered, and the bytes they got.
  int reads = 0;
  int bytesRead = 0;

  /// Whether chunks are being fetched right now.
  bool get isFetching => _loading.isNotEmpty;

  /// Reads from PDFium waiting for chunks right now. While one waits, PDFium
  /// is stuck on it: nothing else is drawn meanwhile.
  int readsWaiting = 0;

  final _sinceLastRead = Stopwatch()..start();

  /// How long since PDFium last asked for bytes. Together with
  /// [readsWaiting] == 0 it tells that PDFium is done drawing for now.
  Duration get sinceLastRead => _sinceLastRead.elapsed;

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
      _sinceLastRead.reset();
      final Map<int, Uint8List> chunks;
      if (wanted.every(_cache.containsKey)) {
        chunks = {for (final n in wanted) n: _cached(n)! as Uint8List};
      } else {
        readsWaiting++;
        try {
          chunks = await Future.any([_chunks(wanted), _gone]);
        } finally {
          readsWaiting--;
          _sinceLastRead.reset();
        }
      }
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

  /// The decrypted chunks [indexes], from the cache or fetched now. Whoever
  /// calls this waits for them, so they are fetched at level 1.
  Future<Map<int, Uint8List>> _chunks(Set<int> indexes) async {
    final missing = [
      for (final index in indexes)
        if (!_cache.containsKey(index) && !_loading.containsKey(index)) index,
    ]..sort();
    if (missing.isNotEmpty) {
      final (ahead, aheadPriority) = _readAhead(missing);
      _load(missing, ChunkPriority.needed);
      // Requests of their own: the chunks asked for now don't wait for the
      // read-ahead to arrive and be decrypted, and the read-ahead comes in
      // small pieces, nearest first.
      _loadInPieces(ahead, aheadPriority);
    }
    // Taken before the first await: the cache may drop a chunk meanwhile.
    final waiting = {
      for (final index in indexes)
        index: _cached(index) ?? _loading[index]!,
    };
    // Someone waits for these now: a request for them that is still queued
    // at a lower level moves up to level 1, and none of them is cancelled.
    final waitedFor = [for (final index in indexes) if (!_cache.containsKey(index)) index];
    for (final index in waitedFor) {
      _waiters[index] = (_waiters[index] ?? 0) + 1;
      _raise(index, ChunkPriority.needed);
    }
    try {
      return {
        for (final entry in waiting.entries) entry.key: await entry.value,
      };
    } finally {
      for (final index in waitedFor) {
        final left = (_waiters[index] ?? 1) - 1;
        if (left > 0) {
          _waiters[index] = left;
        } else {
          _waiters.remove(index);
        }
      }
    }
  }

  // ── Read-ahead ──────────────────────────────────────────────────────────
  //
  // PDFium reads one object at a time and waits for each. To find a page it
  // walks the page tree, loading every page object before it, and in most
  // PDFs those lie between the pages' contents. So a jump to the middle of a
  // book misses chunk after chunk in order: 1, 2, 3, … each a round trip.
  //
  // When the misses run in order, the chunks after them are asked for too,
  // and the window doubles while the run goes on (like a file system's
  // read-ahead). A lone miss somewhere else starts over, small.

  /// Chunks fetched with a miss when misses run in order: 2, 4, 8 … up to this.
  final int maxReadAhead;

  /// Read-ahead is sent in requests of at most this many chunks. Small pieces
  /// arrive and are decrypted one after another, so the next chunk PDFium
  /// needs is ready first instead of waiting for the whole lot.
  final int readAheadPiece;

  /// On a jump ([prepareJump]), how far a walk may be fetched ahead at once.
  final int maxJumpAhead;

  /// The current read-ahead window, in chunks: 0 until misses run in order.
  int _window = 0;

  /// The last chunk asked for by the latest miss, read-ahead included.
  int _runEnd = -2;

  /// Where the page being jumped to probably is, until the walk reaches it.
  int? _jumpTarget;

  /// The chunks to fetch along with [missing] (sorted), and at what level:
  /// on the way to a jumped-to page they are level 2, otherwise level 3.
  (List<int>, ChunkPriority) _readAhead(List<int> missing) {
    if (maxReadAhead <= 0) return (const [], ChunkPriority.ahead);
    final first = missing.first;
    final last = missing.last;
    // In order: the miss is just past what the run asked for (a chunk or so
    // may be skipped, by an object PDFium didn't need).
    final inOrder = first > _runEnd && first <= _runEnd + 1 + max(1, _window);
    _window = inOrder ? min(maxReadAhead, max(2, _window * 2)) : min(maxReadAhead, 1);
    var until = last + _window;
    var priority = ChunkPriority.ahead;
    final target = _jumpTarget;
    if (target != null) {
      if (last > target) {
        _jumpTarget = null; // the walk got there
      } else if (inOrder) {
        // A second miss in order while a jump is on: PDFium is walking the
        // page tree towards the target. Everything up to it will be read, so
        // ask for all of it now, as part of the jump.
        until = max(until, min(target + 1, last + maxJumpAhead));
        priority = ChunkPriority.jump;
        _jumpTarget = null;
      }
    }
    final extra = [
      // The last chunk is always in the cache already.
      for (var n = last + 1; n <= until && n < layout.lastChunk; n++)
        if (!_cache.containsKey(n) && !_loading.containsKey(n)) n,
    ];
    _runEnd = extra.isEmpty ? last : extra.last;
    return (extra, priority);
  }

  void _loadInPieces(List<int> indexes, ChunkPriority priority) {
    final size = max(1, readAheadPiece);
    for (var i = 0; i < indexes.length; i += size) {
      _load(indexes.sublist(i, min(indexes.length, i + size)), priority);
    }
  }

  /// The chunk where page [page] of [pageCount] probably is, taking the pages
  /// to be spread evenly through the file.
  int chunkOfPage(int page, int pageCount) {
    if (pageCount <= 1 || layout.totalChunks <= 2) return 0;
    final fraction = (page - 0.5) / pageCount;
    return (fraction * layout.totalChunks).floor().clamp(1, layout.lastChunk - 1);
  }

  /// The chunks page [page] needs: from the server's page map when there is
  /// one, otherwise the guess around [chunkOfPage].
  List<int> chunksOfPage(int page, int pageCount) {
    final known = pageChunks?[page];
    if (known != null) {
      return [for (final n in known) if (n >= 0 && n < layout.totalChunks) n]..sort();
    }
    final target = chunkOfPage(page, pageCount);
    if (target <= 0) return const [];
    return [
      for (var n = max(1, target - 1); n <= min(layout.lastChunk - 1, target + 1); n++) n,
    ];
  }

  /// The user is jumping to [page] of [pageCount], far from where the viewer
  /// is (the page slider, or a fast scroll).
  ///
  /// - What was being fetched for an earlier jump, and all read-ahead, gives
  ///   way: queued requests are dropped, and requests on the way are
  ///   cancelled, unless PDFium waits for them (those always finish).
  /// - The chunks of [page] are fetched at level 2, before PDFium asks.
  /// - If PDFium then walks the page tree towards it (misses in order), the
  ///   rest of the way is fetched at once, also at level 2.
  void prepareJump(int page, int pageCount) {
    if (_closed || failure != null || _left.isCompleted || maxReadAhead <= 0) return;
    for (final request in [..._queue, ..._sent]) {
      if (request.priority == ChunkPriority.jump) request.priority = ChunkPriority.ahead;
    }
    _dropReadAhead();
    final chunks = chunksOfPage(page, pageCount);
    if (chunks.isEmpty) return;
    _log('jump to page $page: chunks ${chunks.join(',')} '
        '(${pageChunks?[page] != null ? 'from the page map' : 'estimated'})');
    _jumpTarget = chunks.last;
    _loadInPieces(
      [for (final n in chunks) if (!_cache.containsKey(n) && !_loading.containsKey(n)) n],
      ChunkPriority.jump,
    );
  }

  FutureOr<Uint8List>? _cached(int index) {
    final chunk = _cache.remove(index);
    if (chunk != null) _cache[index] = chunk; // now the most recently used
    return chunk;
  }

  // ── Priority queue ──────────────────────────────────────────────────────
  //
  // Every fetch is a request with a level (ChunkPriority). Requests wait in
  // [_queue] and are sent most urgent first, oldest first among equals. Level
  // 1 is sent at once; levels 2 and 3 only while fewer than [maxInFlight]
  // requests are on the way.
  //
  // A read that waits for a chunk raises its request to level 1. So a
  // request at level 2 or 3 never has a read waiting for it, and dropping or
  // cancelling it can never make a PDFium read fail.

  final _queue = <_Request>[];
  final _sent = <_Request>{};

  /// The request (queued or on the way) that will deliver each chunk.
  final _requestOf = <int, _Request>{};

  /// How many reads wait for each chunk.
  final _waiters = <int, int>{};

  /// Starts getting [indexes]: from the device when [stored] has them,
  /// otherwise by requests at [priority]. Each chunk gets a future in
  /// [_loading], so a second read that needs it waits for this one.
  void _load(List<int> indexes, ChunkPriority priority) {
    if (indexes.isEmpty) return;
    final done = {for (final index in indexes) index: Completer<Uint8List>()};
    for (final entry in done.entries) {
      // A failure nobody is waiting for must not count as unhandled.
      _loading[entry.key] = entry.value.future..ignore();
    }
    () async {
      try {
        final toFetch = await _loadStored(indexes, done);
        for (final batch in planRequests(toFetch, maxChunks: layout.maxChunksPerRequest)) {
          final request = _Request(batch, priority, {for (final n in batch) n: done[n]!});
          // Raised while it was being looked for on the device?
          if (batch.any(_waiters.containsKey)) request.priority = ChunkPriority.needed;
          _queue.add(request);
          for (final n in batch) {
            _requestOf[n] = request;
          }
        }
        _pump();
      } catch (error, stack) {
        _finish(done, error, stack);
      }
    }();
  }

  /// Sends what may be sent now, most urgent first.
  void _pump() {
    while (_queue.isNotEmpty && !_closed) {
      // The first of the most urgent ones: reduce keeps the earlier on a tie.
      final next = _queue.reduce((a, b) => b.priority.isMoreUrgentThan(a.priority) ? b : a);
      if (next.priority != ChunkPriority.needed && _sent.length >= maxInFlight) return;
      _queue.remove(next);
      _send(next);
    }
  }

  void _send(_Request request) {
    _sent.add(request);
    _log('→ ${chunksSpec(request.chunks)}  level ${request.priority.level} '
        '${request.priority.label}  (${_sent.length} on the way, ${_queue.length} queued)');
    () async {
      try {
        final chunks = await _fetchAndDecrypt(request);
        for (var i = 0; i < request.chunks.length; i++) {
          final n = request.chunks[i];
          _keep(n, chunks[i]);
          _forget(n, request);
          final done = request.done[n]!;
          if (!done.isCompleted) done.complete(chunks[i]);
        }
        _changed();
      } catch (error, stack) {
        for (final n in request.chunks) {
          _forget(n, request);
        }
        _finish(request.done, error, stack);
      } finally {
        _sent.remove(request);
        _pump();
      }
    }();
  }

  /// [request] no longer stands for chunk [n] (it arrived, failed or was
  /// dropped). A newer request for the same chunk is left alone.
  void _forget(int n, _Request request) {
    if (identical(_requestOf[n], request)) _requestOf.remove(n);
    if (identical(_loading[n], request.done[n]?.future)) _loading.remove(n);
  }

  void _finish(Map<int, Completer<Uint8List>> done, Object error, StackTrace stack) {
    for (final entry in done.entries) {
      if (identical(_loading[entry.key], entry.value.future)) _loading.remove(entry.key);
      if (!entry.value.isCompleted) entry.value.completeError(error, stack);
    }
  }

  /// A read now waits for chunk [index]: its request, if any, moves up.
  void _raise(int index, ChunkPriority priority) {
    final request = _requestOf[index];
    if (request == null || !priority.isMoreUrgentThan(request.priority)) return;
    final wasQueued = _queue.contains(request);
    _log('↑ ${chunksSpec(request.chunks)}  level ${request.priority.level} → '
        '${priority.level} ${priority.label}${wasQueued ? '' : ' (already on the way)'}');
    request.priority = priority;
    if (wasQueued) _pump();
  }

  /// Drops every level-3 request: queued ones are never sent, ones on the way
  /// are cancelled. No read waits for any of them (see the notes above).
  void _dropReadAhead() {
    for (final request in [..._queue, ..._sent]) {
      if (request.priority != ChunkPriority.ahead) continue;
      if (request.chunks.any(_waiters.containsKey)) continue; // safety: never
      final sent = _sent.contains(request);
      _log('✗ ${chunksSpec(request.chunks)}  level 3 '
          '${sent ? 'cancelled on the way' : 'dropped from the queue'}: nothing waits for it');
      _queue.remove(request);
      for (final n in request.chunks) {
        _forget(n, request);
      }
      _finish(request.done, const _Dropped(), StackTrace.current);
      if (sent && !request.cancel.isCompleted) request.cancel.complete();
    }
    _pump();
  }

  void _log(String text) {
    if (log) debugPrint('[CHUNKS] $text');
  }

  /// Answers the chunks of [indexes] found in [stored] and returns the rest,
  /// which must be fetched. A stored chunk that doesn't decrypt is dropped
  /// from the store and fetched instead.
  Future<List<int>> _loadStored(
    List<int> indexes,
    Map<int, Completer<Uint8List>> done,
  ) async {
    final store = stored;
    if (store == null) return indexes;
    final found = <int, Uint8List>{};
    final read = await Future.wait([for (final n in indexes) store.read(n)]);
    for (var i = 0; i < indexes.length; i++) {
      final chunk = read[i];
      if (chunk != null) found[indexes[i]] = chunk;
    }
    if (found.isEmpty) return indexes;
    _check();
    final batch = found.keys.toList()..sort();
    final clock = Stopwatch()..start();
    final List<Uint8List> plain;
    try {
      plain = await _cipher.decrypt(batch, [for (final n in batch) found[n]!]);
    } catch (_) {
      if (_closed) rethrow;
      // Damaged on disk (or left from another key): fetch them again.
      for (final n in batch) {
        unawaited(store.remove(n));
      }
      return indexes;
    }
    decryptTime += clock.elapsed;
    chunksFromDevice += batch.length;
    _log('· ${chunksSpec(batch)} from this device');
    for (var i = 0; i < batch.length; i++) {
      _keep(batch[i], plain[i]);
      if (identical(_loading[batch[i]], done[batch[i]]!.future)) _loading.remove(batch[i]);
      if (!done[batch[i]]!.isCompleted) done[batch[i]]!.complete(plain[i]);
    }
    _changed();
    return [for (final n in indexes) if (!found.containsKey(n)) n];
  }

  /// One request: fetch, split, decrypt, repeated until it works. It gives up
  /// only when the server refuses, when [maxDamagedAnswers] answers in a row
  /// don't decrypt, when the screen has gone ([leave]), or when the request
  /// was cancelled (nothing waits for it any more).
  Future<List<Uint8List>> _fetchAndDecrypt(_Request request) async {
    final batch = request.chunks;
    var pause = firstRetryDelay;
    var damaged = 0;
    for (;;) {
      _check();
      if (request.cancel.isCompleted) throw const _Dropped();
      final clock = Stopwatch()..start();
      final Uint8List body;
      try {
        requests++;
        body = await _fetch(chunksSpec(batch), request.cancel.future);
      } catch (error) {
        // Cancelled on purpose: not a network problem, don't repeat it.
        if (request.cancel.isCompleted) throw const _Dropped();
        if (!_isTemporary(error)) {
          _fail(error);
          rethrow;
        }
        if (_left.isCompleted) rethrow;
        _waitFor(error);
        await Future.any([
          Future<void>.delayed(pause),
          _left.future,
          request.cancel.future,
        ]);
        pause = pause * 2 > maxRetryDelay ? maxRetryDelay : pause * 2;
        continue;
      }
      fetchTime += clock.elapsed;
      bytesDownloaded += body.length;
      try {
        final parts = layout.split(batch, body);
        clock.reset();
        final plain = await _cipher.decrypt(batch, parts);
        decryptTime += clock.elapsed;
        _waitFor(null);
        // Kept only once it decrypted, so nothing damaged is stored.
        final store = stored;
        if (store != null) {
          for (var i = 0; i < batch.length; i++) {
            unawaited(store.write(batch[i], parts[i]));
          }
        }
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

/// One request to the chunks endpoint: [chunks] in a row, at [priority].
class _Request {
  _Request(this.chunks, this.priority, this.done);

  final List<int> chunks;
  ChunkPriority priority;

  /// What each chunk's readers wait on.
  final Map<int, Completer<Uint8List>> done;

  /// Completed to cancel the request while it is on the way.
  final cancel = Completer<void>();
}

/// A request that was dropped or cancelled because nothing waited for it.
class _Dropped implements Exception {
  const _Dropped();

  @override
  String toString() => 'Not needed any more.';
}
