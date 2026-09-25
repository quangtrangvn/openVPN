# OpenVPN Installer đa distro

Installer OpenVPN an toàn, có khả năng chạy lại và quản lý riêng cấu hình, forwarding cùng firewall rule do chính installer tạo.

> Bản hiện tại đã được kiểm thử thực tế trên **Ubuntu Server 22.04 LTS (systemd)**. Các distro khác được hỗ trợ bằng lớp detection/adaptation nhưng vẫn nên thử trên VPS staging trước khi dùng Production.

## Tính năng

- Đọc `/etc/os-release` và dùng `ID`, `ID_LIKE`, `VERSION_ID` để nhận diện distro.
- Tự nhận diện package manager: `apt-get`, `dnf`, `yum`, `pacman`, `apk`, `zypper`.
- Hỗ trợ systemd và OpenRC.
- Tự nhận diện interface outbound từ default route.
- Dùng layout config/service phù hợp với package OpenVPN đã cài.
- Dùng Easy-RSA từ package của distro; không tải bản nhị phân không kiểm soát.
- Tạo CA, certificate server/client và khóa `tls-crypt`.
- Cấu hình NAT/forwarding bằng nftables hoặc iptables với rule riêng, idempotent.
- Lưu baseline trước lần cài đầu tại `/var/lib/openvpn-installer/baseline/`.
- Tạo sysctl riêng tại `/etc/sysctl.d/99-openvpn-installer.conf`.
- Xác minh service, port và `tun0` trước khi báo thành công.
- Không chạy autoremove, không reset firewall và không sửa SSH.

## Distro hỗ trợ

| Family | Distro điển hình | Package manager | Init |
|---|---|---|---|
| Debian | Debian, Ubuntu, Linux Mint | apt-get | systemd |
| RHEL | RHEL, Rocky, AlmaLinux, CentOS Stream, Oracle Linux, Fedora | dnf/yum | systemd |
| Arch | Arch Linux, Manjaro | pacman | systemd |
| Alpine | Alpine Linux | apk | OpenRC |
| openSUSE | Leap, Tumbleweed | zypper | systemd |

Installer dừng với thông báo rõ ràng nếu distro, package manager hoặc init system không được hỗ trợ. RHEL tối giản có thể cần repository cung cấp `easy-rsa`; installer sẽ dừng thay vì tự thêm repository không được duyệt.

## Yêu cầu

- Quyền root.
- TUN device khả dụng tại `/dev/net/tun`.
- Kết nối tới repository package của distro.
- Một IPv4 public hoặc hostname trỏ tới VPS.

## Cài đặt

```bash
git clone https://github.com/quangtrangvn/openVPN.git
cd openVPN
chmod +x openvpn-install.sh
sudo ./openvpn-install.sh install
```

Mặc định:

- Protocol: UDP
- Port: 1194
- VPN subnet: `10.8.0.0/24`
- DNS: Cloudflare
- Client name: `client`

Có thể truyền cấu hình qua biến môi trường:

```bash
sudo ENDPOINT=vpn.example.com PORT=1194 PROTOCOL=udp CLIENT_NAME=laptop ./openvpn-install.sh install
```

Trên Alpine, script tự cài Bash bằng `apk` rồi chạy lại chính nó.

## Repair

Chạy lại an toàn, giữ PKI hiện có và không tạo trùng rule:

```bash
sudo ./openvpn-install.sh repair
```

Baseline của lần cài đầu được giữ nguyên khi repair.

## Uninstall

```bash
sudo ./openvpn-install.sh uninstall
```

Uninstall chỉ dừng service/config, PKI, client profile, sysctl file và firewall rule được ghi nhận bởi installer. Package OpenVPN/Easy-RSA được giữ lại mặc định để tránh xóa dependency dùng chung. Script không chạy autoremove.

## File quan trọng

| File | Mục đích |
|---|---|
| `/etc/openvpn/server/server.conf` | Config phổ biến trên systemd hiện đại |
| `/etc/openvpn/openvpn.conf` | Config OpenRC |
| `/etc/openvpn/pki/` | CA và certificate/key |
| `/etc/openvpn/tls-crypt.key` | Khóa bảo vệ control channel |
| `/root/client.ovpn` | Profile client mặc định |
| `/var/lib/openvpn-installer/state.env` | Trạng thái để repair/uninstall đúng phạm vi |
| `/var/lib/openvpn-installer/baseline/` | Network, service và firewall trước cài đặt |
| `/var/log/openvpn-installer.log` | Log installer |

Đường dẫn config thực tế được lưu trong `state.env` vì layout phụ thuộc package/init system.

## Kiểm tra server

Với systemd:

```bash
systemctl status openvpn-server@server.service
ss -lnup | grep 1194
ip address show tun0
sysctl net.ipv4.ip_forward
```

Xem log:

```bash
journalctl -u openvpn-server@server.service -n 100 --no-pager
```

## Client profile

Profile mặc định nằm tại:

```text
/root/client.ovpn
```

File chứa private key của client. Chỉ tải bằng kênh an toàn như SCP/SFTP và đặt quyền `600`. Không gửi nội dung profile vào chat, log hoặc GitHub.

Ví dụ tải về máy cá nhân:

```bash
scp root@YOUR_SERVER_IP:/root/client.ovpn ./client.ovpn
```

Sau đó import file vào OpenVPN Connect hoặc Tunnelblick để kiểm tra kết nối, IP public và DNS.

## Firewall và forwarding

- Tự chọn nftables nếu có, fallback sang iptables.
- nftables dùng table riêng: `openvpn-installer` và `openvpn-installer_nat`.
- iptables dùng comment `openvpn-installer` và kiểm tra rule trước khi thêm.
- Nếu UFW/firewalld đang active, installer chỉ mở đúng port OpenVPN.
- Không flush/reset ruleset hiện tại.
- NAT chỉ áp dụng cho VPN subnet trên interface outbound đã detect.

## Bảo mật

- Không commit `.ovpn`, private key, certificate client, PKI hoặc secret.
- Không hard-code password/token.
- Mặc định dùng TLS 1.2+, `tls-crypt`, AES-GCM/ChaCha20 và SHA-256.
- Private key và client profile dùng quyền `600`.
- Nên tạo certificate riêng cho từng người hoặc thiết bị.

## Giới hạn

- Chỉ Ubuntu 22.04 đã được kiểm thử end-to-end trong phiên bản hiện tại.
- Tên package/unit có thể thay đổi ở bản distro tương lai; installer sẽ dừng nếu không xác định an toàn.
- Script hiện hỗ trợ IPv4 VPN; không tự bật IPv6 forwarding.
- RHEL tối giản có thể chưa bật repository chứa Easy-RSA.
- Container/VPS không có TUN không thể cài OpenVPN theo cách này.

## Không thuộc phạm vi installer

Installer không sửa SSH, không reboot VPS, không thay đổi proxy/backend ứng dụng, Cloudflare, Telegram hoặc Worker.
