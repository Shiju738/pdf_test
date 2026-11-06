import 'package:go_router/go_router.dart';

import '../../modules/home/controllers/home_controller.dart';
import '../../modules/home/views/home_view.dart';
import '../../modules/reader/controllers/reader_controller.dart';
import '../../modules/reader/reader_args.dart';
import '../../modules/reader/views/reader_view.dart';
import 'app_routes.dart';
import 'controller_scope.dart';

abstract final class AppRouter {
  static final router = GoRouter(
    initialLocation: AppRoutes.homePath,
    routes: [
      GoRoute(
        name: AppRoutes.home,
        path: AppRoutes.homePath,
        builder: (context, state) => ControllerScope<HomeController>(
          create: HomeController.new,
          child: const HomeView(),
        ),
      ),
      GoRoute(
        name: AppRoutes.reader,
        path: AppRoutes.readerPath,
        // The reader needs live objects (the open chunk source), so it is
        // reached only by a push with ReaderArgs as `extra`, never by a link.
        redirect: (context, state) =>
            state.extra is ReaderArgs ? null : AppRoutes.homePath,
        builder: (context, state) => ControllerScope<ReaderController>(
          create: () => ReaderController(state.extra! as ReaderArgs),
          child: const ReaderView(),
        ),
      ),
    ],
  );
}
