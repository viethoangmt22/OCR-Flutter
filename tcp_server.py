import socket
import threading
from datetime import datetime

def start_tcp_server(host='0.0.0.0', port=5000):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(1)
    
    print(f"🚀 Server đang chạy trên {host}:{port}")
    print("Chờ kết nối từ app Flutter...\n")
    
    try:
        while True:
            client_socket, client_address = server.accept()
            print(f"✓ Kết nối từ: {client_address}")
            
            # Xử lý client trong thread riêng
            client_thread = threading.Thread(
                target=handle_client, 
                args=(client_socket, client_address)
            )
            client_thread.daemon = True
            client_thread.start()
    except KeyboardInterrupt:
        print("\n⚠️ Server dừng")
    finally:
        server.close()

def handle_client(client_socket, client_address):
    try:
        while True:
            data = client_socket.recv(4096).decode('utf-8')
            if not data:
                break
            
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            text = data.strip()
            
            print(f"[{timestamp}] {client_address[0]}: {text}")
            
            # Gửi xác nhận về client (tùy chọn)
            client_socket.send(b"OK\n")
            
    except Exception as e:
        print(f"❌ Lỗi: {e}")
    finally:
        client_socket.close()
        print(f"⚠️ Ngắt kết nối: {client_address}")

if __name__ == "__main__":
    start_tcp_server()