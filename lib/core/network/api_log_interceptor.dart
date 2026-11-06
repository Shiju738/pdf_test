import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Prints every API call and its answer to the console, in debug builds only.
///
///     [API #3] → GET https://…/stream/?v=…&chunks=2-4
///     [API #3] ← 200 786.5 KB (application/octet-stream) · 84 ms
///
/// Each call gets a number, so calls that overlap (a read and its read-ahead)
/// can be told apart. Secrets are not printed: key material is shortened, and
/// query values that look like tokens are hidden. Binary answers show only
/// their size.
class ApiLogInterceptor extends Interceptor {
  /// On in debug builds. A test can turn it off.
  static bool enabled = kDebugMode;

  static int _next = 0;
  static const _idKey = 'log.id';
  static const _clockKey = 'log.clock';

  /// Keys whose values are shortened in JSON bodies.
  static const keyFields = {'public_key', 'wrapped_key', 'header', 'private_key'};

  /// Query parameters whose values are hidden, wherever a URL appears (also
  /// inside a JSON answer, such as `stream_url`).
  static final _secretParam = RegExp(
    r'([?&][^=&#]*(?:token|sig|signature|auth|key|secret)[^=&#]*=)[^&#\s"]*',
    caseSensitive: false,
  );

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (enabled) {
      final id = ++_next;
      options.extra[_idKey] = id;
      options.extra[_clockKey] = Stopwatch()..start();
      _print(id, '→ ${options.method} ${_hide(options.uri.toString())}');
      if (options.data != null) _print(id, '  body: ${_json(options.data)}');
    }
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _done(response.requestOptions, '← ${_status(response)}');
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final error = err;
    final response = error.response;
    _done(
      error.requestOptions,
      response != null
          ? '← ${_status(response)}'
          // Dio's own message is a paragraph; the type and the cause say it.
          : '✗ ${error.type.name}${error.error == null ? '' : ': ${error.error}'}',
    );
    handler.next(error);
  }

  void _done(RequestOptions options, String text) {
    final id = options.extra[_idKey] as int?;
    if (!enabled || id == null) return;
    final clock = options.extra[_clockKey] as Stopwatch?;
    _print(id, '$text · ${clock?.elapsedMilliseconds ?? '?'} ms');
  }

  static String _status(Response<dynamic> response) {
    final type = response.headers.value(Headers.contentTypeHeader);
    final data = response.data;
    if (data is List<int>) {
      if (type != null && type.contains('json')) {
        try {
          return '${response.statusCode} ${_size(data.length)} '
              '${_json(jsonDecode(utf8.decode(data)))}';
        } catch (_) {
          // Not JSON after all.
        }
      }
      return '${response.statusCode} ${_size(data.length)} (${type ?? 'no content type'})';
    }
    return '${response.statusCode} ${_json(data)}';
  }

  static String _hide(String text) =>
      text.replaceAllMapped(_secretParam, (match) => '${match[1]}•••');

  static String _json(Object? value) {
    Object? clean(Object? v, [String? key]) => switch (v) {
      Map() => {for (final e in v.entries) e.key: clean(e.value, '${e.key}')},
      List() => [for (final item in v) clean(item)],
      String() when keyFields.contains(key) && v.length > 16 =>
        '${v.substring(0, 8)}…(${v.length} chars)',
      String() => _hide(v),
      _ => v,
    };
    final text = value is String ? _hide(value) : jsonEncode(clean(value));
    return text.length > 800 ? '${text.substring(0, 800)}…' : text;
  }

  static String _size(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
          ? '${(bytes / 1024).toStringAsFixed(1)} KB'
          : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';

  // debugPrint, not dart:developer's log: it shows in `flutter run`'s output
  // too, and throttles long bursts instead of dropping lines.
  static void _print(int id, String text) => debugPrint('[API #$id] $text');
}
