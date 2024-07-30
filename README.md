# Script setup  openVPN on ubuntu server 22.04 LTS.
#### Chuẩn bị 1 VPS, Cloud server ubuntu 22.04 LTS.
1. **SSH vào VPS bằng terminal hoặc các phần mềm chuyên dụng: ssh user@you-ip**
2. **Cập nhật hệ thống:**
   - **Lệnh**:
     ```bash
     sudo apt update && sudo apt upgrade -y && sudo apt full-upgrade -y && sudo apt autoremove -y
     ```
3. **Script cài đặt:**
   - **Lệnh**:
     ```bash
     sudo apt-get install curl -y
     ```
     ```bash
     curl -O https://raw.githubusercontent.com/quangtrangvn/openVPN/main/openvpn-install.sh
     ``
   Cấp quyền thực thi cho Script:
    - **Lệnh**:
     ```bash
     chmod +x openvpn-install.sh
     ```
   Chạy Script:
   - **Lệnh**:
     ```bash
     sudo ./openvpn-install.sh
     ```
   Script Allow multiple clients (kết nối đồng thời), nếu muốn set 1 giấy phép chỉ cho  phép 1 khách hàng duy nhất bạn bỏ xóa bỏ code "duplicate-cn" >> /etc/openvpn/server.conf
   khởi động lại dịch vụ:
   - **Lệnh**:
     ```bash
     systemctl restart openvpn-server@server
     ```
Chú ý:
- Script sẽ tự động lấy địa chỉ IP công khai của máy chủ và điền vào file cấu hình client.
- Đảm bảo rằng máy chủ của bạn có kết nối Internet để script có thể hoạt động đúng cách.
- File cấu hình client sẽ được tạo tại /etc/openvpn/ hoặc /etc/openvpn/easy-rsa/pki/inline Bạn có thể copy file này sang thiết bị client và import vào ứng dụng WireGuard.
- Liên hệ https://t.me/quangtrangvn or mail: ad@networkz.vn tôi sẽ giúp bạn nếu rảnh (không thu phí).
# Chúc các bạn thành công.
   
  
     

