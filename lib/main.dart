import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/bindings/initial_binding.dart';

export 'app/app.dart' show ReaderTestApp;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  InitialBinding.dependencies();
  runApp(const ReaderTestApp());
}
