import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
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
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  final TcpService _tcpService = TcpService();

  File? _image;
  RecognizedText? _recognizedText;
  bool _working = false;
  Size _imageSize = Size.zero;
  
  final TextEditingController _ipController = TextEditingController(text: '192.168.1.100');
  final TextEditingController _portController = TextEditingController(text: '5000');

  Future<void> _pickImageAndOcr() async {
    final XFile? picked =
        await _picker.pickImage(source: ImageSource.gallery);

    if (picked == null) return;

    setState(() {
      _working = true;
      _image = File(picked.path);
      _recognizedText = null;
    });

    final inputImage = InputImage.fromFilePath(picked.path);
    final result = await _recognizer.processImage(inputImage);

    _imageSize = await _getImageSize(_image!);

    setState(() {
      _recognizedText = result;
      _working = false;
    });
  }

  Future<Size> _getImageSize(File file) async {
    final image = Image.file(file);
    final completer = Completer<Size>();
    image.image.resolve(const ImageConfiguration()).addListener(
      ImageStreamListener((info, _) {
        completer.complete(
          Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          ),
        );
      }),
    );
    return completer.future;
  }

  @override
  void dispose() {
    _recognizer.close();
    _tcpService.dispose();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OCR ảnh từ Gallery'),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo),
            onPressed: _working ? null : _pickImageAndOcr,
          )
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

  Widget _buildImageView() {
    if (_image == null) {
      return const Center(
        child: Text('Nhấn icon ảnh để chọn ảnh OCR'),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Image.file(
            _image!,
            fit: BoxFit.contain,
          ),
        ),
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
          const Center(
            child: CircularProgressIndicator(),
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
                _recognizedText?.text ?? '',
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
              onPressed: (_recognizedText?.text.isNotEmpty ?? false) && _tcpService.isConnected
                  ? () => _tcpService.sendText(_recognizedText!.text)
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
                      color: status.contains('❌')
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

  OcrPainter({
    required this.recognizedText,
    required this.imageSize,
  });

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
