#!/usr/bin/env bash
set -eu

NAME="litebox"
BIN="/usr/local/bin/sing-box"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
BASE_DIR="/etc/litebox"
CONF="$BASE_DIR/config.json"
ENV_FILE="$BASE_DIR/env"
LINKS_FILE="$BASE_DIR/links.txt"
CERT_DIR="$BASE_DIR/cert"
SERVICE="/etc/systemd/system/litebox.service"
ARGO_SERVICE="/etc/systemd/system/litebox-argo.service"
CLI="/usr/local/bin/litebox"
SB_CLI="/usr/local/bin/sb"
SCRIPT_URL="https://raw.githubusercontent.com/linlvyy/litebox-singbox-mini/main/install.sh"

SING_BOX_VERSION="${SING_BOX_VERSION:-latest}"
SERVER="${SERVER:-}"
REALITY_SNI="${REALITY_SNI:-}"
TLS_SNI="${TLS_SNI:-}"
VMESS_WS_PATH="${VMESS_WS_PATH:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_TOKEN="${ARGO_TOKEN:-}"
ENABLE_TEMP_ARGO="${ENABLE_TEMP_ARGO:-}"

ANYTLS_PORT="${ANYTLS_PORT:-}"
TUIC_PORT="${TUIC_PORT:-}"
VLESS_PORT="${VLESS_PORT:-}"
HY2_PORT="${HY2_PORT:-}"
VMESS_LOCAL_PORT="${VMESS_LOCAL_PORT:-}"

log() { printf '%s\n' "$*"; }
die() { log "error: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = "0" ] || die "please run as root"; }
has() { command -v "$1" >/dev/null 2>&1; }

rand_hex() {
  if has openssl; then
    openssl rand -hex "$1"
  else
    tr -dc 'a-f0-9' </dev/urandom | head -c "$(( $1 * 2 ))"
  fi
}

rand_b64() {
  if has openssl; then
    openssl rand -base64 "$1" | tr -d '\n=' | tr '+/' '-_'
  else
    rand_hex "$1"
  fi
}

uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    printf '%s-%s-%s-%s-%s\n' "$(rand_hex 4)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 6)"
  fi
}

b64_nowrap() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w 0
  else
    base64 | tr -d '\n'
  fi
}

public_ip() {
  [ -n "$SERVER" ] && {
    printf '%s\n' "$SERVER"
    return
  }
  for url in https://api.ipify.org https://ifconfig.me; do
    ip="$(curl -fsSL --connect-timeout 3 "$url" 2>/dev/null || true)"
    [ -n "$ip" ] && {
      printf '%s\n' "$ip"
      return
    }
  done
  hostname -I 2>/dev/null | awk '{print $1}'
}

download_url() {
  repo="$1"
  pattern="$2"
  curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
    sed -n 's/.*"browser_download_url": "\(.*\)".*/\1/p' |
    grep "$pattern" | head -n 1
}

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) printf amd64 ;;
    aarch64|arm64) printf arm64 ;;
    armv7l) printf armv7 ;;
    s390x) printf s390x ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
}

install_deps_hint() {
  for c in curl tar openssl sed grep awk systemctl; do
    has "$c" || die "missing $c"
  done
}

is_installed() {
  [ -x "$BIN" ] && [ -f "$CONF" ] && [ -f "$ENV_FILE" ]
}

require_installed() {
  is_installed || die "litebox is not installed yet"
}

port_valid() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *)
      [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
      ;;
  esac
}

random_port_between() {
  min="$1"
  max="$2"
  range="$(( max - min + 1 ))"
  num="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
  printf '%s\n' "$(( (num % range) + min ))"
}

apply_saved_settings() {
  REALITY_SNI="${REALITY_SNI:-${LB_REALITY_SNI:-www.microsoft.com}}"
  TLS_SNI="${TLS_SNI:-${LB_TLS_SNI:-bing.com}}"
  VMESS_WS_PATH="${VMESS_WS_PATH:-${LB_VMESS_WS_PATH:-/vmess}}"
  ARGO_DOMAIN="${ARGO_DOMAIN:-${LB_ARGO_DOMAIN:-}}"
  ARGO_TOKEN="${ARGO_TOKEN:-${LB_ARGO_TOKEN:-}}"
  ENABLE_TEMP_ARGO="${ENABLE_TEMP_ARGO:-${LB_ENABLE_TEMP_ARGO:-0}}"
  ANYTLS_PORT="${ANYTLS_PORT:-${LB_ANYTLS_PORT:-8443}}"
  TUIC_PORT="${TUIC_PORT:-${LB_TUIC_PORT:-9443}}"
  VLESS_PORT="${VLESS_PORT:-${LB_VLESS_PORT:-443}}"
  HY2_PORT="${HY2_PORT:-${LB_HY2_PORT:-8444}}"
  VMESS_LOCAL_PORT="${VMESS_LOCAL_PORT:-${LB_VMESS_LOCAL_PORT:-18080}}"
}

save_env() {
  mkdir -p "$BASE_DIR"
  cat >"$ENV_FILE" <<EOF
LB_SERVER='$LB_SERVER'
LB_UUID='$LB_UUID'
LB_PASSWORD='$LB_PASSWORD'
LB_ANYTLS_PASSWORD='$LB_ANYTLS_PASSWORD'
LB_TUIC_PASSWORD='$LB_TUIC_PASSWORD'
LB_HY2_PASSWORD='$LB_HY2_PASSWORD'
LB_HY2_OBFS='$LB_HY2_OBFS'
LB_SHORT_ID='$LB_SHORT_ID'
LB_REALITY_PRIVATE='$LB_REALITY_PRIVATE'
LB_REALITY_PUBLIC='$LB_REALITY_PUBLIC'
LB_REALITY_SNI='$REALITY_SNI'
LB_TLS_SNI='$TLS_SNI'
LB_VMESS_WS_PATH='$VMESS_WS_PATH'
LB_ARGO_DOMAIN='$ARGO_DOMAIN'
LB_ARGO_TOKEN='$ARGO_TOKEN'
LB_ENABLE_TEMP_ARGO='$ENABLE_TEMP_ARGO'
LB_ANYTLS_PORT='$ANYTLS_PORT'
LB_TUIC_PORT='$TUIC_PORT'
LB_VLESS_PORT='$VLESS_PORT'
LB_HY2_PORT='$HY2_PORT'
LB_VMESS_LOCAL_PORT='$VMESS_LOCAL_PORT'
EOF
  chmod 600 "$ENV_FILE"
}

load_or_create_env() {
  mkdir -p "$BASE_DIR"
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  fi

  apply_saved_settings

  LB_SERVER="${LB_SERVER:-$(public_ip)}"
  LB_UUID="${LB_UUID:-$(uuid)}"
  LB_PASSWORD="${LB_PASSWORD:-$(rand_b64 18)}"
  LB_ANYTLS_PASSWORD="${LB_ANYTLS_PASSWORD:-$(rand_b64 24)}"
  LB_TUIC_PASSWORD="${LB_TUIC_PASSWORD:-$(rand_b64 18)}"
  LB_HY2_PASSWORD="${LB_HY2_PASSWORD:-$(rand_b64 18)}"
  LB_HY2_OBFS="${LB_HY2_OBFS:-$(rand_b64 12)}"
  LB_SHORT_ID="${LB_SHORT_ID:-$(rand_hex 4)}"
  LB_REALITY_PRIVATE="${LB_REALITY_PRIVATE:-}"
  LB_REALITY_PUBLIC="${LB_REALITY_PUBLIC:-}"

  if [ -z "$LB_REALITY_PRIVATE" ] || [ -z "$LB_REALITY_PUBLIC" ]; then
    pair="$("$BIN" generate reality-keypair)"
    LB_REALITY_PRIVATE="$(printf '%s\n' "$pair" | awk '/PrivateKey:/ {print $2}')"
    LB_REALITY_PUBLIC="$(printf '%s\n' "$pair" | awk '/PublicKey:/ {print $2}')"
  fi

  save_env
}

install_sing_box() {
  arch="$(arch_name)"
  tmp="$(mktemp -d)"
  if [ "$SING_BOX_VERSION" = "latest" ]; then
    url="$(download_url SagerNet/sing-box "linux-$arch.*\\.tar\\.gz")"
  else
    url="https://github.com/SagerNet/sing-box/releases/download/${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION#v}-linux-${arch}.tar.gz"
  fi
  [ -n "$url" ] || die "cannot find sing-box release for $arch"
  log "download sing-box: $url"
  curl -fL "$url" -o "$tmp/sing-box.tgz"
  tar -xzf "$tmp/sing-box.tgz" -C "$tmp"
  found="$(find "$tmp" -type f -name sing-box | head -n 1)"
  [ -n "$found" ] || die "sing-box binary not found"
  install -m 0755 "$found" "$BIN"
  rm -rf "$tmp"
}

install_cloudflared() {
  [ -n "$ARGO_TOKEN" ] || [ "$ENABLE_TEMP_ARGO" = "1" ] || return 0
  arch="$(arch_name)"
  tmp="$(mktemp -d)"
  url="$(download_url cloudflare/cloudflared "linux-$arch$")"
  [ -n "$url" ] || die "cannot find cloudflared release for $arch"
  log "download cloudflared: $url"
  curl -fL "$url" -o "$tmp/cloudflared"
  install -m 0755 "$tmp/cloudflared" "$CLOUDFLARED_BIN"
  rm -rf "$tmp"
}

gen_cert() {
  mkdir -p "$CERT_DIR"
  if [ -s "$CERT_DIR/cert.pem" ] && [ -s "$CERT_DIR/key.pem" ]; then
    return 0
  fi
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -nodes -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
    -subj "/CN=$TLS_SNI" >/dev/null 2>&1
}

write_config() {
  cat >"$CONF" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": false
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [
        {
          "name": "$NAME",
          "uuid": "$LB_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_SNI",
            "server_port": 443
          },
          "private_key": "$LB_REALITY_PRIVATE",
          "short_id": ["$LB_SHORT_ID"]
        }
      }
    },
    {
      "type": "anytls",
      "tag": "anytls",
      "listen": "::",
      "listen_port": $ANYTLS_PORT,
      "users": [
        {
          "name": "$NAME",
          "password": "$LB_ANYTLS_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$TLS_SNI",
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-v5",
      "listen": "::",
      "listen_port": $TUIC_PORT,
      "users": [
        {
          "name": "$NAME",
          "uuid": "$LB_UUID",
          "password": "$LB_TUIC_PASSWORD"
        }
      ],
      "congestion_control": "bbr",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "server_name": "$TLS_SNI",
        "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "obfs": {
        "type": "salamander",
        "password": "$LB_HY2_OBFS"
      },
      "users": [
        {
          "name": "$NAME",
          "password": "$LB_HY2_PASSWORD"
        }
      ],
      "ignore_client_bandwidth": true,
      "tls": {
        "enabled": true,
        "server_name": "$TLS_SNI",
        "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem"
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-ws-argo",
      "listen": "127.0.0.1",
      "listen_port": $VMESS_LOCAL_PORT,
      "users": [
        {
          "name": "$NAME",
          "uuid": "$LB_UUID",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$VMESS_WS_PATH"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
  "$BIN" check -c "$CONF"
}

write_services() {
  cat >"$SERVICE" <<EOF
[Unit]
Description=Litebox sing-box nodes
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  if [ -n "$ARGO_TOKEN" ] || [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    if [ -n "$ARGO_TOKEN" ]; then
      argo_cmd="$CLOUDFLARED_BIN tunnel --no-autoupdate run --token $ARGO_TOKEN"
    else
      argo_cmd="$CLOUDFLARED_BIN tunnel --no-autoupdate --url http://127.0.0.1:$VMESS_LOCAL_PORT"
    fi
    cat >"$ARGO_SERVICE" <<EOF
[Unit]
Description=Litebox Cloudflare Argo tunnel
After=network-online.target litebox.service
Wants=network-online.target
Requires=litebox.service

[Service]
Type=simple
ExecStart=$argo_cmd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  else
    rm -f "$ARGO_SERVICE"
  fi

  systemctl daemon-reload
}

write_cli() {
  if ! curl -fsSL "$SCRIPT_URL" -o "$CLI"; then
    self_path="$0"
    if [ -r "$self_path" ] && [ "$(basename "$self_path")" != "bash" ]; then
      install -m 0755 "$self_path" "$CLI"
    else
      die "cannot install litebox cli"
    fi
  fi
  chmod 0755 "$CLI"
  ln -sf "$CLI" "$SB_CLI"
}

write_links() {
  server="$LB_SERVER"
  vless="vless://$LB_UUID@$server:$VLESS_PORT?encryption=none&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$LB_REALITY_PUBLIC&sid=$LB_SHORT_ID&type=tcp&flow=xtls-rprx-vision#$NAME-vless-reality"
  anytls="anytls://$LB_ANYTLS_PASSWORD@$server:$ANYTLS_PORT?security=tls&sni=$TLS_SNI&insecure=1#$NAME-anytls"
  tuic="tuic://$LB_UUID:$LB_TUIC_PASSWORD@$server:$TUIC_PORT?congestion_control=bbr&alpn=h3&allow_insecure=1#$NAME-tuic-v5"
  hy2="hysteria2://$LB_HY2_PASSWORD@$server:$HY2_PORT?obfs=salamander&obfs-password=$LB_HY2_OBFS&sni=$TLS_SNI&insecure=1#$NAME-hysteria2"

  vmess_host="${ARGO_DOMAIN:-<your-argo-domain-from-cloudflared-log>}"
  vmess_json="$(printf '{"v":"2","ps":"%s-vmess-ws-argo","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s"}' "$NAME" "$vmess_host" "$LB_UUID" "$vmess_host" "$VMESS_WS_PATH" "$vmess_host" | b64_nowrap)"

  cat >"$LINKS_FILE" <<EOF
VLESS-REALITY:
$vless

AnyTLS:
$anytls

TUIC-v5:
$tuic

Hysteria2:
$hy2

VMess-WS-Argo:
vmess://$vmess_json

Server: $server
UUID: $LB_UUID
Reality public key: $LB_REALITY_PUBLIC
Reality short id: $LB_SHORT_ID
Shortcut: sudo sb
EOF
  chmod 600 "$LINKS_FILE"
}

enable_services() {
  systemctl enable --now litebox.service
  if [ -n "$ARGO_TOKEN" ] || [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    systemctl enable --now litebox-argo.service || true
  else
    systemctl disable --now litebox-argo.service 2>/dev/null || true
  fi
}

restart_all() {
  require_installed
  systemctl restart litebox.service
  if [ -f "$ARGO_SERVICE" ]; then
    systemctl restart litebox-argo.service || true
  fi
}

apply_changes() {
  require_installed
  need_root
  load_or_create_env
  install_cloudflared
  gen_cert
  save_env
  write_config
  write_services
  write_links
  enable_services
}

set_random_ports() {
  VLESS_PORT="$(random_port_between 10000 40000)"
  ANYTLS_PORT="$(random_port_between 10000 50000)"
  while [ "$ANYTLS_PORT" = "$VLESS_PORT" ]; do
    ANYTLS_PORT="$(random_port_between 10000 50000)"
  done
  TUIC_PORT="$(random_port_between 10000 50000)"
  while [ "$TUIC_PORT" = "$VLESS_PORT" ] || [ "$TUIC_PORT" = "$ANYTLS_PORT" ]; do
    TUIC_PORT="$(random_port_between 10000 50000)"
  done
  HY2_PORT="$(random_port_between 10000 50000)"
  while [ "$HY2_PORT" = "$VLESS_PORT" ] || [ "$HY2_PORT" = "$ANYTLS_PORT" ] || [ "$HY2_PORT" = "$TUIC_PORT" ]; do
    HY2_PORT="$(random_port_between 10000 50000)"
  done
  VMESS_LOCAL_PORT="$(random_port_between 18080 28080)"
}

set_default_ports() {
  VLESS_PORT=443
  ANYTLS_PORT=8443
  TUIC_PORT=9443
  HY2_PORT=8444
  VMESS_LOCAL_PORT=18080
}

prompt_port() {
  label="$1"
  current="$2"
  while :; do
    printf '%s [%s]: ' "$label" "$current"
    read -r value || exit 1
    [ -z "$value" ] && value="$current"
    if port_valid "$value"; then
      printf '%s\n' "$value"
      return
    fi
    log "invalid port, try again"
  done
}

change_ports_menu() {
  require_installed
  load_or_create_env
  while :; do
    printf '\n'
    log "Port settings"
    log "1. Use recommended default ports"
    log "2. Randomize all public ports"
    log "3. Set ports manually"
    log "0. Back"
    printf 'Choose [0-3]: '
    read -r action || exit 1
    case "$action" in
      1)
        set_default_ports
        apply_changes
        log "ports reset to defaults"
        break
        ;;
      2)
        set_random_ports
        apply_changes
        log "ports randomized"
        break
        ;;
      3)
        VLESS_PORT="$(prompt_port 'VLESS Reality port' "$VLESS_PORT")"
        ANYTLS_PORT="$(prompt_port 'AnyTLS port' "$ANYTLS_PORT")"
        TUIC_PORT="$(prompt_port 'TUIC v5 port' "$TUIC_PORT")"
        HY2_PORT="$(prompt_port 'Hysteria2 port' "$HY2_PORT")"
        VMESS_LOCAL_PORT="$(prompt_port 'VMess local port (127.0.0.1 only)' "$VMESS_LOCAL_PORT")"
        apply_changes
        log "ports updated"
        break
        ;;
      0) break ;;
      *) log "invalid selection" ;;
    esac
  done
}

argo_mode_text() {
  if [ -n "${LB_ARGO_TOKEN:-}" ]; then
    printf 'fixed'
  elif [ "${LB_ENABLE_TEMP_ARGO:-0}" = "1" ]; then
    printf 'temporary'
  else
    printf 'disabled'
  fi
}

set_argo_temp() {
  ARGO_TOKEN=""
  ARGO_DOMAIN=""
  ENABLE_TEMP_ARGO=1
  apply_changes
  log "temporary argo enabled"
}

set_argo_fixed() {
  printf 'Argo tunnel token: '
  read -r token || exit 1
  [ -n "$token" ] || die "token cannot be empty"
  printf 'Argo public domain: '
  read -r domain || exit 1
  [ -n "$domain" ] || die "domain cannot be empty"
  ARGO_TOKEN="$token"
  ARGO_DOMAIN="$domain"
  ENABLE_TEMP_ARGO=0
  apply_changes
  log "fixed argo enabled"
}

disable_argo() {
  ARGO_TOKEN=""
  ARGO_DOMAIN=""
  ENABLE_TEMP_ARGO=0
  apply_changes
  log "argo disabled"
}

argo_menu() {
  require_installed
  load_or_create_env
  while :; do
    printf '\n'
    log "Argo tunnel settings"
    log "Current mode: $(argo_mode_text)"
    [ -n "${LB_ARGO_DOMAIN:-}" ] && log "Current domain: $LB_ARGO_DOMAIN"
    log "1. Enable or refresh temporary Argo"
    log "2. Enable or refresh fixed Argo"
    log "3. Disable Argo"
    log "0. Back"
    printf 'Choose [0-3]: '
    read -r action || exit 1
    case "$action" in
      1) set_argo_temp; break ;;
      2) set_argo_fixed; break ;;
      3) disable_argo; break ;;
      0) break ;;
      *) log "invalid selection" ;;
    esac
  done
}

show_links() {
  require_installed
  load_or_create_env
  write_links
  cat "$LINKS_FILE"
  if [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    printf '\n'
    log "Temporary Argo hint:"
    log "Use 'sudo litebox logs 80' or 'sudo sb logs 80' to find the trycloudflare.com domain."
  fi
}

show_logs() {
  journalctl -u litebox.service -u litebox-argo.service -n "${1:-80}" --no-pager
}

status_all() {
  systemctl --no-pager --full status litebox.service || true
  systemctl --no-pager --full status litebox-argo.service 2>/dev/null || true
}

info_all() {
  require_installed
  [ -f "$LINKS_FILE" ] && cat "$LINKS_FILE" || die "not installed"
}

config_all() {
  require_installed
  cat "$CONF"
}

uninstall_all() {
  need_root
  systemctl disable --now litebox.service 2>/dev/null || true
  systemctl disable --now litebox-argo.service 2>/dev/null || true
  rm -f "$SERVICE" "$ARGO_SERVICE" "$CLI" "$SB_CLI"
  systemctl daemon-reload
  log "kept $BASE_DIR for credentials. remove it manually if you no longer need links."
}

show_menu() {
  while :; do
    printf '\n'
    log "Litebox quick menu"
    if is_installed; then
      load_or_create_env
      log "Installed: yes"
      log "Shortcut: sudo sb"
      log "Argo: $(argo_mode_text)"
      log "Ports: vless=$VLESS_PORT anytls=$ANYTLS_PORT tuic=$TUIC_PORT hy2=$HY2_PORT"
    else
      log "Installed: no"
      log "Shortcut after install: sudo sb"
    fi
    printf '\n'
    log "1. Install or reinstall Litebox"
    log "2. Uninstall Litebox"
    log "3. Argo tunnel settings"
    log "4. Change ports"
    log "6. Restart Litebox"
    log "9. Refresh and show node links"
    log "10. View logs"
    log "0. Exit"
    printf 'Choose [0-10]: '
    read -r action || exit 1
    case "$action" in
      1) install_all ;;
      2) uninstall_all ;;
      3) argo_menu ;;
      4) change_ports_menu ;;
      6) restart_all; log "services restarted" ;;
      9) show_links ;;
      10) show_logs 80 ;;
      0) break ;;
      *) log "invalid selection" ;;
    esac
  done
}

install_all() {
  need_root
  install_deps_hint
  install_sing_box
  load_or_create_env
  install_cloudflared
  gen_cert
  save_env
  write_config
  write_services
  write_cli
  write_links
  enable_services
  log "done. links: $LINKS_FILE"
  cat "$LINKS_FILE"
}

default_action() {
  prog="$(basename "$0")"
  case "$prog" in
    litebox|sb) printf 'menu' ;;
    *) printf 'install' ;;
  esac
}

case "${1:-$(default_action)}" in
  install) install_all ;;
  status) status_all ;;
  config) config_all ;;
  info) info_all ;;
  logs) show_logs "${2:-80}" ;;
  restart) restart_all ;;
  uninstall) uninstall_all ;;
  ports) change_ports_menu ;;
  argo) argo_menu ;;
  menu) show_menu ;;
  *) die "usage: $0 [install|status|config|info|logs [lines]|restart|uninstall|ports|argo|menu]" ;;
esac
