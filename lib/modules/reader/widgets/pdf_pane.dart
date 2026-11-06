import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pdfrx/pdfrx.dart';

import '../controllers/reader_controller.dart';
import 'reader_failure.dart';

/// The pdfrx viewer. Built once, in initState: the viewer must not be rebuilt
/// each time the numbers around it change.
class PdfPane extends StatefulWidget {
  const PdfPane({super.key});

  @override
  State<PdfPane> createState() => _PdfPaneState();
}

class _PdfPaneState extends State<PdfPane> {
  late final Widget _viewer;

  @override
  void initState() {
    super.initState();
    final controller = Get.find<ReaderController>();
    final source = controller.source;
    final layout = controller.access.layout;
    _viewer = PdfViewer(
      PdfDocumentRefCustom(
        fileSize: layout.fileSize,
        // pdfrx tells documents apart by this name, so every version of a
        // file needs its own.
        sourceName: 'np:${layout.version}',
        read: source.read,
        // Page 1 shows first; the other pages load afterwards.
        useProgressiveLoading: true,
        // pdfrx calls this once it has closed the document. Only then is it
        // safe to drop the chunks and the key: until then PDFium may still be
        // reading, and a read that fails can crash it.
        onDispose: source.dispose,
      ),
      controller: controller.pdfController,
      params: PdfViewerParams(
        behaviorControlParams: controller.loadAllPages
            ? const PdfViewerBehaviorControlParams()
            // pdfrx 2.4 has no setting for "measure a page only when it is
            // shown"; 2.5 added loadPageDimensionsOnDemand. Putting its
            // background pass off for a year has the same effect here. Pages
            // not measured yet are laid out with the last measured page's
            // size, and their text can't be selected.
            : const PdfViewerBehaviorControlParams(
                trailingPageLoadingDelay: Duration(days: 365),
              ),
        onDocumentChanged: controller.onDocumentChanged,
        onViewerReady: (document, _) =>
            controller.onViewerReady(document.pages.length),
        onPageChanged: controller.onPageChanged,
        errorBannerBuilder: (context, error, stackTrace, documentRef) =>
            ReaderFailure(error: source.lastError ?? error),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _viewer;
}
