import 'package:flutter/material.dart';

import '../../../core/utils/format.dart';
import '../../../data/services/chunk_source.dart';

/// How much of the file is on the phone so far.
class FetchProgress extends StatelessWidget {
  const FetchProgress({
    super.key,
    required this.source,
    required this.readyNote,
    required this.loadAllPages,
  });

  final ChunkSource source;
  final String? readyNote;
  final bool loadAllPages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layout = source.layout;
    final loaded = source.loadedChunks;
    final fetched = source.plainBytesLoaded;
    final percent = layout.fileSize == 0 ? 100 : fetched * 100 ~/ layout.fileSize;
    final error = source.lastError;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Fetched ${loaded.length} of ${layout.totalChunks} chunks: '
                '${megabytes(fetched)} of ${megabytes(layout.fileSize)} ($percent%)',
                key: const Key('fetched'),
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              ChunkMap(total: layout.totalChunks, loaded: loaded),
              const SizedBox(height: 4),
              Text(
                '${counted(source.requests, 'request')} · '
                '${source.chunksFromDevice} from this device · network '
                '${source.fetchTime.inMilliseconds} ms · decrypt '
                '${source.decryptTime.inMilliseconds} ms · the viewer made '
                '${counted(source.reads, 'read')} (${kilobytes(source.bytesRead)})',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                loadAllPages
                    ? 'The other pages load in the background.'
                    : 'A page is fetched only when it is shown.',
                style: theme.textTheme.bodySmall,
              ),
              if (readyNote != null)
                Text(readyNote!, key: const Key('viewerReady'), style: theme.textTheme.bodySmall),
              if (error != null)
                Text(
                  'Last failed read: $error',
                  key: const Key('failedRead'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One small square per chunk, filled once the chunk has been fetched.
class ChunkMap extends StatelessWidget {
  const ChunkMap({super.key, required this.total, required this.loaded});

  final int total;
  final Set<int> loaded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 44),
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [
            for (var index = 0; index < total; index++)
              Container(
                width: 8,
                height: 8,
                color: loaded.contains(index) ? scheme.primary : scheme.outlineVariant,
              ),
          ],
        ),
      ),
    );
  }
}
