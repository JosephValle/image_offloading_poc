import "dart:io";
import "dart:typed_data";
import "dart:ui" as ui;

import "package:archive/archive_io.dart";
import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:path_provider/path_provider.dart";

// ---------------------------------------------------------------------------
// CONFIGURATION
//
// kZipUrl     — publicly accessible URL to download assets.zip from.
// kImagePaths — filenames as they appear inside the zip (basename only).
//               Add or remove entries here freely; the rest of the app
//               adapts automatically.
//
// The zip may contain a single top-level folder (e.g. assets/img1.jpg) —
// the app strips any prefix and uses only the basename when writing to disk.
// macOS __MACOSX metadata entries are ignored automatically.
// ---------------------------------------------------------------------------
const String kZipUrl =
    "https://raw.githubusercontent.com/JosephValle/image_offloading_poc/main/assets.zip";

const List<String> kImagePaths = ["img1.jpg", "img2.jpg", "img3.jpg"];

// ---------------------------------------------------------------------------
// ImageCache — singleton that holds every decoded image in memory.
//
// Images are stored as dart:ui Image objects, which are fully decoded,
// GPU-resident bitmaps. Reading them in a widget is synchronous and paints
// on the very first frame — no async work, no blank flicker during navigation.
//
// Populated once on the loading screen; never written to again.
// ---------------------------------------------------------------------------
class ImageCache {
  ImageCache._();
  static final ImageCache instance = ImageCache._();

  final Map<String, ui.Image> images = {};
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Asset Viewer",
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),

      themeMode: ThemeMode.system,
      home: const LoadingScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// LoadingScreen
//
// Performs three sequential steps before allowing the user to proceed:
//
//   1. Download — fetches assets.zip and writes it to the app's documents
//      directory. Skipped on subsequent launches if the file already exists.
//
//   2. Extract — decodes the zip and writes each image file to disk.
//      Skipped per-file if that file already exists (partial re-extraction
//      is supported — only missing files are written).
//
//   3. Decode — reads each image file and fully decodes it into a
//      dart:ui Image via instantiateImageCodec. Stores results in
//      ImageCache.instance.images keyed by filename.
//
// Once all three steps complete, the spinner is replaced by a "View images"
// button. The user taps it to navigate; by that point every image is already
// in memory so ImageScreen renders instantly.
//
// A "Reset & redownload" button is also available once ready, which clears
// the cached zip and image files from disk, clears the in-memory cache, and
// re-runs the prepare pipeline from scratch.
// ---------------------------------------------------------------------------
class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key});

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  String _status = "Initialising…";
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final zipPath = "${dir.path}/assets.zip";

      // Step 1 — Download zip (skip if already cached on disk)
      if (!File(zipPath).existsSync()) {
        _setStatus("Downloading assets…");
        final response = await http.get(Uri.parse(kZipUrl));
        if (response.statusCode != 200) {
          throw Exception("Download failed: ${response.statusCode}");
        }
        await File(zipPath).writeAsBytes(response.bodyBytes);
      }

      // Step 2 — Extract only the files that are not yet on disk
      final missing = kImagePaths
          .where((p) => !File("${dir.path}/$p").existsSync())
          .toList();

      if (missing.isNotEmpty) {
        _setStatus("Extracting…");
        final bytes = await File(zipPath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);

        for (final file in archive) {
          if (!file.isFile) continue;
          if (file.name.startsWith("__MACOSX")) continue;
          // Strip any leading directory prefix (e.g. "assets/img1.jpg" → "img1.jpg")
          final baseName = file.name.split("/").last;
          if (missing.contains(baseName)) {
            await File(
              "${dir.path}/$baseName",
            ).writeAsBytes(file.content as List<int>);
          }
        }
      }

      // Step 3 — Decode all images into GPU-ready ui.Image objects
      _setStatus("Loading images…");
      for (final name in kImagePaths) {
        ImageCache.instance.images[name] = await _decodeFile(
          "${dir.path}/$name",
        );
      }

      if (mounted) setState(() => _ready = true);
    } catch (e) {
      _setStatus("Error: $e");
    }
  }

  Future<void> _reset() async {
    setState(() {
      _ready = false;
      _status = "Resetting…";
    });

    final dir = await getApplicationDocumentsDirectory();

    final zipFile = File("${dir.path}/assets.zip");
    if (zipFile.existsSync()) await zipFile.delete();

    for (final name in kImagePaths) {
      final f = File("${dir.path}/$name");
      if (f.existsSync()) await f.delete();
    }

    ImageCache.instance.images.clear();

    await _prepare();
  }

  /// Reads a file from disk and fully decodes it into a [ui.Image].
  Future<ui.Image> _decodeFile(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _ready
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton(
                    onPressed: () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ImageScreen(index: 0),
                      ),
                    ),
                    child: const Text("View images"),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _reset,
                    child: const Text("Reset & redownload"),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  Text(_status, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ImageScreen
//
// Displays a single image from ImageCache by index into kImagePaths.
// Because the image is already a decoded ui.Image in memory, RawImage
// paints it synchronously on the first frame — there is no loading state.
//
// Next/Back buttons push/pop ImageScreen with index ± 1. The first screen
// hides Back; the last screen hides Next. A "Done" button in the app bar
// returns the user to the LoadingScreen via popUntil.
// ---------------------------------------------------------------------------
class ImageScreen extends StatelessWidget {
  const ImageScreen({super.key, required this.index});

  final int index;

  String get _key => kImagePaths[index];
  ui.Image get _image => ImageCache.instance.images[_key]!;

  @override
  Widget build(BuildContext context) {
    final isFirst = index == 0;
    final isLast = index == kImagePaths.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text("Image ${index + 1} of ${kImagePaths.length}"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const LoadingScreen()),
              (_) => false,
            ),
            child: const Text("Done"),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RawImage(image: _image, fit: BoxFit.contain),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                isFirst
                    ? const SizedBox.shrink()
                    : ElevatedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text("Back"),
                      ),
                isLast
                    ? const SizedBox.shrink()
                    : ElevatedButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ImageScreen(index: index + 1),
                          ),
                        ),
                        child: const Text("Next"),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
