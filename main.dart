import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image/image.dart' as img;
import 'tcp_service.dart';

void main() {
  runApp(const MyApp());
}

// ================= APP ROOT =================
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: OcrFromGalleryPage(),
    );
  }
}

// ================= OCR PAGE =================
class OcrFromGalleryPage extends StatefulWidget {
  const OcrFromGalleryPage({super.key});

  @override
  State<OcrFromGalleryPage> createState() => _OcrFromGalleryPageState();
}

class _OcrFromGalleryPageState extends State<OcrFromGalleryPage> {
  final ImagePicker _picker = ImagePicker();
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );
  final BarcodeScanner _barcodeScanner = BarcodeScanner(
    formats: [BarcodeFormat.qrCode],
  );
  final TcpService _tcpService = TcpService();

  File? _image;
  File? _processedImage;
  RecognizedText? _recognizedText;
  List<Barcode> _barcodes = [];
  String _qrText = '';
  bool _working = false;
  Size _imageSize = Size.zero;

  // Tùy chọn xử lý ảnh
  bool _usePreprocessing = true;
  bool _useMultipleAttempts = true;

  final TextEditingController _ipController = TextEditingController(
    text: '192.168.1.100',
  );
  final TextEditingController _portController = TextEditingController(
    text: '5000',
  );

  Future<void> _pickImageAndOcr() async {
    final XFile? picked = await _picker.pickImage(source: ImageSource.gallery);

    if (picked == null) return;

    setState(() {
      _working = true;
      _image = File(picked.path);
      _processedImage = null;
      _recognizedText = null;
      _barcodes = [];
      _qrText = '';
    });

    try {
      String imagePath = picked.path;

      // Xử lý ảnh trước khi OCR nếu được bật
      if (_usePreprocessing) {
        imagePath = await _preprocessImage(picked.path);
        _processedImage = File(imagePath);
      }

      RecognizedText result;

      if (_useMultipleAttempts) {
        // Thử nhiều cấu hình khác nhau và chọn kết quả tốt nhất
        result = await _ocrWithMultipleAttempts(picked.path);
      } else {
        final inputImage = InputImage.fromFilePath(imagePath);
        result = await _recognizer.processImage(inputImage);
      }

      // Quét QR code
      final inputImage = InputImage.fromFilePath(picked.path);
      final barcodes = await _barcodeScanner.processImage(inputImage);

      final qrText = barcodes
          .map((b) => b.rawValue)
          .where((value) => value != null && value!.trim().isNotEmpty)
          .map((value) => value!.trim())
          .toList();

      _imageSize = await _getImageSize(_image!);

      setState(() {
        _recognizedText = result;
        _barcodes = barcodes;
        _qrText = qrText.join('\n');
        _working = false;
      });
    } catch (e) {
      setState(() {
        _working = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Lỗi xử lý: $e')));
      }
    }
  }

  /// Xử lý ảnh để cải thiện OCR
  Future<String> _preprocessImage(String imagePath) async {
    final bytes = await File(imagePath).readAsBytes();
    img.Image? image = img.decodeImage(bytes);

    if (image == null) return imagePath;

    // 1. Tăng kích thước nếu ảnh quá nhỏ
    if (image.width < 1000) {
      final scale = 1500 / image.width;
      image = img.copyResize(
        image,
        width: (image.width * scale).toInt(),
        height: (image.height * scale).toInt(),
        interpolation: img.Interpolation.cubic,
      );
    }

    // 2. Chuyển sang grayscale
    image = img.grayscale(image);

    // 3. Tăng độ tương phản
    image = img.adjustColor(image, contrast: 1.3);

    // 4. Tăng độ sắc nét
    image = img.gaussianBlur(image, radius: 1);

    // 5. Áp dụng ngưỡng (thresholding) để tạo ảnh đen trắng rõ ràng
    // Sử dụng Otsu's method hoặc adaptive threshold
    image = _applyAdaptiveThreshold(image);

    // 6. Giảm nhiễu
    image = img.gaussianBlur(image, radius: 1);

    // Lưu ảnh đã xử lý
    final processedPath = imagePath.replaceAll('.', '_processed.');
    final processedFile = File(processedPath);
    await processedFile.writeAsBytes(img.encodeJpg(image, quality: 95));

    return processedPath;
  }

  /// Áp dụng adaptive threshold để tạo ảnh đen trắng rõ ràng
  img.Image _applyAdaptiveThreshold(img.Image image) {
    final threshold = _calculateOtsuThreshold(image);

    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        final gray = pixel.r; // Đã là grayscale nên r=g=b

        // Áp dụng ngưỡng
        final newValue = gray > threshold ? 255 : 0;
        image.setPixelRgba(x, y, newValue, newValue, newValue, 255);
      }
    }

    return image;
  }

  /// Tính ngưỡng Otsu
  int _calculateOtsuThreshold(img.Image image) {
    // Tạo histogram
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

  /// Thử OCR với nhiều cấu hình khác nhau
  Future<RecognizedText> _ocrWithMultipleAttempts(String imagePath) async {
    final results = <RecognizedText>[];

    // Thử 1: Ảnh gốc
    final original = InputImage.fromFilePath(imagePath);
    results.add(await _recognizer.processImage(original));

    // Thử 2: Ảnh đã xử lý
    final processedPath = await _preprocessImage(imagePath);
    final processed = InputImage.fromFilePath(processedPath);
    results.add(await _recognizer.processImage(processed));

    // Thử 3: Ảnh với độ sáng tăng
    final brightened = await _adjustBrightness(imagePath, 1.2);
    final bright = InputImage.fromFilePath(brightened);
    results.add(await _recognizer.processImage(bright));

    // Chọn kết quả có nhiều text nhất (độ tin cậy cao hơn)
    results.sort((a, b) => b.text.length.compareTo(a.text.length));

    return results.first;
  }

  /// Điều chỉnh độ sáng
  Future<String> _adjustBrightness(String imagePath, double factor) async {
    final bytes = await File(imagePath).readAsBytes();
    img.Image? image = img.decodeImage(bytes);

    if (image == null) return imagePath;

    image = img.adjustColor(image, brightness: factor);

    final adjustedPath = imagePath.replaceAll('.', '_bright.');
    final adjustedFile = File(adjustedPath);
    await adjustedFile.writeAsBytes(img.encodeJpg(image, quality: 95));

    return adjustedPath;
  }

  Future<Size> _getImageSize(File file) async {
    final image = Image.file(file);
    final completer = Completer<Size>();
    image.image
        .resolve(const ImageConfiguration())
        .addListener(
          ImageStreamListener((info, _) {
            completer.complete(
              Size(info.image.width.toDouble(), info.image.height.toDouble()),
            );
          }),
        );
    return completer.future;
  }

  @override
  void dispose() {
    _recognizer.close();
    _barcodeScanner.close();
    _tcpService.dispose();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  String get _combinedText {
    final ocr = _recognizedText?.text.trim() ?? '';
    final qr = _qrText.trim();
    if (ocr.isEmpty && qr.isEmpty) return '';
    if (qr.isEmpty) return ocr;
    if (ocr.isEmpty) return 'QR:\n$qr';
    return '$ocr\n\nQR:\n$qr';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OCR + QR từ Gallery'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettings,
          ),
          IconButton(
            icon: const Icon(Icons.photo),
            onPressed: _working ? null : _pickImageAndOcr,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildImageView()),
          _buildTcpConnectionPanel(),
          _buildTextPanel(),
        ],
      ),
    );
  }

  void _showSettings() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cài đặt OCR'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('Xử lý ảnh trước'),
                subtitle: const Text('Tăng độ tương phản, làm nét'),
                value: _usePreprocessing,
                onChanged: (value) {
                  setDialogState(() => _usePreprocessing = value);
                  setState(() => _usePreprocessing = value);
                },
              ),
              SwitchListTile(
                title: const Text('Thử nhiều lần'),
                subtitle: const Text('OCR với nhiều cấu hình'),
                value: _useMultipleAttempts,
                onChanged: (value) {
                  setDialogState(() => _useMultipleAttempts = value);
                  setState(() => _useMultipleAttempts = value);
                },
              ),
            ],
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

  Widget _buildImageView() {
    if (_image == null) {
      return const Center(child: Text('Nhấn icon ảnh để chọn ảnh OCR'));
    }

    final displayImage = _processedImage ?? _image!;

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
        if (_working) const Center(child: CircularProgressIndicator()),
        // Hiển thị nhãn cho ảnh gốc/đã xử lý
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
              child: const Text(
                'Ảnh đã xử lý',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTextPanel() {
    return Container(
      height: 220,
      padding: const EdgeInsets.all(12),
      color: Colors.black.withValues(alpha: 0.75),
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                _combinedText,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
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
                  decoration: InputDecoration(
                    hintText: 'IP',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  enabled: !_tcpService.isConnected,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: _portController,
                  decoration: InputDecoration(
                    hintText: 'Port',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  enabled: !_tcpService.isConnected,
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _tcpService.isConnected
                    ? () => _tcpService.disconnect()
                    : () async {
                        final ip = _ipController.text;
                        final port = int.tryParse(_portController.text) ?? 5000;
                        await _tcpService.connect(ip, port);
                        setState(() {});
                      },
                child: Text(_tcpService.isConnected ? 'Ngắt' : 'Kết nối'),
              ),
            ],
          ),
          SizedBox(
            height: 50,
            child: StreamBuilder<String>(
              stream: _tcpService.statusStream,
              builder: (context, snapshot) {
                final status = snapshot.data ?? '';
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
