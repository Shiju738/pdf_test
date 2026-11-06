import 'package:flutter/material.dart';

import 'src/home_page.dart';

void main() => runApp(const ReaderTestApp());

class ReaderTestApp extends StatelessWidget {
  const ReaderTestApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Secure PDF reader test',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const HomePage(),
  );
}
