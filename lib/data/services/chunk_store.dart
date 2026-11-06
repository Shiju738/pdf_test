import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:path_provider/path_provider.dart';

import '../models/file_layout.dart';

/// The chunks of one file kept on the device, still encrypted: exactly the
/// bytes the chunks endpoint sent (the chunk and its GCM tag). Without the
/// file key, which is never stored, they can't be read.
abstract interface class StoredChunks {
  /// Chunk [index] as stored, or null when it isn't here.
  Future<Uint8List?> read(int index);

  /// Keeps chunk [index]. Errors are swallowed: the store is only a cache.
  Future<void> write(int index, Uint8List stored);

  /// Drops chunk [index], for example because it didn't decrypt.
  Future<void> remove(int index);
}

/// Keeps fetched chunks in the app's cache folder, so opening the same file
/// again doesn't download them again.
///
/// One folder per file version: `chunk_cache/<sha256 of stream path + version>/`.
/// When the server replaces the file its version changes, so old chunks are
/// never mixed with new ones. The least recently opened folders are deleted
/// once all of them pass [maxBytes].
class ChunkStore {
  ChunkStore({Future<Directory> Function()? root, this.maxBytes = 512 * 1024 * 1024})
    : _root = root ?? _defaultRoot;

  /// How much the cache may hold, over all files.
  final int maxBytes;

  final Future<Directory> Function() _root;

  // The OS cache folder: not backed up, and the OS may clear it when space
  // runs low, which is fine for a cache.
  static Future<Directory> _defaultRoot() async =>
      Directory('${(await getApplicationCacheDirectory()).path}/chunk_cache');

  static const _usedMark = '.used';

  /// The stored chunks of the file whose chunks come from [streamUrl], at
  /// [layout]'s version. The query is left out of the key: it may carry a
  /// token that changes on every access call.
  Future<StoredChunks> open(Uri streamUrl, FileLayout layout) async {
    final root = await _root();
    final id = utf8.encode(
      '${streamUrl.scheme}://${streamUrl.authority}${streamUrl.path}'
      '|${layout.version}|${layout.fileSize}|${layout.chunkSize}',
    );
    final name = _hex(const DartSha256().hashSync(id).bytes);
    final folder = Directory('${root.path}/$name');
    await folder.create(recursive: true);
    // Marks the folder as just used, for pruning.
    await File('${folder.path}/$_usedMark').writeAsString('');
    unawaited(_prune(root, keep: name).catchError((_) {}));
    return _FolderChunks(folder, layout);
  }

  /// Bytes kept over all files.
  Future<int> size() async {
    final root = await _root();
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entry in root.list(recursive: true)) {
      if (entry is File) total += await entry.length();
    }
    return total;
  }

  /// Deletes every stored chunk.
  Future<void> clear() async {
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
  }

  /// Deletes the least recently opened files until the rest fit [maxBytes].
  Future<void> _prune(Directory root, {required String keep}) async {
    final folders = <(Directory, DateTime, int)>[];
    var total = 0;
    await for (final entry in root.list()) {
      if (entry is! Directory) continue;
      var size = 0;
      await for (final file in entry.list()) {
        if (file is File) size += await file.length();
      }
      final mark = File('${entry.path}/$_usedMark');
      final used = await mark.exists()
          ? await mark.lastModified()
          : DateTime.fromMillisecondsSinceEpoch(0);
      folders.add((entry, used, size));
      total += size;
    }
    folders.sort((a, b) => a.$2.compareTo(b.$2)); // least recent first
    for (final (folder, _, size) in folders) {
      if (total <= maxBytes) break;
      if (folder.path.endsWith('/$keep')) continue;
      await folder.delete(recursive: true);
      total -= size;
    }
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class _FolderChunks implements StoredChunks {
  _FolderChunks(this._folder, this._layout);

  final Directory _folder;
  final FileLayout _layout;

  File _file(int index) => File('${_folder.path}/$index.chunk');

  @override
  Future<Uint8List?> read(int index) async {
    try {
      final bytes = await _file(index).readAsBytes();
      // A short or long file is not this chunk: ignore it.
      return bytes.length == _layout.storedLength(index) ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(int index, Uint8List stored) async {
    try {
      // Written to a temporary name and renamed, so a chunk is either all
      // there or not there at all, even if the app is killed meanwhile.
      final temp = File('${_folder.path}/$index.part');
      await temp.writeAsBytes(stored, flush: true);
      await temp.rename(_file(index).path);
    } catch (_) {
      // Out of space, folder cleared by the OS…: the chunk is fetched again.
    }
  }

  @override
  Future<void> remove(int index) async {
    try {
      await _file(index).delete();
    } catch (_) {}
  }
}

/// Chunks kept in memory: for tests.
class MemoryChunks implements StoredChunks {
  final chunks = <int, Uint8List>{};

  @override
  Future<Uint8List?> read(int index) async => chunks[index];

  @override
  Future<void> write(int index, Uint8List stored) async =>
      chunks[index] = Uint8List.fromList(stored);

  @override
  Future<void> remove(int index) async => chunks.remove(index);
}
