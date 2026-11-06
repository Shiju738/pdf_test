import 'package:flutter/material.dart';

/// Shown in place of the viewer when the PDF can't be opened or read.
class ReaderFailure extends StatelessWidget {
  const ReaderFailure({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'This PDF can\'t be read.\n\n$error',
            key: const Key('failure'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Back'),
          ),
        ],
      ),
    ),
  );
}
