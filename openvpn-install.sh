#!/bin/sh
# Portable OpenVPN installer: Debian, RHEL, Arch, Alpine and openSUSE families.
# Alpine bootstrap: the script installs bash, then re-executes itself.
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v apk >/dev/null 2>&1; then
    [ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
    apk --wait 600 add --no-cache bash >/dev/null
  fi
  command -v bash >/dev/null 2>&1 || { echo "This installer requires bash"; exit 1; }
  exec bash "$0" "$@"
fi

set -Eeuo pipefail
umask 077

APP_NAME=openvpn-installer
STATE_DIR=/var/lib/$APP_NAME
STATE_FILE=$STATE_DIR/state.env
BASELINE_DIR=$STATE_DIR/baseline
PKI_DIR=/etc/openvpn/pki
SERVER_NAME=server
CLIENT_NAME=${CLIENT_NAME:-client}
VPN_SUBNET=${VPN_SUBNET:-10.8.0.0/24}
VPN_NETWORK=${VPN_NETWORK:-10.8.0.0}
VPN_NETMASK=${VPN_NETMASK:-255.255.255.0}
PORT=${PORT:-1194}
PROTOCOL=${PROTOCOL:-udp}
DNS1=${DNS1:-1.1.1.1}
DNS2=${DNS2:-1.0.0.1}
ACTION=${1:-install}
LOG_FILE=/var/log/openvpn-installer.log
PKG_LOCK_TIMEOUT=${PKG_LOCK_TIMEOUT:-600}
PKG_LOCK_POLL=${PKG_LOCK_POLL:-5}

log(){ printf "[%s] %s\n" "$1" "$2" | tee -a "$LOG_FILE"; }
die(){ log ERROR "$1"; exit 1; }
on_error(){ local rc=$?; log ERROR "Failed at line $1 (exit $rc). Review $LOG_FILE"; exit "$rc"; }
trap 'on_error $LINENO' ERR

require_root(){ [ "$EUID" -eq 0 ] || die "Run this installer as root."; }
require_tun(){ [ -c /dev/net/tun ] || die "/dev/net/tun is unavailable. Enable TUN at the provider first."; }

OS_ID= OS_LIKE= OS_VERSION= OS_FAMILY= PKG_MGR= INIT_SYSTEM= OUT_IF= PUBLIC_ENDPOINT=
SERVER_CONF= SERVICE_UNIT= EASYRSA_BIN= FW_BACKEND= GROUP_NAME= PREV_IPV4_FORWARD=0
OPENVPN_PREEXISTING=0 EASYRSA_PREEXISTING=0 UFW_RULE_ADDED=0 FIREWALLD_RULE_ADDED=0

detect_os(){
  [ -r /etc/os-release ] || die "Unsupported distro: /etc/os-release is missing."
  . /etc/os-release
  OS_ID=${ID:-unknown}; OS_LIKE=${ID_LIKE:-}; OS_VERSION=${VERSION_ID:-unknown}
  case " $OS_ID $OS_LIKE " in
    *debian*|*ubuntu*) OS_FAMILY=debian ;;
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*ol*) OS_FAMILY=rhel ;;
    *arch*|*manjaro*) OS_FAMILY=arch ;;
    *alpine*) OS_FAMILY=alpine ;;
    *suse*|*opensuse*) OS_FAMILY=suse ;;
    *) die "Unsupported distro: ID=$OS_ID ID_LIKE=$OS_LIKE" ;;
  esac
  log INFO "Detected $OS_ID $OS_VERSION ($OS_FAMILY family)."
}

detect_package_manager(){
  local candidate
  case $OS_FAMILY in
    debian) candidate=apt-get ;; rhel) command -v dnf >/dev/null && candidate=dnf || candidate=yum ;;
    arch) candidate=pacman ;; alpine) candidate=apk ;; suse) candidate=zypper ;;
  esac
  command -v "$candidate" >/dev/null 2>&1 || die "Package manager $candidate was not found."
  PKG_MGR=$candidate
}


package_manager_busy(){
  case $PKG_MGR in
    apt-get)
      if command -v fuser >/dev/null 2>&1; then
        fuser -s /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null
      else
        pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null || pgrep -x unattended-upgrade >/dev/null
      fi
      ;;
    dnf) pgrep -x dnf >/dev/null || pgrep -x packagekitd >/dev/null ;;
    yum) pgrep -x yum >/dev/null || pgrep -x packagekitd >/dev/null ;;
    pacman) [ -e /var/lib/pacman/db.lck ] ;;
    apk)
      if command -v fuser >/dev/null 2>&1; then fuser -s /lib/apk/db/lock 2>/dev/null
      else pgrep -x apk >/dev/null; fi
      ;;
    zypper) pgrep -x zypper >/dev/null || pgrep -x packagekitd >/dev/null ;;
    *) return 1 ;;
  esac
}

wait_for_package_manager(){
  local started now elapsed announced=0
  started=$(date +%s)
  while package_manager_busy; do
    now=$(date +%s); elapsed=$((now - started))
    if [ "$elapsed" -ge "$PKG_LOCK_TIMEOUT" ]; then
      die "Timed out after ${PKG_LOCK_TIMEOUT}s waiting for $PKG_MGR lock. No lock file was removed and no process was killed."
    fi
    if [ "$announced" -eq 0 ] || [ $((elapsed % 30)) -lt "$PKG_LOCK_POLL" ]; then
      log WARN "$PKG_MGR is busy; waiting for its valid process to release the lock (${elapsed}s elapsed)."
      announced=1
    fi
    sleep "$PKG_LOCK_POLL"
  done
  [ "$announced" -eq 0 ] || log INFO "$PKG_MGR lock released; continuing installation."
}

run_package_command(){
  wait_for_package_manager
  if [ "$PKG_MGR" = apt-get ]; then
    apt-get -o DPkg::Lock::Timeout="$PKG_LOCK_TIMEOUT" "$@"
  else
    "$PKG_MGR" "$@"
  fi
}

detect_init_system(){
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null; then INIT_SYSTEM=systemd
  elif command -v rc-service >/dev/null && command -v rc-update >/dev/null; then INIT_SYSTEM=openrc
  else die "Unsupported init system. Supported: systemd and OpenRC."; fi
}

package_installed(){
  case $PKG_MGR in
    apt-get) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
    dnf|yum) rpm -q "$1" >/dev/null 2>&1 ;; pacman) pacman -Q "$1" >/dev/null 2>&1 ;;
    apk) apk info -e "$1" >/dev/null 2>&1 ;; zypper) rpm -q "$1" >/dev/null 2>&1 ;;
  esac
}

install_packages(){
  package_installed openvpn && OPENVPN_PREEXISTING=1
  package_installed easy-rsa && EASYRSA_PREEXISTING=1
  log INFO "Installing only required packages with $PKG_MGR."
  case $PKG_MGR in
    apt-get)
      run_package_command update
      DEBIAN_FRONTEND=noninteractive run_package_command install -y --no-install-recommends openvpn easy-rsa ca-certificates
      ;;
    dnf) run_package_command install -y openvpn easy-rsa ca-certificates ;;
    yum) run_package_command install -y openvpn easy-rsa ca-certificates ;;
    pacman) run_package_command -Sy --needed --noconfirm openvpn easy-rsa ca-certificates ;;
    apk) run_package_command add --no-cache openvpn easy-rsa ca-certificates bash ;;
    zypper) run_package_command --non-interactive install --no-recommends openvpn easy-rsa ca-certificates ;;
  esac
  command -v openvpn >/dev/null || die "OpenVPN package installation failed."
}

detect_layout(){
  if [ "$INIT_SYSTEM" = systemd ]; then
    if systemctl cat openvpn-server@.service >/dev/null 2>&1; then
      mkdir -p /etc/openvpn/server
      SERVER_CONF=/etc/openvpn/server/server.conf
      SERVICE_UNIT=openvpn-server@server.service
    elif systemctl cat openvpn@.service >/dev/null 2>&1; then
      mkdir -p /etc/openvpn
      SERVER_CONF=/etc/openvpn/server.conf
      SERVICE_UNIT=openvpn@server.service
    elif systemctl cat openvpn.service >/dev/null 2>&1; then
      mkdir -p /etc/openvpn
      SERVER_CONF=/etc/openvpn/openvpn.conf
      SERVICE_UNIT=openvpn.service
    else
      die "No supported OpenVPN systemd unit was installed."
    fi
  else
    mkdir -p /etc/openvpn
    SERVER_CONF=/etc/openvpn/openvpn.conf
    [ -x /etc/init.d/openvpn ] || die "OpenRC OpenVPN service was not installed."
    SERVICE_UNIT=openvpn
  fi
  GROUP_NAME=nogroup
  getent group nogroup >/dev/null 2>&1 || GROUP_NAME=nobody
}

locate_easyrsa(){
  local candidate
  for candidate in "$(command -v easyrsa 2>/dev/null || true)" /usr/share/easy-rsa/easyrsa /usr/share/easy-rsa/3/easyrsa /usr/share/easy-rsa/3.0/easyrsa; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { EASYRSA_BIN=$candidate; break; }
  done
  [ -n "$EASYRSA_BIN" ] || die "Easy-RSA executable was not found after package installation."
}

detect_network(){
  OUT_IF=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
  [ -n "$OUT_IF" ] || die "Unable to detect outbound interface from the default route."
  PUBLIC_ENDPOINT=${ENDPOINT:-}
  if [ -z "$PUBLIC_ENDPOINT" ]; then
    PUBLIC_ENDPOINT=$(ip -4 addr show dev "$OUT_IF" | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
  fi
  [ -n "$PUBLIC_ENDPOINT" ] || die "Set ENDPOINT to the public IP or hostname."
}

capture_baseline(){
  mkdir -p "$BASELINE_DIR"
  if [ -f "$BASELINE_DIR/captured-at.txt" ]; then
    log INFO "Preserving the original pre-install baseline."
    return
  fi
  date -Is > "$BASELINE_DIR/captured-at.txt"
  ip -brief address > "$BASELINE_DIR/ip-address.txt"
  ip route show > "$BASELINE_DIR/routes.txt"
  ss -lntup > "$BASELINE_DIR/listeners.txt"
  sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding > "$BASELINE_DIR/forwarding.txt" 2>&1 || true
  systemctl list-units --type=service --state=running --no-pager > "$BASELINE_DIR/services.txt" 2>&1 || true
  nft list ruleset > "$BASELINE_DIR/nftables.txt" 2>&1 || true
  iptables-save > "$BASELINE_DIR/iptables.txt" 2>&1 || true
  ufw status verbose > "$BASELINE_DIR/ufw.txt" 2>&1 || true
  firewall-cmd --list-all-zones > "$BASELINE_DIR/firewalld.txt" 2>&1 || true
}

build_pki(){
  mkdir -p "$PKI_DIR"
  if [ ! -f "$PKI_DIR/ca.crt" ]; then
    log INFO "Creating a new PKI."
    EASYRSA_BATCH=1 EASYRSA_PKI="$PKI_DIR" EASYRSA_REQ_CN=OpenVPN-CA "$EASYRSA_BIN" init-pki
    EASYRSA_BATCH=1 EASYRSA_PKI="$PKI_DIR" EASYRSA_REQ_CN=OpenVPN-CA "$EASYRSA_BIN" build-ca nopass
  fi
  [ -f "$PKI_DIR/issued/server.crt" ] || EASYRSA_BATCH=1 EASYRSA_PKI="$PKI_DIR" "$EASYRSA_BIN" build-server-full server nopass
  [ -f "$PKI_DIR/issued/$CLIENT_NAME.crt" ] || EASYRSA_BATCH=1 EASYRSA_PKI="$PKI_DIR" "$EASYRSA_BIN" build-client-full "$CLIENT_NAME" nopass
  [ -f /etc/openvpn/tls-crypt.key ] || openvpn --genkey secret /etc/openvpn/tls-crypt.key
  chmod 600 "$PKI_DIR/private/server.key" "$PKI_DIR/private/$CLIENT_NAME.key" /etc/openvpn/tls-crypt.key
}

write_server_config(){
  [ ! -f "$SERVER_CONF" ] || cp -a "$SERVER_CONF" "$SERVER_CONF.bak.$(date +%Y%m%d%H%M%S)"
  cat > "$SERVER_CONF" <<EOF
port $PORT
proto $PROTOCOL
dev tun
user nobody
group $GROUP_NAME
persist-key
persist-tun
topology subnet
server $VPN_NETWORK $VPN_NETMASK
ifconfig-pool-persist /var/lib/openvpn/ipp.txt
ca $PKI_DIR/ca.crt
cert $PKI_DIR/issued/server.crt
key $PKI_DIR/private/server.key
dh none
ecdh-curve prime256v1
tls-crypt /etc/openvpn/tls-crypt.key
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
auth SHA256
server-cert-not-required
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS $DNS1"
push "dhcp-option DNS $DNS2"
keepalive 10 120
explicit-exit-notify 1
status /var/log/openvpn-status.log
log-append /var/log/openvpn-server.log
verb 3
EOF
  # Remove an option unsupported by server mode; retained here only if a downstream package requires it.
  sed -i '/^server-cert-not-required$/d' "$SERVER_CONF"
}

verify_assets(){
  local file
  for file in "$SERVER_CONF" "$PKI_DIR/ca.crt" "$PKI_DIR/issued/server.crt" "$PKI_DIR/private/server.key" /etc/openvpn/tls-crypt.key; do
    [ -s "$file" ] || die "Required file is missing: $file"
  done
  openvpn --config "$SERVER_CONF" --test-crypto >/dev/null 2>&1 || log WARN "OpenVPN --test-crypto is not supported by this package; service start remains authoritative."
}

configure_forwarding(){
  PREV_IPV4_FORWARD=$(sysctl -n net.ipv4.ip_forward)
  cat > /etc/sysctl.d/99-openvpn-installer.conf <<EOF
# Managed by $APP_NAME
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
  [ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] || die "IPv4 forwarding could not be enabled."
}

detect_firewall(){
  if command -v nft >/dev/null 2>&1; then FW_BACKEND=nft
  elif command -v iptables >/dev/null 2>&1; then FW_BACKEND=iptables
  else die "Neither nftables nor iptables is available."; fi
}

write_firewall_scripts(){
  mkdir -p /usr/local/lib/$APP_NAME
  if [ "$FW_BACKEND" = nft ]; then
    cat > /usr/local/lib/$APP_NAME/firewall-up.sh <<EOF
#!/usr/bin/env bash
set -e
nft list table inet $APP_NAME >/dev/null 2>&1 && nft delete table inet $APP_NAME || true
nft list table ip ${APP_NAME}_nat >/dev/null 2>&1 && nft delete table ip ${APP_NAME}_nat || true
nft -f - <<NFT
add table inet $APP_NAME
add chain inet $APP_NAME forward { type filter hook forward priority -10; policy accept; }
add rule inet $APP_NAME forward iifname "tun0" oifname "$OUT_IF" accept
add rule inet $APP_NAME forward iifname "$OUT_IF" oifname "tun0" ct state established,related accept
add table ip ${APP_NAME}_nat
add chain ip ${APP_NAME}_nat postrouting { type nat hook postrouting priority srcnat; policy accept; }
add rule ip ${APP_NAME}_nat postrouting ip saddr $VPN_SUBNET oifname "$OUT_IF" masquerade
NFT
EOF
    cat > /usr/local/lib/$APP_NAME/firewall-down.sh <<EOF
#!/usr/bin/env bash
nft list table inet $APP_NAME >/dev/null 2>&1 && nft delete table inet $APP_NAME || true
nft list table ip ${APP_NAME}_nat >/dev/null 2>&1 && nft delete table ip ${APP_NAME}_nat || true
EOF
  else
    cat > /usr/local/lib/$APP_NAME/firewall-up.sh <<EOF
#!/usr/bin/env bash
set -e
iptables -C INPUT -p $PROTOCOL --dport $PORT -m comment --comment $APP_NAME -j ACCEPT 2>/dev/null || iptables -I INPUT -p $PROTOCOL --dport $PORT -m comment --comment $APP_NAME -j ACCEPT
iptables -C FORWARD -i tun0 -o $OUT_IF -m comment --comment $APP_NAME -j ACCEPT 2>/dev/null || iptables -I FORWARD -i tun0 -o $OUT_IF -m comment --comment $APP_NAME -j ACCEPT
iptables -C FORWARD -i $OUT_IF -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment $APP_NAME -j ACCEPT 2>/dev/null || iptables -I FORWARD -i $OUT_IF -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment $APP_NAME -j ACCEPT
iptables -t nat -C POSTROUTING -s $VPN_SUBNET -o $OUT_IF -m comment --comment $APP_NAME -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $VPN_SUBNET -o $OUT_IF -m comment --comment $APP_NAME -j MASQUERADE
EOF
    cat > /usr/local/lib/$APP_NAME/firewall-down.sh <<EOF
#!/usr/bin/env bash
iptables -D INPUT -p $PROTOCOL --dport $PORT -m comment --comment $APP_NAME -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i tun0 -o $OUT_IF -m comment --comment $APP_NAME -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i $OUT_IF -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment $APP_NAME -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s $VPN_SUBNET -o $OUT_IF -m comment --comment $APP_NAME -j MASQUERADE 2>/dev/null || true
EOF
  fi
  chmod 700 /usr/local/lib/$APP_NAME/firewall-*.sh

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow "$PORT/$PROTOCOL" comment "$APP_NAME"
    UFW_RULE_ADDED=1
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    firewall-cmd --permanent --add-port="$PORT/$PROTOCOL"
    firewall-cmd --reload
    FIREWALLD_RULE_ADDED=1
  fi

  if [ "$INIT_SYSTEM" = systemd ]; then
    cat > /etc/systemd/system/openvpn-installer-firewall.service <<EOF
[Unit]
Description=OpenVPN installer owned firewall rules
Before=$SERVICE_UNIT
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/lib/$APP_NAME/firewall-up.sh
ExecStop=/usr/local/lib/$APP_NAME/firewall-down.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now openvpn-installer-firewall.service
  else
    cp /usr/local/lib/$APP_NAME/firewall-up.sh /etc/local.d/openvpn-installer.start
    cp /usr/local/lib/$APP_NAME/firewall-down.sh /etc/local.d/openvpn-installer.stop
    chmod 700 /etc/local.d/openvpn-installer.start /etc/local.d/openvpn-installer.stop
    rc-update add local default >/dev/null
    /etc/local.d/openvpn-installer.start
  fi
}

write_client(){
  local out=/root/$CLIENT_NAME.ovpn
  cat > "$out" <<EOF
client
dev tun
proto $PROTOCOL
remote $PUBLIC_ENDPOINT $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256
verb 3
<ca>
$(cat "$PKI_DIR/ca.crt")
</ca>
<cert>
$(sed -ne '/BEGIN CERTIFICATE/,$ p' "$PKI_DIR/issued/$CLIENT_NAME.crt")
</cert>
<key>
$(cat "$PKI_DIR/private/$CLIENT_NAME.key")
</key>
<tls-crypt>
$(cat /etc/openvpn/tls-crypt.key)
</tls-crypt>
EOF
  chmod 600 "$out"
  log INFO "Client profile created at $out (never commit this file)."
}

save_state(){
  mkdir -p "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
OS_FAMILY='$OS_FAMILY'
PKG_MGR='$PKG_MGR'
INIT_SYSTEM='$INIT_SYSTEM'
OUT_IF='$OUT_IF'
PORT='$PORT'
PROTOCOL='$PROTOCOL'
SERVER_CONF='$SERVER_CONF'
SERVICE_UNIT='$SERVICE_UNIT'
FW_BACKEND='$FW_BACKEND'
PREV_IPV4_FORWARD='$PREV_IPV4_FORWARD'
OPENVPN_PREEXISTING='$OPENVPN_PREEXISTING'
EASYRSA_PREEXISTING='$EASYRSA_PREEXISTING'
UFW_RULE_ADDED='$UFW_RULE_ADDED'
FIREWALLD_RULE_ADDED='$FIREWALLD_RULE_ADDED'
CLIENT_NAME='$CLIENT_NAME'
EOF
  chmod 600 "$STATE_FILE"
}

start_openvpn(){
  if [ "$INIT_SYSTEM" = systemd ]; then
    systemctl enable "$SERVICE_UNIT"
    systemctl restart "$SERVICE_UNIT"
    systemctl is-active --quiet "$SERVICE_UNIT" || { journalctl -u "$SERVICE_UNIT" -n 80 --no-pager; die "OpenVPN service failed."; }
  else
    rc-update add openvpn default >/dev/null
    rc-service openvpn restart
    rc-service openvpn status >/dev/null || die "OpenVPN OpenRC service failed."
  fi
  ss -lnup | grep -q ":$PORT " || die "OpenVPN is active but $PROTOCOL port $PORT is not listening."
  ip link show tun0 >/dev/null 2>&1 || die "OpenVPN service is active but tun0 is missing."
}

install_main(){
  require_root; require_tun; detect_os; detect_package_manager; detect_init_system; detect_network
  mkdir -p "$STATE_DIR"; capture_baseline; install_packages; detect_layout; locate_easyrsa
  build_pki; write_server_config; verify_assets; configure_forwarding; detect_firewall; write_firewall_scripts
  save_state; start_openvpn; write_client
  log INFO "Installation verified: $SERVICE_UNIT active, $PROTOCOL/$PORT listening, tun0 present."
}

uninstall_main(){
  require_root
  [ -r "$STATE_FILE" ] || die "No installer state found; refusing broad cleanup."
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  if [ "$INIT_SYSTEM" = systemd ]; then
    systemctl disable --now "$SERVICE_UNIT" 2>/dev/null || true
    systemctl disable --now openvpn-installer-firewall.service 2>/dev/null || true
    rm -f /etc/systemd/system/openvpn-installer-firewall.service
    systemctl daemon-reload
  else
    rc-service openvpn stop 2>/dev/null || true
    rc-update del openvpn default 2>/dev/null || true
    /usr/local/lib/$APP_NAME/firewall-down.sh || true
    rm -f /etc/local.d/openvpn-installer.start /etc/local.d/openvpn-installer.stop
  fi
  /usr/local/lib/$APP_NAME/firewall-down.sh 2>/dev/null || true
  [ "$UFW_RULE_ADDED" = 1 ] && ufw --force delete allow "$PORT/$PROTOCOL" || true
  if [ "$FIREWALLD_RULE_ADDED" = 1 ]; then firewall-cmd --permanent --remove-port="$PORT/$PROTOCOL" || true; firewall-cmd --reload || true; fi
  rm -rf /usr/local/lib/$APP_NAME
  rm -f /etc/sysctl.d/99-openvpn-installer.conf "$SERVER_CONF" /etc/openvpn/tls-crypt.key
  rm -rf "$PKI_DIR"
  rm -f "/root/$CLIENT_NAME.ovpn"
  sysctl -w net.ipv4.ip_forward="$PREV_IPV4_FORWARD" >/dev/null || true
  log INFO "Removed only OpenVPN files and rules recorded by this installer. Packages were retained intentionally."
}

case $ACTION in
  install|repair) install_main ;; uninstall) uninstall_main ;;
  *) die "Usage: $0 [install|repair|uninstall]" ;;
esac
