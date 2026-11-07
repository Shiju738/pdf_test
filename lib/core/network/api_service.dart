import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'api_log_interceptor.dart';

export 'api_exception.dart';

/// The one place the app talks HTTP. Every API call goes through here, so
/// they all get the same timeouts, the debug log, and the same errors:
///
/// - the server refused (any status but 2xx) → [ApiException]
/// - no answer (no network, timeout, broken connection) → [NetworkException]
///
/// Feature services (such as ReaderApi) take an ApiService and only say which
/// URL to call and how to read the answer.
class ApiService {
  ApiService({
    Dio? dio,
    String? baseUrl,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration receiveTimeout = const Duration(seconds: 30),
    Duration sendTimeout = const Duration(seconds: 30),
  }) : dio = dio ?? Dio() {
    this.dio.options
      ..baseUrl = baseUrl ?? this.dio.options.baseUrl
      ..connectTimeout = connectTimeout
      ..receiveTimeout = receiveTimeout
      ..sendTimeout = sendTimeout;
    this.dio.interceptors.add(ApiLogInterceptor());
  }

  final Dio dio;

  /// GET, answering decoded JSON.
  Future<Map<String, dynamic>> getJson(Uri url, {Map<String, String>? headers}) =>
      _json('GET', url, headers: headers);

  /// POST [body] as JSON, answering decoded JSON.
  Future<Map<String, dynamic>> postJson(
    Uri url,
    Object body, {
    Map<String, String>? headers,
  }) => _json('POST', url, body: body, headers: headers);

  /// GET, answering the raw bytes (files, encrypted chunks).
  ///
  /// When [cancelled] completes before the answer is in, the call is aborted
  /// and throws a [NetworkException].
  Future<Uint8List> getBytes(
    Uri url, {
    Map<String, String>? headers,
    Future<void>? cancelled,
  }) async {
    final response = await send<List<int>>(
      'GET',
      url,
      headers: headers,
      responseType: ResponseType.bytes,
      cancelled: cancelled,
    );
    final data = response.data ?? const <int>[];
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  Future<Map<String, dynamic>> _json(
    String method,
    Uri url, {
    Object? body,
    Map<String, String>? headers,
  }) async {
    final response = await send<Object?>(
      method,
      url,
      body: body,
      headers: headers,
      responseType: ResponseType.json,
    );
    final data = response.data;
    if (data is Map<String, dynamic>) return data;
    throw ApiException(response.statusCode ?? 0, 'bad_answer', 'Expected a JSON object.');
  }

  /// Any call. Only 2xx answers come back; everything else is thrown as an
  /// [ApiException] or a [NetworkException].
  Future<Response<T>> send<T>(
    String method,
    Uri url, {
    Object? body,
    Map<String, String>? headers,
    ResponseType responseType = ResponseType.json,
    Future<void>? cancelled,
  }) async {
    final token = cancelled == null ? null : CancelToken();
    if (token != null) unawaited(cancelled!.then((_) => token.cancel()));
    try {
      return await dio.requestUri<T>(
        url,
        data: body,
        cancelToken: token,
        options: Options(
          method: method,
          headers: headers,
          responseType: responseType,
          contentType: body == null ? null : Headers.jsonContentType,
        ),
      );
    } on DioException catch (error) {
      throw _translate(error);
    }
  }

  static Exception _translate(DioException error) {
    final response = error.response;
    if (error.type == DioExceptionType.badResponse && response != null) {
      return ApiException.fromBody(response.statusCode ?? 0, response.data);
    }
    final host = error.requestOptions.uri.host;
    final message = switch (error.type) {
      DioExceptionType.connectionTimeout => 'Could not reach $host in time.',
      DioExceptionType.receiveTimeout => '$host did not answer in time.',
      DioExceptionType.sendTimeout => 'Sending to $host took too long.',
      DioExceptionType.connectionError => 'No connection to $host.',
      DioExceptionType.cancel => 'The call to $host was cancelled.',
      _ => 'The call to $host failed: ${error.message ?? error.error}',
    };
    return NetworkException(message, cause: error);
  }

  void close() => dio.close(force: true);
}
