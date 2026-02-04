import 'dart:io';
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'tcp_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final cameras = await availableCameras();

  runApp(MyApp(cameras: cameras));
}

// ================= APP ROOT =================
class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const MyApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: CameraOcrPage(cameras: cameras),
    );
  }
}

// ================= CAMERA OCR PAGE =================
class CameraOcrPage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const CameraOcrPage({super.key, required this.cameras});

  @override
  State<CameraOcrPage> createState() => _CameraOcrPageState();
}

class _CameraOcrPageState extends State<CameraOcrPage>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );
  final BarcodeScanner _barcodeScanner = BarcodeScanner(
    formats: [BarcodeFormat.qrCode],
  );
  final TcpService _tcpService = TcpService();

  File? _capturedImage;
  File? _processedImage;
  RecognizedText? _recognizedText;
  List<Barcode> _barcodes = [];
  String _qrText = '';
  bool _working = false;
  bool _isCameraInitialized = false;
  Size _imageSize = Size.zero;

  // Tùy chọn - SẼ ĐƯỢC LƯU
  bool _usePreprocessing = true;
  bool _autoSendAfterOcr = true;
  int _currentCameraIndex = 0;
  ProcessingLevel _processingLevel = ProcessingLevel.balanced;

  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController();

  // SharedPreferences
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _recognizer.close();
    _barcodeScanner.close();
    _tcpService.dispose();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  /// ========== LƯU/TẢI SETTINGS ==========

  Future<void> _loadSettings() async {
    _prefs = await SharedPreferences.getInstance();

    final savedIp = _prefs?.getString('tcp_ip');
    final savedPort = _prefs?.getString('tcp_port');
    final savedPreprocess = _prefs?.getBool('use_preprocessing');
    final savedAutoSend = _prefs?.getBool('auto_send');
    final savedLevelIndex = _prefs?.getInt('processing_level');
    final savedCameraIndex = _prefs?.getInt('camera_index');

    print('📂 Đang tải cài đặt đã lưu...');
    print('  TCP IP: $savedIp');
    print('  TCP Port: $savedPort');
    print('  Preprocessing: $savedPreprocess');
    print('  Auto Send: $savedAutoSend');
    print('  Level Index: $savedLevelIndex');
    print('  Camera Index: $savedCameraIndex');

    setState(() {
      // Load TCP settings
      _ipController.text = savedIp ?? '192.168.1.100';
      _portController.text = savedPort ?? '5000';

      // Load processing settings
      _usePreprocessing = savedPreprocess ?? true;
      _autoSendAfterOcr = savedAutoSend ?? true;

      // Load processing level
      final levelIndex = savedLevelIndex ?? 1; // 1 = balanced
      _processingLevel = ProcessingLevel.values[levelIndex];

      // Load camera index
      _currentCameraIndex = savedCameraIndex ?? 0;
    });

    // Khởi tạo camera sau khi load settings
    _initializeCamera();

    print(
      '✅ Đã tải cài đặt: IP=${_ipController.text}, Port=${_portController.text}, Level=${_processingLevel.name}',
    );
  }

  Future<void> _saveSettings() async {
    if (_prefs == null) {
      print('❌ SharedPreferences chưa được khởi tạo');
      return;
    }

    try {
      // Save TCP settings
      final ipSaved = await _prefs!.setString('tcp_ip', _ipController.text);
      final portSaved = await _prefs!.setString(
        'tcp_port',
        _portController.text,
      );

      // Save processing settings
      final preprocSaved = await _prefs!.setBool(
        'use_preprocessing',
        _usePreprocessing,
      );
      final autoSendSaved = await _prefs!.setBool(
        'auto_send',
        _autoSendAfterOcr,
      );

      // Save processing level
      final levelSaved = await _prefs!.setInt(
        'processing_level',
        _processingLevel.index,
      );

      // Save camera index
      final cameraSaved = await _prefs!.setInt(
        'camera_index',
        _currentCameraIndex,
      );

      print(
        '💾 Đã lưu cài đặt thành công: '
        'IP=${_ipController.text}, '
        'Port=${_portController.text}, '
        'Level=${_processingLevel.name}, '
        'Preprocess=$_usePreprocessing, '
        'AutoSend=$_autoSendAfterOcr',
      );
      print(
        '✓ Kết quả: '
        'IP=$ipSaved, Port=$portSaved, Preprocess=$preprocSaved, '
        'AutoSend=$autoSendSaved, Level=$levelSaved, Camera=$cameraSaved',
      );
    } catch (e) {
      print('❌ Lỗi lưu cài đặt: $e');
    }
  }

  /// ========== CAMERA ==========

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      _showError('Không tìm thấy camera');
      return;
    }

    // Đảm bảo camera index hợp lệ
    if (_currentCameraIndex >= widget.cameras.length) {
      _currentCameraIndex = 0;
    }

    try {
      final camera = widget.cameras[_currentCameraIndex];

      _cameraController = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _cameraController!.initialize();

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
    } catch (e) {
      _showError('Lỗi khởi tạo camera: $e');
    }
  }

  Future<void> _switchCamera() async {
    if (widget.cameras.length < 2) return;

    setState(() {
      _isCameraInitialized = false;
      _currentCameraIndex = (_currentCameraIndex + 1) % widget.cameras.length;
    });

    await _cameraController?.dispose();
    await _initializeCamera();

    // Lưu camera index mới
    await _saveSettings();
  }

  /// ========== OCR PROCESSING ==========

  Future<void> _captureAndProcess() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      _showError('Camera chưa sẵn sàng');
      return;
    }

    if (_working) return;

    setState(() {
      _working = true;
    });

    final startTime = DateTime.now();

    try {
      final XFile image = await _cameraController!.takePicture();

      setState(() {
        _capturedImage = File(image.path);
        _processedImage = null;
        _recognizedText = null;
        _barcodes = [];
        _qrText = '';
      });

      String imagePath = image.path;

      if (_usePreprocessing) {
        imagePath = await _preprocessImageFast(image.path);
        _processedImage = File(imagePath);
      }

      final inputImage = InputImage.fromFilePath(imagePath);
      final result = await _recognizer.processImage(inputImage);

      final inputImageQR = InputImage.fromFilePath(image.path);
      final barcodes = await _barcodeScanner.processImage(inputImageQR);

      final qrText = barcodes
          .map((b) => b.rawValue)
          .where((value) => value != null && value!.trim().isNotEmpty)
          .map((value) => value!.trim())
          .toList();

      _imageSize = await _getImageSize(_capturedImage!);

      setState(() {
        _recognizedText = result;
        _barcodes = barcodes;
        _qrText = qrText.join('\n');
        _working = false;
      });

      if (_autoSendAfterOcr &&
          _tcpService.isConnected &&
          _combinedText.isNotEmpty) {
        await _tcpService.sendText(_combinedText);
        _showSuccess('Đã gửi text qua TCP');
      }

      final duration = DateTime.now().difference(startTime);
      print('⏱️ Tổng thời gian xử lý: ${duration.inMilliseconds}ms');
    } catch (e) {
      setState(() {
        _working = false;
      });
      _showError('Lỗi xử lý: $e');
    }
  }

  Future<String> _preprocessImageFast(String imagePath) async {
    final preprocessStart = DateTime.now();

    final processedPath = await compute(
      _processImageInIsolate,
      ImageProcessingParams(imagePath: imagePath, level: _processingLevel),
    );

    final duration = DateTime.now().difference(preprocessStart);
    print('⏱️ Preprocessing: ${duration.inMilliseconds}ms');

    return processedPath;
  }

  Future<Size> _getImageSize(File file) async {
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return Size.zero;
    return Size(image.width.toDouble(), image.height.toDouble());
  }

  String get _combinedText {
    final ocr = _recognizedText?.text.trim() ?? '';
    final qr = _qrText.trim();
    if (ocr.isEmpty && qr.isEmpty) return '';
    if (qr.isEmpty) return ocr;
    if (ocr.isEmpty) return 'QR:\n$qr';
    return '$ocr\n\nQR:\n$qr';
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _showSettings() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cài đặt'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: const Text('Xử lý ảnh trước'),
                  subtitle: Text(_processingLevel.description),
                  value: _usePreprocessing,
                  onChanged: (value) async {
                    setDialogState(() => _usePreprocessing = value);
                    setState(() => _usePreprocessing = value);
                    print('🔄 Thay đổi preprocessing thành: $value');
                    await _saveSettings();
                  },
                ),
                if (_usePreprocessing)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Cấp độ xử lý:',
                          style: TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        SegmentedButton<ProcessingLevel>(
                          segments: ProcessingLevel.values.map((level) {
                            return ButtonSegment(
                              value: level,
                              label: Text(
                                level.name,
                                style: const TextStyle(fontSize: 11),
                              ),
                            );
                          }).toList(),
                          selected: {_processingLevel},
                          onSelectionChanged:
                              (Set<ProcessingLevel> selection) async {
                                setDialogState(
                                  () => _processingLevel = selection.first,
                                );
                                setState(
                                  () => _processingLevel = selection.first,
                                );
                                print(
                                  '🔄 Thay đổi processing level thành: ${selection.first.name}',
                                );
                                await _saveSettings();
                              },
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('Tự động gửi'),
                  subtitle: const Text('Gửi TCP sau khi OCR'),
                  value: _autoSendAfterOcr,
                  onChanged: (value) async {
                    setDialogState(() => _autoSendAfterOcr = value);
                    setState(() => _autoSendAfterOcr = value);
                    print('🔄 Thay đổi auto send thành: $value');
                    await _saveSettings();
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text(
                    'Cài đặt được lưu tự động',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  void _clearCapture() {
    setState(() {
      _capturedImage = null;
      _processedImage = null;
      _recognizedText = null;
      _barcodes = [];
      _qrText = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Camera OCR + TCP'),
        backgroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettings,
          ),
          if (widget.cameras.length > 1)
            IconButton(
              icon: const Icon(Icons.flip_camera_android),
              onPressed: _working ? null : _switchCamera,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildCameraOrImageView()),
          _buildTcpConnectionPanel(),
          _buildTextPanel(),
        ],
      ),
      floatingActionButton: _buildFloatingButtons(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Widget _buildCameraOrImageView() {
    if (_capturedImage != null) {
      final displayImage = _processedImage ?? _capturedImage!;

      return Stack(
        children: [
          Positioned.fill(child: Image.file(displayImage, fit: BoxFit.contain)),
          if (_recognizedText != null)
            Positioned.fill(
              child: CustomPaint(
                painter: OcrPainter(
                  recognizedText: _recognizedText!,
                  imageSize: _imageSize,
                ),
              ),
            ),
          if (_working)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (_processedImage != null)
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Đã xử lý (${_processingLevel.name})',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: _clearCapture,
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
            ),
          ),
        ],
      );
    }

    if (!_isCameraInitialized || _cameraController == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return CameraPreview(_cameraController!);
  }

  Widget _buildFloatingButtons() {
    if (_capturedImage != null) {
      return const SizedBox.shrink();
    }

    return FloatingActionButton(
      onPressed: _working ? null : _captureAndProcess,
      backgroundColor: Colors.white,
      child: _working
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.camera_alt, color: Colors.black, size: 32),
    );
  }

  Widget _buildTextPanel() {
    return Container(
      height: 200,
      padding: const EdgeInsets.all(12),
      color: Colors.black.withValues(alpha: 0.85),
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                _combinedText.isEmpty ? 'Chụp ảnh để OCR...' : _combinedText,
                style: TextStyle(
                  color: _combinedText.isEmpty ? Colors.grey : Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.send),
                  label: const Text('Gửi text'),
                  onPressed: _combinedText.isNotEmpty && _tcpService.isConnected
                      ? () => _tcpService.sendText(_combinedText)
                      : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTcpConnectionPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.grey[900],
      child: Column(
        spacing: 8,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ipController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'IP',
                    hintStyle: TextStyle(color: Colors.grey),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  enabled: !_tcpService.isConnected,
                  onChanged: (value) {
                    print('🔄 Thay đổi IP thành: $value');
                    _saveSettings();
                  }, // Lưu khi thay đổi
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: _portController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'Port',
                    hintStyle: TextStyle(color: Colors.grey),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  enabled: !_tcpService.isConnected,
                  keyboardType: TextInputType.number,
                  onChanged: (value) {
                    print('🔄 Thay đổi Port thành: $value');
                    _saveSettings();
                  }, // Lưu khi thay đổi
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _tcpService.isConnected
                    ? () {
                        print('❌ Ngắt kết nối TCP');
                        _tcpService.disconnect();
                        setState(() {});
                      }
                    : () async {
                        final ip = _ipController.text;
                        final port = int.tryParse(_portController.text) ?? 5000;
                        print('🔌 Kết nối TCP: IP=$ip, Port=$port');
                        await _tcpService.connect(ip, port);
                        setState(() {});
                        await _saveSettings(); // Lưu sau khi kết nối
                      },
                child: Text(_tcpService.isConnected ? 'Ngắt' : 'Kết nối'),
              ),
            ],
          ),
          SizedBox(
            height: 40,
            child: StreamBuilder<String>(
              stream: _tcpService.statusStream,
              builder: (context, snapshot) {
                final status = snapshot.data ?? 'Chưa kết nối';
                return SingleChildScrollView(
                  child: Text(
                    status,
                    style: TextStyle(
                      color: status.contains('✗')
                          ? Colors.red
                          : status.contains('✓')
                          ? Colors.green
                          : Colors.yellow,
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ================= ISOLATE PROCESSING =================

Future<String> _processImageInIsolate(ImageProcessingParams params) async {
  final bytes = await File(params.imagePath).readAsBytes();
  img.Image? image = img.decodeImage(bytes);

  if (image == null) return params.imagePath;

  switch (params.level) {
    case ProcessingLevel.fast:
      image = _processFast(image);
      break;
    case ProcessingLevel.balanced:
      image = _processBalanced(image);
      break;
    case ProcessingLevel.quality:
      image = _processQuality(image);
      break;
  }

  final originalFile = File(params.imagePath);
  final directory = originalFile.parent.path;
  final filename = originalFile.uri.pathSegments.last;
  final nameWithoutExt = filename.substring(0, filename.lastIndexOf('.'));
  final extension = filename.substring(filename.lastIndexOf('.'));

  final processedPath = '$directory/${nameWithoutExt}_processed$extension';
  final processedFile = File(processedPath);
  await processedFile.writeAsBytes(img.encodeJpg(image, quality: 90));

  return processedPath;
}

img.Image _processFast(img.Image image) {
  image = img.grayscale(image);
  image = img.adjustColor(image, contrast: 1.2);
  return image;
}

img.Image _processBalanced(img.Image image) {
  image = img.grayscale(image);
  image = img.adjustColor(image, contrast: 1.3);

  const threshold = 128;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      final gray = pixel.r;
      final newValue = gray > threshold ? 255 : 0;
      image.setPixelRgba(x, y, newValue, newValue, newValue, 255);
    }
  }

  return image;
}

img.Image _processQuality(img.Image image) {
  if (image.width < 1000) {
    final scale = 1500 / image.width;
    image = img.copyResize(
      image,
      width: (image.width * scale).toInt(),
      height: (image.height * scale).toInt(),
      interpolation: img.Interpolation.cubic,
    );
  }

  image = img.grayscale(image);
  image = img.adjustColor(image, contrast: 1.3);
  image = img.gaussianBlur(image, radius: 1);

  final threshold = _calculateOtsuThreshold(image);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      final gray = pixel.r;
      final newValue = gray > threshold ? 255 : 0;
      image.setPixelRgba(x, y, newValue, newValue, newValue, 255);
    }
  }

  image = img.gaussianBlur(image, radius: 1);

  return image;
}

int _calculateOtsuThreshold(img.Image image) {
  final histogram = List<int>.filled(256, 0);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      histogram[pixel.r.toInt()]++;
    }
  }

  final total = image.width * image.height;
  double sum = 0;
  for (var i = 0; i < 256; i++) {
    sum += i * histogram[i];
  }

  double sumB = 0;
  int wB = 0;
  int wF;
  double varMax = 0;
  int threshold = 0;

  for (var t = 0; t < 256; t++) {
    wB += histogram[t];
    if (wB == 0) continue;

    wF = total - wB;
    if (wF == 0) break;

    sumB += t * histogram[t];

    final mB = sumB / wB;
    final mF = (sum - sumB) / wF;

    final varBetween = wB * wF * (mB - mF) * (mB - mF);

    if (varBetween > varMax) {
      varMax = varBetween;
      threshold = t;
    }
  }

  return threshold;
}

// ================= DATA CLASSES =================

class ImageProcessingParams {
  final String imagePath;
  final ProcessingLevel level;

  ImageProcessingParams({required this.imagePath, required this.level});
}

enum ProcessingLevel {
  fast('Nhanh', 'Chỉ grayscale + contrast (~200ms)'),
  balanced('Cân bằng', 'Thêm threshold cố định (~500ms)'),
  quality('Chất lượng', 'Full pipeline với Otsu (~1-2s)');

  final String name;
  final String description;

  const ProcessingLevel(this.name, this.description);
}

// ================= OCR PAINTER =================
class OcrPainter extends CustomPainter {
  final RecognizedText recognizedText;
  final Size imageSize;

  OcrPainter({required this.recognizedText, required this.imageSize});

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize == Size.zero) return;

    final paint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final rect = Rect.fromLTRB(
          line.boundingBox.left * scaleX,
          line.boundingBox.top * scaleY,
          line.boundingBox.right * scaleX,
          line.boundingBox.bottom * scaleY,
        );
        canvas.drawRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
