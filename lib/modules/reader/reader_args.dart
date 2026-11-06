import '../../data/services/chunk_source.dart';
import '../../data/services/reader_api.dart';

/// What the home screen hands the reader route (as go_router `extra`).
class ReaderArgs {
  const ReaderArgs({
    required this.access,
    required this.source,
    required this.sinceOpen,
    required this.loadAllPages,
  });

  final PdfAccess access;

  /// The reader owns it from here: it is closed when pdfrx has closed the
  /// document.
  final ChunkSource source;

  /// Running since "Open PDF" was pressed.
  final Stopwatch sinceOpen;

  /// True: pdfrx's normal behaviour, which measures every page in the
  /// background after showing the first one, and so fetches the whole file
  /// within seconds. False: only the pages that are shown are fetched.
  final bool loadAllPages;
}
