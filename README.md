# OpenVPN Installer đa distro

Script cài OpenVPN cho VPS Linux, tự nhận diện hệ điều hành, package manager, init system, đường dẫn cấu hình và firewall. Script chỉ quản lý các tệp/rule do chính nó tạo; không sửa SSH, không reboot, không chạy autoremove và không reset firewall hiện có.

> Bản hiện tại đã được kiểm thử end-to-end trên **Ubuntu Server 22.04 LTS (systemd)**. Các distro khác có logic hỗ trợ nhưng nên thử trên VPS staging trước khi dùng Production.

## Mục lục

- [Script làm gì](#script-làm-gì)
- [Hệ điều hành hỗ trợ](#hệ-điều-hành-hỗ-trợ)
- [Chuẩn bị](#chuẩn-bị)
- [Cài đặt từng bước](#cài-đặt-từng-bước)
- [Kiểm tra sau cài đặt](#kiểm-tra-sau-cài-đặt)
- [Tải và dùng file client](#tải-và-dùng-file-client)
- [Quản lý client](#quản-lý-client)
- [Repair và gỡ cài đặt](#repair-và-gỡ-cài-đặt)
- [Lỗi thường gặp](#lỗi-thường-gặp)
- [File quan trọng](#file-quan-trọng)
- [Bảo mật và giới hạn](#bảo-mật-và-giới-hạn)

## Script làm gì

- Đọc `/etc/os-release` để nhận diện distro.
- Tự chọn `apt-get`, `dnf`, `yum`, `pacman`, `apk` hoặc `zypper`.
- Hỗ trợ systemd và OpenRC.
- Chờ package manager đang bận tối đa 600 giây; không xóa lock và không kill tiến trình hợp lệ.
- Cài OpenVPN, Easy-RSA và CA certificates từ repository của distro.
- Tạo CA, certificate server/client và khóa `tls-crypt`.
- Tự nhận diện interface Internet từ default route.
- Bật riêng `net.ipv4.ip_forward=1` trong `/etc/sysctl.d/99-openvpn-installer.conf`.
- Tạo NAT/forwarding bằng nftables hoặc iptables; chỉ mở cổng OpenVPN nếu UFW/firewalld đang chạy.
- Lưu baseline trước lần cài đầu tại `/var/lib/openvpn-installer/baseline/`.
- Chỉ báo thành công khi service chạy, UDP/TCP port lắng nghe và `tun0` tồn tại.

## Hệ điều hành hỗ trợ

| Family | Distro điển hình | Package manager | Init |
|---|---|---|---|
| Debian | Debian, Ubuntu, Linux Mint | apt-get | systemd |
| RHEL | RHEL, Rocky, AlmaLinux, CentOS Stream, Oracle Linux, Fedora | dnf/yum | systemd |
| Arch | Arch Linux, Manjaro | pacman | systemd |
| Alpine | Alpine Linux | apk | OpenRC |
| openSUSE | Leap, Tumbleweed | zypper | systemd |

Installer sẽ dừng nếu distro, package manager hoặc init system không được hỗ trợ. RHEL tối giản có thể chưa bật repository chứa `easy-rsa`; script không tự thêm repository ngoài.

## Chuẩn bị

Bạn cần:

1. Một VPS Linux có quyền `root`/`sudo`.
2. TUN device hoạt động tại `/dev/net/tun`.
3. VPS truy cập được repository package của distro và GitHub.
4. Một IPv4 public hoặc hostname trỏ về VPS.
5. Nếu VPS có firewall ngoài (Security Group/Cloud Firewall), mở cổng sẽ dùng, mặc định là **UDP 1194**.

Đăng nhập VPS từ **máy cá nhân**:

```bash
ssh root@YOUR_SERVER_IP
```

Thay `YOUR_SERVER_IP` bằng IP VPS. Nếu đăng nhập bằng user thường, dùng user đó và thêm `sudo` cho các lệnh quản trị.

Kiểm tra TUN trên **VPS**:

```bash
ls -l /dev/net/tun
```

Kết quả đúng là một character device. Nếu báo không tồn tại, bật TUN trong trang quản trị nhà cung cấp VPS trước khi chạy installer.

## Cài đặt từng bước

### 1. Tải source trên VPS

```bash
git clone https://github.com/quangtrangvn/openVPN.git
cd openVPN
chmod +x openvpn-install.sh
```

Nếu repo đã có sẵn, cập nhật nhánh `main`:

```bash
cd openVPN
git switch main
git pull --ff-only
```

### 2. Chọn cấu hình

Mặc định:

- Protocol: `udp`
- Port: `1194`
- VPN subnet: `10.8.0.0/24`
- DNS: `1.1.1.1` và `1.0.0.1`
- Client đầu tiên: `client`

Cài với giá trị mặc định:

```bash
sudo ./openvpn-install.sh install
```

Nếu VPS có private IP hoặc bạn muốn chỉ định hostname/IP public, truyền `ENDPOINT`. Ví dụ:

```bash
sudo ENDPOINT=vpn.example.com PORT=1194 PROTOCOL=udp CLIENT_NAME=laptop ./openvpn-install.sh install
```

Hãy thay:

- `vpn.example.com`: hostname hoặc IPv4 public mà client truy cập được.
- `1194`: cổng muốn dùng.
- `udp`: `udp` hoặc `tcp` theo nhu cầu.
- `laptop`: tên client chỉ gồm ký tự an toàn, không dùng khoảng trắng.

Các biến tùy chọn đúng theo script:

| Biến | Mặc định | Ý nghĩa |
|---|---:|---|
| `ENDPOINT` | IP trên interface mặc định | IP/hostname ghi vào file client |
| `PORT` | `1194` | Cổng OpenVPN |
| `PROTOCOL` | `udp` | Giao thức OpenVPN |
| `CLIENT_NAME` | `client` | Tên certificate và file `.ovpn` |
| `VPN_SUBNET` | `10.8.0.0/24` | Subnet dùng cho rule NAT |
| `VPN_NETWORK` | `10.8.0.0` | Địa chỉ mạng OpenVPN |
| `VPN_NETMASK` | `255.255.255.0` | Netmask OpenVPN |
| `DNS1` | `1.1.1.1` | DNS thứ nhất đẩy cho client |
| `DNS2` | `1.0.0.1` | DNS thứ hai đẩy cho client |
| `PKG_LOCK_TIMEOUT` | `600` | Số giây chờ package manager |
| `PKG_LOCK_POLL` | `5` | Chu kỳ kiểm tra lock |

Trên Alpine, script tự cài Bash bằng `apk` rồi chạy lại chính nó.

### 3. Dấu hiệu cài thành công

Cuối log phải có dòng tương tự:

```text
[INFO] Installation verified: openvpn-server@server.service active, udp/1194 listening, tun0 present.
[INFO] Client profile created at /root/laptop.ovpn (never commit this file).
```

Tên service, protocol, port và tên client có thể khác theo distro/cấu hình.

## Kiểm tra sau cài đặt

Script lưu service/config thực tế trong `/var/lib/openvpn-installer/state.env`. Không đoán tên service; đọc state trước.

### systemd

Chạy trên **VPS**:

```bash
sudo bash -c '. /var/lib/openvpn-installer/state.env
systemctl status "$SERVICE_UNIT" --no-pager
ss -lunp | grep ":$PORT " || ss -lntp | grep ":$PORT "
ip address show tun0
sysctl net.ipv4.ip_forward'
```

Kết quả đúng:

- service có trạng thái `active (running)`;
- port đã chọn xuất hiện trong `ss`;
- interface `tun0` tồn tại;
- `net.ipv4.ip_forward = 1`.

Xem log service và log installer:

```bash
sudo bash -c '. /var/lib/openvpn-installer/state.env
journalctl -u "$SERVICE_UNIT" -n 100 --no-pager'
sudo tail -n 100 /var/log/openvpn-installer.log
sudo tail -n 100 /var/log/openvpn-server.log
```

### OpenRC (Alpine)

```bash
sudo rc-service openvpn status
sudo ss -lunp
sudo ip address show tun0
sudo sysctl net.ipv4.ip_forward
```

## Tải và dùng file client

File mặc định là `/root/client.ovpn`; nếu dùng `CLIENT_NAME=laptop` thì file là `/root/laptop.ovpn`.

File này chứa private key. Không mở nội dung trong chat, không gửi qua kênh công khai và không commit lên GitHub.

Tải từ VPS về **máy cá nhân**:

```bash
scp root@YOUR_SERVER_IP:/root/CLIENT_NAME.ovpn ./CLIENT_NAME.ovpn
```

Ví dụ:

```bash
scp root@203.0.113.10:/root/laptop.ovpn ./laptop.ovpn
```

Sau đó import file vào OpenVPN Connect hoặc Tunnelblick. Kết nối thử và kiểm tra IP public/DNS. Trên VPS có thể xem client đã kết nối bằng:

```bash
sudo cat /var/log/openvpn-status.log
```

## Quản lý client

Script hiện không có lệnh `add-client`, `revoke-client` hoặc menu tương tác riêng.

Để tạo thêm profile client bằng logic hiện có, chạy `repair` với tên mới trên **VPS**:

```bash
cd openVPN
sudo CLIENT_NAME=phone ./openvpn-install.sh repair
```

Kết quả là `/root/phone.ovpn`. PKI cũ được giữ; certificate chỉ được tạo nếu chưa tồn tại. Mỗi lần chạy nên dùng tên riêng cho từng thiết bị.

> Script chưa tự revoke từng client. Không xóa thủ công certificate/key nếu chưa hiểu Easy-RSA. Khi cần thu hồi riêng một client, phải bổ sung quy trình revoke/CRL trước khi coi là đã vô hiệu hóa hoàn toàn.

## Repair và gỡ cài đặt

### Repair

Dùng khi package/config/rule cần được tạo lại. Lệnh giữ PKI hiện có và baseline ban đầu:

```bash
cd openVPN
sudo ./openvpn-install.sh repair
```

Repair vẫn chạy lại kiểm tra package, viết lại config (có tạo file backup có timestamp), áp dụng rule riêng và xác minh service/port/`tun0`.

### Uninstall

> Lệnh này dừng OpenVPN và xóa config, PKI, client profile, sysctl cùng firewall rule đã ghi trong state. Hãy sao lưu profile cần giữ trước khi chạy.

```bash
cd openVPN
sudo ./openvpn-install.sh uninstall
```

Script giữ lại package OpenVPN/Easy-RSA, không autoremove, không reboot và không reset firewall. Nếu không có `state.env`, script từ chối cleanup rộng.

## Lỗi thường gặp

### Package manager đang bị khóa

Log có dạng `apt-get is busy` hoặc tương tự. Script tự chờ 5 giây/lần, tối đa 600 giây. Không xóa lock và không kill `apt`/`dpkg` đang chạy hợp lệ.

Kiểm tra tiến trình:

```bash
ps aux | grep -E 'apt|dpkg|dnf|yum|pacman|apk|zypper' | grep -v grep
```

Nếu timeout, chờ tiến trình hệ thống hoàn tất rồi chạy lại installer.

### `/dev/net/tun is unavailable`

VPS/container chưa được cấp TUN. Bật TUN trong control panel nhà cung cấp hoặc đổi loại VPS; không thể sửa bằng cách tạo file thường.

### Không tìm thấy Easy-RSA

Trên RHEL tối giản, repository hiện tại có thể không chứa `easy-rsa`. Bật repository phù hợp theo tài liệu distro rồi chạy lại; script không tự thêm repo ngoài.

### Service active nhưng không thấy port hoặc `tun0`

Đọc đúng service từ state và xem log:

```bash
sudo bash -c '. /var/lib/openvpn-installer/state.env
systemctl status "$SERVICE_UNIT" --no-pager
journalctl -u "$SERVICE_UNIT" -n 100 --no-pager
ss -lunp
ip link show tun0'
```

Installer chờ tối đa 30 giây. Không báo thành công nếu thiếu port hoặc `tun0`.

### Client không kết nối được

Kiểm tra:

1. `remote`, port và protocol trong file client đúng với VPS.
2. Cloud Firewall/Security Group đã mở đúng port/protocol.
3. UFW/firewalld và service firewall riêng đang chạy.
4. DNS/hostname trỏ đúng IP public.
5. Thời gian hệ thống client/VPS không sai nhiều.

Không đăng nội dung file `.ovpn` lên issue hoặc chat công khai.

## File quan trọng

| Đường dẫn | Mục đích |
|---|---|
| `/var/lib/openvpn-installer/state.env` | Service, config và rule thực tế để repair/uninstall đúng phạm vi |
| `/var/lib/openvpn-installer/baseline/` | Network, service và firewall trước lần cài đầu |
| `/etc/openvpn/server/server.conf` | Config phổ biến trên systemd mới |
| `/etc/openvpn/server.conf` | Config của unit `openvpn@server.service` |
| `/etc/openvpn/openvpn.conf` | Config OpenRC hoặc `openvpn.service` |
| `/etc/openvpn/pki/` | CA, certificate và private key |
| `/etc/openvpn/tls-crypt.key` | Khóa bảo vệ control channel |
| `/root/CLIENT_NAME.ovpn` | Profile client chứa private key |
| `/var/log/openvpn-installer.log` | Log installer |
| `/var/log/openvpn-server.log` | Log OpenVPN server |

## Firewall và forwarding

- Ưu tiên nftables; nếu không có thì dùng iptables.
- nftables dùng table riêng `openvpn-installer` và `openvpn-installer_nat`.
- iptables dùng comment `openvpn-installer` và kiểm tra rule trước khi thêm.
- Nếu UFW/firewalld đang active, script chỉ mở port OpenVPN.
- NAT chỉ áp dụng cho VPN subnet trên interface outbound được phát hiện.
- Không flush/reset ruleset hiện tại.

## Bảo mật và giới hạn

- Không commit `.ovpn`, private key, certificate client, PKI, password hoặc token.
- File key/profile được đặt quyền `600`.
- Mặc định dùng TLS 1.2+, `tls-crypt`, AES-GCM/ChaCha20 và SHA-256.
- Hiện chỉ hỗ trợ IPv4 VPN; script không bật IPv6 forwarding.
- Container/VPS không có TUN không thể dùng installer này.
- Tên package/unit có thể thay đổi ở bản distro tương lai; script sẽ dừng nếu không xác định an toàn.
- Installer không sửa SSH, proxy/backend ứng dụng, Cloudflare, Telegram hoặc Worker.
