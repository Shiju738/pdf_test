import 'dart:convert';

/// The server answered, and refused. [code] is its machine-readable reason,
/// such as `version_changed`, when it gave one.
class ApiException implements Exception {
  ApiException(this.status, this.code, this.message);

  /// From an error answer's [status] and body ([data]: a decoded JSON map, a
  /// string, or bytes).
  factory ApiException.fromBody(int status, Object? data) {
    String? code;
    var message = 'The server answered $status.';
    try {
      final body = switch (data) {
        Map() => data,
        String() => jsonDecode(data),
        List<int>() => jsonDecode(utf8.decode(data)),
        _ => null,
      };
      if (body is Map) {
        code = body['code'] as String?;
        message = body['detail'] as String? ?? jsonEncode(body);
      }
    } catch (_) {
      // Not JSON: keep the plain message.
    }
    return ApiException(status, code, message);
  }

  final int status;
  final String? code;
  final String message;

  /// The same call may work a little later.
  bool get mayPass => status >= 500 || status == 429 || code == 'source_unavailable';

  @override
  String toString() => code == null ? '$status: $message' : '$status $code: $message';
}

/// The call didn't get an answer: no network, the server didn't answer in
/// time, or the connection broke. Always worth trying again.
class NetworkException implements Exception {
  NetworkException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Whether a failed call may work if it is tried again: no when the server
/// refused (the file changed, access ended), yes for anything else, such as
/// no network, a timeout or a busy server.
bool isTemporaryApiError(Object error) => error is! ApiException || error.mayPass;
