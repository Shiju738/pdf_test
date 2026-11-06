import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/reader_controller.dart';
import '../widgets/fetch_progress.dart';
import '../widgets/pdf_pane.dart';
import '../widgets/reader_failure.dart';

class ReaderView extends GetView<ReaderController> {
  const ReaderView({super.key});

  @override
  Widget build(BuildContext context) {
    final access = controller.access;
    final source = controller.source;
    return Scaffold(
      appBar: AppBar(
        title: Text(access.name.isEmpty ? 'PDF' : access.name),
        actions: [
          Obx(() {
            controller.tick.value;
            final pageCount = controller.pageCount.value;
            if (pageCount == null || source.failure != null) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  // While dragging: the page under the thumb.
                  'Page ${controller.sliderPage.value ?? controller.page.value ?? 1} of $pageCount',
                  key: const Key('pageNumber'),
                ),
              ),
            );
          }),
        ],
      ),
      body: Obx(() {
        controller.tick.value; // the source's counters changed
        final pageCount = controller.pageCount.value;
        final page = controller.page.value;
        final sliderPage = controller.sliderPage.value;
        final failure = source.failure;
        final waitingFor = source.waitingFor;
        return Column(
          children: [
            if (waitingFor != null && failure == null)
              Material(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: ListTile(
                  key: const Key('waiting'),
                  dense: true,
                  leading: const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: const Text('Waiting for the network. Trying again…'),
                  subtitle: Text('$waitingFor', maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              ),
            // Once the file can't be read any more the viewer is taken away,
            // which makes pdfrx close the document.
            Expanded(
              key: const ValueKey('viewer'),
              child: failure == null
                  ? Stack(
                      children: [
                        const Positioned.fill(child: PdfPane()),
                        if (controller.loadingPage.value case final loading?)
                          Positioned(
                            top: 12,
                            left: 0,
                            right: 0,
                            child: Center(child: _LoadingPage(page: loading)),
                          ),
                      ],
                    )
                  : ReaderFailure(error: failure),
            ),
            if (pageCount != null && pageCount > 1 && failure == null)
              Slider(
                key: const Key('pageSlider'),
                min: 1,
                max: pageCount.toDouble(),
                divisions: pageCount - 1,
                value: (sliderPage ?? page ?? 1).clamp(1, pageCount).toDouble(),
                label: 'Page ${sliderPage ?? page ?? 1}',
                onChanged: controller.onSliderChanged,
                onChangeEnd: controller.onSliderChangeEnd,
              ),
            FetchProgress(
              source: source,
              readyNote: controller.readyNote.value,
              loadAllPages: controller.loadAllPages,
            ),
          ],
        );
      }),
    );
  }
}

/// The small "Loading page N…" label shown over the page after a jump.
class _LoadingPage extends StatelessWidget {
  const _LoadingPage({required this.page});

  final int page;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const Key('loadingPage'),
      color: scheme.inverseSurface.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onInverseSurface),
            ),
            const SizedBox(width: 10),
            Text('Loading page $page…', style: TextStyle(color: scheme.onInverseSurface)),
          ],
        ),
      ),
    );
  }
}
