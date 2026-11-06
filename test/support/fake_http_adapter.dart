import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Answers Dio's requests in-process, so ApiService can be tested without a
/// server. [answer] gets each request and returns the response, or throws a
/// [DioException] to stand for a network failure.
class FakeHttpAdapter implements HttpClientAdapter {
  FakeHttpAdapter(this.answer);

  final Future<ResponseBody> Function(RequestOptions request, String? body) answer;

  /// Every request so far, as `METHOD url`.
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.uri}');
    final body = requestStream == null
        ? null
        : utf8.decode(await requestStream.expand((bytes) => bytes).toList());
    return answer(options, body);
  }

  @override
  void close({bool force = false}) {}

  static ResponseBody json(Object body, {int status = 200}) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
  );

  static ResponseBody bytes(List<int> body, {int status = 200}) => ResponseBody.fromBytes(
    body,
    status,
    headers: {Headers.contentTypeHeader: ['application/octet-stream']},
  );
}
