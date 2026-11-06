import 'dart:math';
import 'dart:typed_data';

/// Every stored chunk ends with a GCM tag of this many bytes.
const tagSize = 16;

/// The stored file's header, which goes into every chunk's decryption.
const headerSize = 28;

/// One chunk request may ask for this much of the PDF at most.
const maxBytesPerRequest = 4 * 1024 * 1024;

/// One chunk request may name this many runs of chunks at most.
const maxRunsPerRequest = 4;

/// Where the chunks of one encrypted file are, as the server's `access`
/// answer describes it.
class FileLayout {
  FileLayout({
    required this.version,
    required this.fileSize,
    required this.chunkSize,
    required this.totalChunks,
    required this.header,
  }) {
    if (header.length != headerSize) {
      throw FormatException('The header is ${header.length} bytes, not $headerSize.');
    }
    if (chunkSize <= 0 || fileSize < 0) {
      throw const FormatException('The file sizes make no sense.');
    }
    if (totalChunks != max(1, (fileSize + chunkSize - 1) ~/ chunkSize)) {
      throw const FormatException('total_chunks does not fit the file size.');
    }
  }

  /// Names this exact stored file. It changes when the file is replaced.
  final String version;

  /// Size of the PDF in bytes: what the viewer is told.
  final int fileSize;

  /// Bytes of PDF in every chunk but the last.
  final int chunkSize;

  final int totalChunks;

  /// The stored file's first 28 bytes.
  final Uint8List header;

  int get lastChunk => totalChunks - 1;

  /// Bytes of PDF in chunk [index].
  int plainLength(int index) =>
      index < lastChunk ? chunkSize : fileSize - index * chunkSize;

  /// Bytes chunk [index] takes in the stored file, and in an answer from the
  /// chunks endpoint: the chunk and its tag.
  int storedLength(int index) => plainLength(index) + tagSize;

  /// Where chunk [index] starts in a stored file (a download).
  int storedOffset(int index) => headerSize + index * (chunkSize + tagSize);

  int get maxChunksPerRequest => max(1, maxBytesPerRequest ~/ chunkSize);

  /// The 12-byte nonce of chunk [index]: its number as 11 bytes, big-endian,
  /// then 1 for the file's last chunk and 0 for every other.
  Uint8List nonce(int index) {
    final nonce = Uint8List(12);
    for (var i = 10, rest = index; i >= 0; i--, rest >>= 8) {
      nonce[i] = rest & 0xff;
    }
    nonce[11] = index == lastChunk ? 1 : 0;
    return nonce;
  }

  /// Cuts an answer from the chunks endpoint into its chunks. The answer holds
  /// the chunks asked for, one after another, in the order asked.
  List<Uint8List> split(List<int> indexes, Uint8List body) {
    final expected = indexes.fold(0, (sum, index) => sum + storedLength(index));
    if (body.length != expected) {
      throw FormatException(
        'The answer is ${body.length} bytes; chunks $indexes need $expected.',
      );
    }
    final parts = <Uint8List>[];
    var at = 0;
    for (final index in indexes) {
      final length = storedLength(index);
      parts.add(Uint8List.sublistView(body, at, at + length));
      at += length;
    }
    return parts;
  }
}

/// Groups chunk numbers into requests the server accepts: at most
/// [maxRunsPerRequest] runs of neighbouring chunks and [maxChunks] chunks
/// each. The numbers come out sorted, each once.
List<List<int>> planRequests(Iterable<int> indexes, {required int maxChunks}) {
  final requests = <List<int>>[];
  var current = <int>[];
  var runs = 0;
  for (final index in indexes.toSet().toList()..sort()) {
    final continuesRun = current.isNotEmpty && current.last == index - 1;
    if (current.length == maxChunks || (!continuesRun && runs == maxRunsPerRequest)) {
      requests.add(current);
      current = <int>[];
      runs = 0;
    }
    if (current.isEmpty || current.last != index - 1) runs++;
    current.add(index);
  }
  if (current.isNotEmpty) requests.add(current);
  return requests;
}

/// The `chunks` value for sorted chunk numbers: `[0, 1, 22]` gives `0-1,22`.
String chunksSpec(List<int> indexes) {
  final runs = <String>[];
  var first = indexes.first;
  var previous = first;
  void close() => runs.add(first == previous ? '$first' : '$first-$previous');
  for (final index in indexes.skip(1)) {
    if (index != previous + 1) {
      close();
      first = index;
    }
    previous = index;
  }
  close();
  return runs.join(',');
}
