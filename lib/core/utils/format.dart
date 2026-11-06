/// Sizes and counts for the screen.
library;

String kilobytes(int bytes) => '${(bytes / 1024).round()} KB';

String megabytes(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';

/// `1 request`, `2 requests`.
String counted(int count, String thing) => '$count $thing${count == 1 ? '' : 's'}';
