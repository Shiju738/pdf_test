import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'file_layout.dart';

/// The server refused a call. [code] is its machine-readable reason, such as
/// `version_changed`, when it gave one.
class ApiException implements Exception {
  ApiException(this.status, this.code, this.message);

  factory ApiException.fromResponse(http.Response response) {
    String? code;
    var message = 'The server answered ${response.statusCode}.';
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        code = body['code'] as String?;
        message = body['detail'] as String? ?? jsonEncode(body);
      }
    } catch (_) {
      // Not JSON: keep the plain message.
    }
    return ApiException(response.statusCode, code, message);
  }

  final int status;
  final String? code;
  final String message;

  /// The same call may work a little later.
  bool get mayPass => status >= 500 || status == 429 || code == 'source_unavailable';

  @override
  String toString() => code == null ? '$status: $message' : '$status $code: $message';
}

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
    );
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
}

/// The two calls the reader makes.
class ReaderApi {
  ReaderApi({http.Client? client, this.timeout = const Duration(seconds: 30)})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  /// Sends the phone's public key to [accessUrl] and gets back the file's
  /// wrapped key and layout.
  Future<PdfAccess> requestAccess(
    Uri accessUrl, {
    required String publicKey,
    required String algorithm,
  }) async {
    final response = await _client
        .post(
          accessUrl,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'public_key': publicKey, 'algorithm': algorithm}),
        )
        .timeout(timeout);
    if (response.statusCode != 200) throw ApiException.fromResponse(response);
    return PdfAccess.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
      accessUrl,
    );
  }

  /// The stored chunks [chunks] names (for example `0-1,22`), still
  /// encrypted, one after another in the order asked.
  Future<Uint8List> fetchChunks(Uri streamUrl, String chunks) async {
    final url = streamUrl.replace(
      queryParameters: {...streamUrl.queryParameters, 'chunks': chunks},
    );
    // No Accept header: the server would refuse "application/octet-stream".
    final response = await _client.get(url).timeout(timeout);
    if (response.statusCode != 200) throw ApiException.fromResponse(response);
    return response.bodyBytes;
  }

  /// Whether a failed call may work if it is tried again: no when the server
  /// refused (the file changed, access ended), yes for anything else, such as
  /// no network, a timeout or a busy server.
  static bool isTemporary(Object error) =>
      error is! ApiException || error.mayPass;

  void close() => _client.close();
}
