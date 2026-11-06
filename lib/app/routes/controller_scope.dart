import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// Ties a GetX controller's life to a route's screen.
///
/// go_router builds screens itself, so GetX's own route bindings never run.
/// This puts the controller when the screen first appears and deletes it
/// (which calls [GetxController.onClose]) when the screen goes away. The view
/// below it finds the controller with `Get.find` / `GetView`.
class ControllerScope<T extends GetxController> extends StatefulWidget {
  const ControllerScope({super.key, required this.create, required this.child});

  final T Function() create;
  final Widget child;

  @override
  State<ControllerScope<T>> createState() => _ControllerScopeState<T>();
}

class _ControllerScopeState<T extends GetxController>
    extends State<ControllerScope<T>> {
  @override
  void initState() {
    super.initState();
    Get.put<T>(widget.create());
  }

  @override
  void dispose() {
    Get.delete<T>();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
