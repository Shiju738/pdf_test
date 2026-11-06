import 'package:flutter/material.dart';

import 'routes/app_router.dart';
import 'theme/app_theme.dart';

class ReaderTestApp extends StatelessWidget {
  const ReaderTestApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Secure PDF reader test',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    routerConfig: AppRouter.router,
  );
}
