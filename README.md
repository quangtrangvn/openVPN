# Cài OpenVPN trên VPS

Hướng dẫn cho Ubuntu Server 22.04. Script cũng có phần nhận diện một số bản Linux khác, nhưng chỉ nên dùng sau khi đã thử trên VPS test. Nếu VPS `spx` đang chạy OpenVPN, **không chạy lại phần cài mới**: hãy dùng menu để tạo thêm client hoặc kiểm tra trạng thái.

## 1. Chuẩn bị

- VPS có quyền `root`/`sudo`, đã bật TUN, có kết nối Internet.
- Trong firewall của nhà cung cấp VPS, mở **UDP 1194** (hoặc cổng/giao thức bạn chọn).
- Giữ phiên SSH hiện tại mở trong lúc cài.

Từ máy tính của bạn, SSH vào VPS (thay địa chỉ IP):

```bash
ssh root@IP_CUA_VPS
```

## 2. Tải và chạy script

Các lệnh dưới đây chạy **trên VPS**:

```bash
sudo apt-get update
sudo apt-get install -y curl
curl -fL https://raw.githubusercontent.com/quangtrangvn/openVPN/main/openvpn-install.sh -o openvpn-install.sh
bash -n openvpn-install.sh
sudo bash openvpn-install.sh
```

Script hiện menu. Nếu đây là VPS chưa cài, chọn **1) Cài OpenVPN**. Bạn có thể nhấn Enter để dùng mặc định: UDP, cổng 1194, tên client `client`. Nếu VPS sau NAT, nhập IP public hoặc tên miền khi script hỏi. Nếu đã cài bằng script này, menu có mục **Tạo thêm file client**, **Kiểm tra server**, và **Repair**. Chỉ dùng Repair khi đã xác định lỗi; Repair sẽ khởi động lại OpenVPN và ngắt client đang kết nối trong chốc lát.

Không chạy script 2024 trên `spx` đang dùng PKI/cấu hình của bản mới: hai bản quản lý file khác nhau. Bản gốc năm 2024 vẫn nằm trong lịch sử Git để tham khảo hoặc thử trên VPS trống.

## 3. Kiểm tra

Trên VPS, chạy lại `sudo bash openvpn-install.sh`, chọn **Kiểm tra server**. Kết quả đúng là service đang chạy, cổng đã mở và có `tun0`. Nếu cài đặt báo lỗi, xem các dòng cuối của log (đừng gửi file `.ovpn` hoặc private key):

```bash
sudo tail -n 40 /var/log/openvpn-installer.log
```

## 4. Tải file client

File mặc định là `/root/client.ovpn`; nếu chọn tên `phone` thì là `/root/phone.ovpn`. File chứa **khóa riêng**, chỉ tải về thiết bị của bạn. Trên **máy tính cá nhân**, chạy (thay IP và tên file):

```bash
scp root@IP_CUA_VPS:/root/client.ovpn .
```

Hoặc dùng WinSCP: kết nối SFTP vào VPS và kéo file từ `/root/` về máy. Import `.ovpn` vào OpenVPN Connect rồi kết nối. Chỉ sau khi thiết bị thực tế kết nối và truy cập Internet qua VPN mới coi là đã kiểm thử hoàn chỉnh.

## 5. Tạo thêm client hoặc sửa lỗi

Chạy lại `sudo bash openvpn-install.sh` trên VPS, chọn **Tạo thêm file client**, đặt tên khác với file cũ, ví dụ `phone`. Script tạo profile mới mà không khởi động lại OpenVPN. Nếu service không chạy, xem log:

```bash
sudo systemctl status openvpn-server@server.service --no-pager
sudo journalctl -u openvpn-server@server.service -n 50 --no-pager
```

Tên unit có thể khác trên Linux khác; xem `/var/lib/openvpn-installer/state.env` để biết unit thực tế, nhưng đừng dán cả file trạng thái lên chat. Đừng dùng `uninstall` để xử lý lỗi cài đặt vì nó xóa PKI và cấu hình mà client cũ đang dùng.
