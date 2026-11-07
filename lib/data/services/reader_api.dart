import 'dart:typed_data';

import '../../core/network/api_service.dart';
import '../models/pdf_access.dart';

export '../../core/network/api_exception.dart';
export '../models/pdf_access.dart';

/// The two calls the reader makes. HTTP itself (timeouts, logging, errors) is
/// [ApiService]'s job.
class ReaderApi {
  ReaderApi([ApiService? api]) : _api = api ?? ApiService();

  final ApiService _api;

  /// Sends the phone's public key to [accessUrl] and gets back the file's
  /// wrapped key and layout.
  Future<PdfAccess> requestAccess(
    Uri accessUrl, {
    required String publicKey,
    required String algorithm,
  }) async {
    final json = await _api.postJson(accessUrl, {
      'public_key': publicKey,
      'algorithm': algorithm,
    });
    return PdfAccess.fromJson(json, accessUrl);
  }

  /// The stored chunks [chunks] names (for example `0-1,22`), still
  /// encrypted, one after another in the order asked.
  // No Accept header: the server would refuse "application/octet-stream".
  ///
  /// When [cancelled] completes first, the request is aborted (Dio
  /// CancelToken) and this throws.
  Future<Uint8List> fetchChunks(
    Uri streamUrl,
    String chunks, {
    Future<void>? cancelled,
  }) => _api.getBytes(
    streamUrl.replace(
      queryParameters: {...streamUrl.queryParameters, 'chunks': chunks},
    ),
    cancelled: cancelled,
  );

  /// See [isTemporaryApiError].
  static bool isTemporary(Object error) => isTemporaryApiError(error);

  void close() => _api.close();
}
