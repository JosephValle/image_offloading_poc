import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

// ---------------------------------------------------------------------------
// Hardcoded image paths as they appear inside the zip.
// Add or remove entries here to change what gets extracted and shown.
// ---------------------------------------------------------------------------
const List<String> kImagePaths = [
  'img1.jpg',
  'img2.jpg',
  'img3.jpg',
  // 'subdir/image3.jpg',
];

// ---------------------------------------------------------------------------
// Image cache singleton — keyed by the same filename strings as kImagePaths.
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
      title: 'Asset Viewer',
      theme: ThemeData.dark(useMaterial3: true),
      home: const LoadingScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Loading screen — download, unzip, decode, then show a button to continue
// ---------------------------------------------------------------------------
class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key});

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  String _status = 'Initialising…';
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final zipPath = '${dir.path}/assets.zip';

      // 1. Download zip (skip if cached)
      if (!File(zipPath).existsSync()) {
        _setStatus('Downloading assets…');
        final response = await http.get(Uri.parse('https://example.com/assets.zip'));
        if (response.statusCode != 200) throw Exception('Download failed: ${response.statusCode}');
        await File(zipPath).writeAsBytes(response.bodyBytes);
      }

      // 2. Extract any images not yet on disk
      final missing = kImagePaths.where((p) => !File('${dir.path}/$p').existsSync()).toList();

      if (missing.isNotEmpty) {
        _setStatus('Extracting…');
        final bytes = await File(zipPath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);

        for (final file in archive) {
          if (!file.isFile) continue;
          if (missing.contains(file.name)) {
            final outPath = '${dir.path}/${file.name}';
            await File(outPath).create(recursive: true);
            await File(outPath).writeAsBytes(file.content as List<int>);
          }
        }
      }

      // 3. Decode all images into GPU-ready ui.Image objects
      _setStatus('Loading images…');
      for (final name in kImagePaths) {
        final path = '${dir.path}/$name';
        ImageCache.instance.images[name] = await _decodeFile(path);
      }

      if (mounted) setState(() => _ready = true);
    } catch (e) {
      _setStatus('Error: $e');
    }
  }

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
            ? ElevatedButton(
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => const ImageScreen(index: 0),
            ),
          ),
          child: const Text('View images'),
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
// Image screen — reads from the singleton by index, no async, no blank frames
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
      appBar: AppBar(title: Text('Image ${index + 1} of ${kImagePaths.length}')),
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
                  child: const Text('Back'),
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
                  child: const Text('Next'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}