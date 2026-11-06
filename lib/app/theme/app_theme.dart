import 'package:flutter/material.dart';

abstract final class AppTheme {
  static ThemeData get light =>
      ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true);
}
