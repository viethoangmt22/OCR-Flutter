import 'dart:io';
import 'dart:async';

class TcpService {
  Socket? _socket;
  String? _serverIp;
  int? _serverPort;
  bool _isConnected = false;
  
  final StreamController<String> _statusStream = StreamController<String>.broadcast();
  
  Stream<String> get statusStream => _statusStream.stream;
  bool get isConnected => _isConnected;
  
  /// Kết nối đến server TCP/IP
  Future<bool> connect(String ip, int port, {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      _serverIp = ip;
      _serverPort = port;
      
      _statusStream.add('Đang kết nối tới $ip:$port...');
      
      _socket = await Socket.connect(ip, port, timeout: timeout);
      _isConnected = true;
      _statusStream.add('✓ Kết nối thành công!');
      
      // Lắng nghe dữ liệu từ server
      _socket!.listen(
        (List<int> event) {
          final data = String.fromCharCodes(event);
          _statusStream.add('Server gửi: $data');
        },
        onError: (error) {
          _statusStream.add('❌ Lỗi: $error');
          _isConnected = false;
        },
        onDone: () {
          _statusStream.add('⚠️ Ngắt kết nối');
          _isConnected = false;
        },
      );
      
      return true;
    } catch (e) {
      _isConnected = false;
      _statusStream.add('❌ Không thể kết nối: $e');
      return false;
    }
  }
  
  /// Gửi text đến server
  Future<bool> sendText(String text) async {
    if (!_isConnected || _socket == null) {
      _statusStream.add('❌ Chưa kết nối');
      return false;
    }
    
    try {
      _socket!.write('$text\n');
      await _socket!.flush();
      _statusStream.add('✓ Gửi thành công: ${text.length} ký tự');
      return true;
    } catch (e) {
      _statusStream.add('❌ Lỗi gửi: $e');
      _isConnected = false;
      return false;
    }
  }
  
  /// Ngắt kết nối
  Future<void> disconnect() async {
    try {
      await _socket?.close();
      _isConnected = false;
      _statusStream.add('⚠️ Đã ngắt kết nối');
    } catch (e) {
      _statusStream.add('❌ Lỗi ngắt kết nối: $e');
    }
  }
  
  void dispose() {
    disconnect();
    _statusStream.close();
  }
}
