# CLAUDE.md

Secure PDF reader test app (Flutter 3.41.6, run with `fvm flutter`). It makes an RSA key pair on the device, sends the public key to the backend, unwraps the PDF's AES key and streams/decrypts chunks into **pdfrx**. See README.md for the backend side.

## Architecture: MVC with GetX + go_router

- **Model** – plain Dart data classes in `lib/data/models/`. No Flutter, no GetX.
- **View** – widgets in `lib/modules/<feature>/views/` and `widgets/`. A view `extends GetView<XController>`, reads state with `Obx(...)` and calls controller methods. No business logic, no `setState` for app state.
- **Controller** – `lib/modules/<feature>/controllers/`, `extends GetxController`. Holds reactive state (`.obs`, `Rxn<T>`), runs the flow, talks to services and navigates. Clean up in `onClose()`.
- **Services** – `lib/data/services/`: feature APIs, storage, the chunk source. Registered once in `InitialBinding` and taken with `Get.find()` (constructor parameters stay optional so tests can pass fakes).
- **Navigation** – go_router only. Do **not** use `Get.to`, `Get.toNamed`, `GetMaterialApp` or GetX route bindings. The app uses `MaterialApp.router(routerConfig: AppRouter.router)`.
- **Controller life** – every route wraps its view in `ControllerScope<T>(create: ..., child: View())` (`lib/app/routes/controller_scope.dart`). It `Get.put`s the controller when the screen appears and `Get.delete`s it (→ `onClose`) when it goes away.

## Folder structure

```
lib/
├── main.dart                     # InitialBinding.dependencies() + runApp
├── app/
│   ├── app.dart                  # ReaderTestApp (MaterialApp.router)
│   ├── bindings/initial_binding.dart  # app-wide services (permanent Get.put)
│   ├── routes/
│   │   ├── app_routes.dart       # route names + paths (constants)
│   │   ├── app_router.dart       # GoRouter config
│   │   └── controller_scope.dart # ties a GetxController to a route
│   └── theme/app_theme.dart
├── core/                         # app-agnostic helpers
│   ├── crypto/                   # der.dart, chunk_cipher.dart (AES-GCM)
│   ├── network/
│   │   ├── api_service.dart      # the common Dio API service (all HTTP)
│   │   ├── api_exception.dart    # ApiException, NetworkException
│   │   └── api_log_interceptor.dart  # debug-only API call log
│   └── utils/format.dart
├── data/
│   ├── models/                   # file_layout, pdf_access, reader_key
│   └── services/                 # reader_api, reader_key_store, chunk_source
└── modules/                      # one folder per feature/screen
    ├── home/
    │   ├── controllers/home_controller.dart
    │   └── views/home_view.dart
    └── reader/
        ├── reader_args.dart      # passed as go_router `extra`
        ├── controllers/reader_controller.dart
        ├── views/reader_view.dart
        └── widgets/              # pdf_pane, fetch_progress, reader_failure
```

## Adding a screen

1. `lib/modules/<name>/controllers/<name>_controller.dart`: `class XController extends GetxController`.
2. `lib/modules/<name>/views/<name>_view.dart`: `class XView extends GetView<XController>`.
3. Add the name/path to `AppRoutes`, and a `GoRoute` in `AppRouter` whose builder returns `ControllerScope<XController>(create: XController.new, child: const XView())`.
4. Navigate with `context.pushNamed(AppRoutes.x)` from a view, or `AppRouter.router.pushNamed(...)` from a controller. Live objects go in `extra` as a typed args class (see `ReaderArgs`).

## Rules that matter here

- **pdfrx viewer is built once** (`PdfPane.initState`). Never rebuild `PdfViewer` from an `Obx`; it would reopen the document.
- **ChunkSource ownership**: once `ReaderArgs` is pushed, the reader owns the source. `ReaderController.onClose` calls `source.leave()`, and pdfrx's `onDispose` calls `source.dispose()`. Never dispose it earlier: PDFium may still be reading.
- **Chunks on the device** (`ChunkStore`, `lib/data/services/chunk_store.dart`): fetched chunks are saved **still encrypted** in the OS cache folder, one folder per stream path + file version (the query/token is not part of the key), pruned to 512 MB. `ChunkSource` reads them before going to the network and saves a chunk only after it decrypted. Never store decrypted chunks or the file key.
- Widget keys (`keyStatus`, `accessUrl`, `openPdf`, `viewerReady`, `pageNumber`, `fetched`, `pageSlider`, `failedRead`, …) are used by `integration_test/app_test.dart`. Keep them.
- **Always name the type in `Get.find<T>()`.** A bare `Get.find()` takes its type from where it's used: passed into a parameter of type `T?`, it looks up `T?`, which isn't registered, and the app crashes at start-up.
- Tests that pump `ReaderTestApp` directly must call `InitialBinding.dependencies()` first.

## API calls: Dio through the common `ApiService`

All HTTP goes through **`ApiService`** (`lib/core/network/api_service.dart`), a wrapper around one shared **Dio** instance. Do not use `package:http`, `HttpClient`, or a new `Dio()` anywhere else.

- **One instance**: `InitialBinding` registers `ApiService` (permanent). Feature services take it in their constructor: `ReaderApi(Get.find<ApiService>())`.
- **Feature services stay thin**: a class per backend area in `lib/data/services/` (like `ReaderApi`). It builds the URL, calls `getJson` / `postJson` / `getBytes` (or `send<T>` for anything else), and turns the JSON into a model in `lib/data/models/` (`Model.fromJson`). No Dio types, status checks or try/catch for HTTP there.
- **Errors**: `ApiService` only returns 2xx answers. Anything else is thrown as one of two types, so callers never see a `DioException`:
  - `ApiException(status, code, message)`: the server answered and refused. `code` and `message` come from its `{"code", "detail"}` body. `mayPass` is true for 5xx, 429 and `source_unavailable`.
  - `NetworkException(message)`: no answer (timeout, no connection). Its message is readable, for example "host did not answer in time.", and is safe to show on screen.
  - `isTemporaryApiError(error)` tells whether a retry may help. ChunkSource uses it, via `ReaderApi.isTemporary`.
- **Timeouts**: connect 15 s, send and receive 30 s, set once in `ApiService`. Pass different values to its constructor rather than per call.
- **Retries** belong to the caller (ChunkSource retries chunk fetches). Don't add a retry interceptor: it would retry refusals and run twice alongside ChunkSource's own retry.
- **Logging**: `ApiLogInterceptor` prints `[API #n] → METHOD url`, the body, and `← status size · ms` (or `✗ type`) in debug builds only. Key fields (`ApiLogInterceptor.keyFields`) are shortened, and URL values named like token, sig or key are hidden, including URLs inside JSON. Add any new secret JSON field to `keyFields`. Turn the log off in tests with `ApiLogInterceptor.enabled = false`.
- **Tests**: give the service a Dio with a fake adapter: `ApiService(dio: Dio()..httpClientAdapter = FakeHttpAdapter(...))` (`test/support/fake_http_adapter.dart`). See `test/api_service_test.dart`.

### Adding an endpoint

```dart
// lib/data/services/books_api.dart
class BooksApi {
  BooksApi([ApiService? api]) : _api = api ?? ApiService();
  final ApiService _api;

  Future<Book> book(Uri baseUrl, int id) async =>
      Book.fromJson(await _api.getJson(baseUrl.resolve('books/$id/')));
}
```

Then register it in `InitialBinding` with `Get.put<BooksApi>(BooksApi(Get.find<ApiService>()), permanent: true)`, and use `Get.find<BooksApi>()` in a controller.

## Reading speed (a jump to a page far into the book)

PDFium finds page N by walking the page tree, loading every page object before it, and those usually sit between the pages' contents. So a jump misses chunk after chunk **in order**, each one a round trip followed by a decrypt. Two things keep this fast; don't undo them:

- **Native AES-GCM** (`ChunkCipher.platformAes`, via `cryptography_flutter`): about 8× faster than pure Dart on iOS. It runs on the main isolate (the plugin is only there). The pure-Dart cipher in a background isolate is only the fallback, for tests and desktop.
- **Adaptive read-ahead** (`ChunkSource.maxReadAhead`, default 8): when misses run in order, the next chunks are fetched in a **separate, concurrent** request (1, 2, 4 … chunks ahead). Never merge them into the request for the chunk being waited for: that chunk would then wait for the extras to arrive and be decrypted.
- **Jump hint** (`ChunkSource.prepareJump(page, pageCount)`): `ReaderController` calls it when the slider's thumb rests for 150 ms during a drag, when the slider is released, and when a scroll skips more than 2 pages. It fetches the chunks where the page probably is (pages assumed evenly spread: `chunkOfPage`) before PDFium asks. If PDFium then walks the page tree (2 misses in order), everything up to the target is fetched at once instead of the window growing step by step (`maxJumpAhead`, 16 chunks).
- Read-ahead goes out in pieces of `readAheadPiece` (2) chunks, all at once, so the nearest chunk arrives and is decrypted first.
- Over the dev tunnel the limit is bandwidth (about 250–350 KB/s, so 0.7–1.4 s per 256 KB chunk), not the app. A jump costs roughly the download time of the 1–2 chunks that hold the page. Smaller chunks on the server, or a faster host, are what would help there.
- Measure before and after any change here: `test/jump_benchmark_test.dart` (see its header) and `integration_test/chunk_cipher_test.dart` on a simulator. `integration_test/app_test.dart` prints `AFTER THE JUMP (N ms)` against the real backend. Run it with `--dart-define=NO_JUMP_HINT=true` to compare without the jump hint.

## Commands

```
fvm flutter pub get
fvm flutter analyze
fvm flutter test                                   # unit tests (test/)
fvm flutter test integration_test/app_test.dart -d <device> \
  --dart-define=ACCESS_URL=http://10.0.2.2:8000/api/v1/reader-test/access/
```
