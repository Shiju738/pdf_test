import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_pdf_reader_test/core/network/api_log_interceptor.dart';
import 'package:secure_pdf_reader_test/core/network/api_service.dart';
import 'package:secure_pdf_reader_test/data/services/reader_api.dart';

import 'support/fake_http_adapter.dart';

void main() {
  final lines = <String>[];
  late DebugPrintCallback original;

  setUp(() {
    lines.clear();
    original = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    ApiLogInterceptor.enabled = true;
  });
  tearDown(() => debugPrint = original);

  final header = base64Encode(List.filled(28, 1));
  late FakeHttpAdapter adapter;
  String? sentBody;

  ReaderApi api() {
    adapter = FakeHttpAdapter((request, body) async {
      if (request.method == 'POST') {
        sentBody = body;
        return FakeHttpAdapter.json({
          'cipher': 'AES-256-GCM', 'tag_size': 16, 'name': 'Book', 'pages': 3,
          'version': 'v1', 'file_size': 100, 'chunk_size': 100, 'total_chunks': 1,
          'header': header, 'wrapped_key': base64Encode(List.filled(256, 9)),
          'key_algorithm': 'RSA-OAEP-SHA256', 'stream_url': 'stream/?v=1&token=SECRET123',
        });
      }
      return switch (request.uri.queryParameters['chunks']) {
        '9' => FakeHttpAdapter.json({'code': 'version_changed', 'detail': 'Gone'}, status: 409),
        '7' => FakeHttpAdapter.json({'detail': 'Busy'}, status: 503),
        '8' => throw DioException.receiveTimeout(
            timeout: const Duration(seconds: 30),
            requestOptions: request,
          ),
        _ => FakeHttpAdapter.bytes(Uint8List(2048)),
      };
    });
    return ReaderApi(ApiService(dio: Dio()..httpClientAdapter = adapter));
  }

  Future<PdfAccess> access(ReaderApi api) => api.requestAccess(
    Uri.parse('http://server/access/'),
    publicKey: 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA' * 4,
    algorithm: 'RSA-OAEP-SHA256',
  );

  test('the access call sends JSON and reads the answer', () async {
    final reader = api();
    final answer = await access(reader);
    expect(jsonDecode(sentBody!), {
      'public_key': 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA' * 4,
      'algorithm': 'RSA-OAEP-SHA256',
    });
    expect(answer.name, 'Book');
    expect(answer.wrappedKey.length, 256);
    expect(answer.streamUrl.toString(), 'http://server/access/stream/?v=1&token=SECRET123');
  });

  test('chunks come back as bytes, with the chunks parameter added', () async {
    final reader = api();
    final bytes = await reader.fetchChunks((await access(reader)).streamUrl, '0-1');
    expect(bytes.length, 2048);
    expect(adapter.requests.last, 'GET http://server/access/stream/?v=1&token=SECRET123&chunks=0-1');
  });

  test('a refusal is an ApiException; a busy server or no answer may pass', () async {
    final reader = api();
    final stream = Uri.parse('http://server/stream/');

    final refused = await reader.fetchChunks(stream, '9').then<Object>((_) => 'no error', onError: (Object e) => e);
    expect(refused, isA<ApiException>().having((e) => e.code, 'code', 'version_changed'));
    expect(ReaderApi.isTemporary(refused), isFalse);

    final busy = await reader.fetchChunks(stream, '7').then<Object>((_) => 'no error', onError: (Object e) => e);
    expect(busy, isA<ApiException>().having((e) => e.status, 'status', 503));
    expect(ReaderApi.isTemporary(busy), isTrue);

    final timeout = await reader.fetchChunks(stream, '8').then<Object>((_) => 'no error', onError: (Object e) => e);
    expect(timeout, isA<NetworkException>());
    expect('$timeout', 'server did not answer in time.');
    expect(ReaderApi.isTemporary(timeout), isTrue);
  });

  test('the debug log shows each call and its answer, without secrets', () async {
    final reader = api();
    final answer = await access(reader);
    await reader.fetchChunks(answer.streamUrl, '0-1');
    await expectLater(reader.fetchChunks(answer.streamUrl, '9'), throwsA(isA<ApiException>()));
    await expectLater(reader.fetchChunks(answer.streamUrl, '8'), throwsA(isA<NetworkException>()));

    final log = lines.join('\n');
    // ignore: avoid_print
    print(log);
    expect(log, contains('→ POST http://server/access/'));
    expect(log, contains('"public_key":"MIIBIjAN…(176 chars)"'));
    expect(log, contains('chunks=0-1'));
    expect(log, contains('2.0 KB (application/octet-stream)'));
    expect(log, contains('← 409'));
    expect(log, contains('version_changed'));
    expect(log, contains('✗ receiveTimeout'));
    expect(log, isNot(contains('SECRET123')), reason: 'token hidden');
    expect(log, isNot(contains('CQkJCQkJCQkJCQkJCQkJCQkJ')), reason: 'wrapped key shortened');
    expect(RegExp(r'\[API #\d+\] →').allMatches(log).length, 4);
    expect(RegExp(r'\[API #\d+\] [←✗]').allMatches(log).length, 4);
  });

  test('the log prints nothing when turned off', () async {
    ApiLogInterceptor.enabled = false;
    await api().fetchChunks(Uri.parse('http://server/stream/'), '0');
    expect(lines, isEmpty);
  });
}
