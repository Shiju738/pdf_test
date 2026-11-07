import 'dart:convert';
import 'dart:typed_data';

import 'file_layout.dart';

/// What the access call answers: the file's layout, its key wrapped for this
/// phone, and where to get its chunks.
class PdfAccess {
  PdfAccess({
    required this.name,
    required this.pages,
    required this.layout,
    required this.wrappedKey,
    required this.keyAlgorithm,
    required this.streamUrl,
    this.pageChunks,
  });

  /// [accessUrl] is the URL that gave this answer: a relative `stream_url` is
  /// resolved against it.
  factory PdfAccess.fromJson(Map<String, dynamic> json, Uri accessUrl) {
    if (json['cipher'] != 'AES-256-GCM' || json['tag_size'] != tagSize) {
      throw const FormatException('This app only reads AES-256-GCM chunks with a 16-byte tag.');
    }
    return PdfAccess(
      name: (json['name'] ?? json['chapter_name'] ?? '') as String,
      pages: (json['pages'] ?? 0) as int,
      layout: FileLayout(
        version: json['version'] as String,
        fileSize: json['file_size'] as int,
        chunkSize: json['chunk_size'] as int,
        totalChunks: json['total_chunks'] as int,
        header: base64Decode(json['header'] as String),
      ),
      wrappedKey: base64Decode(json['wrapped_key'] as String),
      keyAlgorithm: json['key_algorithm'] as String,
      streamUrl: accessUrl.resolve(json['stream_url'] as String),
      pageChunks: _pageChunks(json['page_chunks']),
    );
  }

  /// `"page_chunks": {"25": [17, 18], …}`: for each page (from 1), the chunks
  /// needed to draw it. Optional: null when the server doesn't send it, or
  /// sends something this app can't read (then the app guesses instead).
  static Map<int, List<int>>? _pageChunks(Object? value) {
    if (value is! Map) return null;
    try {
      return {
        for (final MapEntry(:key, :value) in value.entries)
          int.parse('$key'): [for (final n in value as List) n as int],
      };
    } catch (_) {
      return null;
    }
  }

  final String name;
  final int pages;
  final FileLayout layout;

  /// The file's AES-256 key, encrypted with this phone's public key.
  final Uint8List wrappedKey;

  /// How [wrappedKey] was wrapped: the algorithm the phone asked for.
  final String keyAlgorithm;

  /// Where the chunks come from. It already names the file's version.
  final Uri streamUrl;

  /// The chunks each page needs (page number → chunk numbers), when the
  /// server sends `page_chunks`. Used to fetch a jumped-to page first.
  final Map<int, List<int>>? pageChunks;
}
