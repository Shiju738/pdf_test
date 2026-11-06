import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../core/utils/format.dart';
import '../controllers/home_controller.dart';

class HomeView extends GetView<HomeController> {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Secure PDF reader test')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('1. This device\'s key pair', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Obx(() => Text(controller.keyStatus.value, key: const Key('keyStatus'))),
          Obx(() {
            final key = controller.key.value;
            if (key == null) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Text('Fingerprint: ${key.fingerprint.substring(0, 16)}…'),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Public key: ${key.publicKeyBase64}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy the public key',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: key.publicKeyBase64),
                      ),
                    ),
                  ],
                ),
              ],
            );
          }),
          Align(
            alignment: Alignment.centerLeft,
            child: Obx(
              () => TextButton(
                onPressed: controller.busy.value ||
                        (controller.key.value == null && !controller.keyFailed)
                    ? null
                    : () => controller.prepareKey(makeNew: true),
                child: const Text('Make a new key pair'),
              ),
            ),
          ),
          const Divider(height: 32),
          Text('2. PDF access URL', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            key: const Key('accessUrl'),
            controller: controller.url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'http://…/api/v1/reader-test/access/',
            ),
          ),
          Obx(
            () => SwitchListTile(
              key: const Key('loadAllPages'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Load the other pages in the background'),
              subtitle: Text(
                controller.loadAllPages.value
                    ? 'What pdfrx does by default: the whole file arrives within seconds.'
                    : 'Off: a page is fetched only when it is shown.',
              ),
              value: controller.loadAllPages.value,
              onChanged: controller.busy.value ? null : controller.setLoadAllPages,
            ),
          ),
          const SizedBox(height: 4),
          Obx(() {
            final busy = controller.busy.value;
            return FilledButton.icon(
              key: const Key('openPdf'),
              onPressed: controller.key.value == null || busy ? null : controller.open,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.lock_open),
              label: Text(busy ? 'Opening…' : 'Open PDF'),
            );
          }),
          const Divider(height: 32),
          Text('Saved on this device', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Obx(() {
            final bytes = controller.savedBytes.value;
            return Text(
              bytes == null
                  ? 'Counting the saved chunks…'
                  : bytes == 0
                      ? 'No chunks saved. Opened files are downloaded.'
                      : '${megabytes(bytes)} of encrypted chunks saved: '
                          'opening those files again needs no download.',
              key: const Key('savedSize'),
            );
          }),
          Align(
            alignment: Alignment.centerLeft,
            child: Obx(() {
              final clearing = controller.clearingSaved.value;
              return TextButton.icon(
                key: const Key('clearSaved'),
                onPressed: clearing ||
                        controller.busy.value ||
                        (controller.savedBytes.value ?? 0) == 0
                    ? null
                    : () => _confirmClear(context),
                icon: const Icon(Icons.delete_outline),
                label: Text(clearing ? 'Deleting…' : 'Delete saved chunks'),
              );
            }),
          ),
          const Divider(height: 32),
          Text('Steps', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Obx(
            () => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, step) in controller.steps.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${index + 1}. $step',
                      style: step.startsWith('Failed')
                          ? TextStyle(color: theme.colorScheme.error)
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete saved chunks?'),
        content: const Text(
          'Every file will be downloaded again the next time it is opened.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirmClearSaved'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes == true) await controller.clearSaved();
  }
}
