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
SERVICE=""
ARGO_SERVICE=""
CLI="/usr/local/bin/litebox"
LB_CLI="/usr/local/bin/lb"
LB_CLI_UPPER="/usr/local/bin/LB"
OLD_SB_CLI="/usr/local/bin/sb"
SCRIPT_URL="https://raw.githubusercontent.com/linlvyy/litebox-singbox-mini/main/install.sh"
RUN_LITEBOX="$BASE_DIR/run-litebox.sh"
RUN_ARGO="$BASE_DIR/run-argo.sh"
MAIN_LOG="$BASE_DIR/litebox.log"
ARGO_LOG="$BASE_DIR/argo.log"
LITEBOX_PID="/run/litebox.pid"
ARGO_PID="/run/litebox-argo.pid"
INIT_SYSTEM=""
OS_ID=""
OS_LIKE=""

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
OUTBOUND_MODE="${OUTBOUND_MODE:-}"
CUSTOM_UUID="${CUSTOM_UUID:-}"
FIREWALL_ACTION="${FIREWALL_ACTION:-1}"
TUIC_HOP_PORTS="${TUIC_HOP_PORTS:-}"
HY2_HOP_PORTS="${HY2_HOP_PORTS:-}"

log() { printf '%s\n' "$*"; }
die() { log "error: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = "0" ] || die "please run as root"; }
has() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  if [ -n "$OS_ID" ]; then
    return 0
  fi
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  fi
}

is_alpine() {
  detect_os
  [ "$OS_ID" = "alpine" ] && return 0
  printf '%s\n' "$OS_LIKE" | grep -Eq '(^| )alpine( |$)'
}

detect_init_system() {
  if [ -n "$INIT_SYSTEM" ]; then
    return 0
  fi
  if has systemctl; then
    INIT_SYSTEM="systemd"
    SERVICE="/etc/systemd/system/litebox.service"
    ARGO_SERVICE="/etc/systemd/system/litebox-argo.service"
    return 0
  fi
  if has rc-service && has rc-update; then
    INIT_SYSTEM="openrc"
    SERVICE="/etc/init.d/litebox"
    ARGO_SERVICE="/etc/init.d/litebox-argo"
    return 0
  fi
  INIT_SYSTEM="unknown"
  SERVICE="$BASE_DIR/litebox.service"
  ARGO_SERVICE="$BASE_DIR/litebox-argo.service"
}

service_reload() {
  detect_init_system
  case "$INIT_SYSTEM" in
    systemd) systemctl daemon-reload ;;
    openrc) true ;;
    *) die "unsupported init system: need systemd or openrc" ;;
  esac
}

service_enable_start() {
  detect_init_system
  name="$1"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl enable --now "$name"
      ;;
    openrc)
      rc-update add "$name" default >/dev/null 2>&1 || true
      rc-service "$name" restart >/dev/null 2>&1 || rc-service "$name" start
      ;;
    *)
      die "unsupported init system: need systemd or openrc"
      ;;
  esac
}

service_disable_stop() {
  detect_init_system
  name="$1"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl disable --now "$name" 2>/dev/null || true
      ;;
    openrc)
      rc-service "$name" stop >/dev/null 2>&1 || true
      rc-update del "$name" default >/dev/null 2>&1 || true
      ;;
    *)
      true
      ;;
  esac
}

service_restart_cmd() {
  detect_init_system
  name="$1"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl restart "$name"
      ;;
    openrc)
      rc-service "$name" restart
      ;;
    *)
      die "unsupported init system: need systemd or openrc"
      ;;
  esac
}

service_status_cmd() {
  detect_init_system
  name="$1"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl --no-pager --full status "$name"
      ;;
    openrc)
      rc-service "$name" status
      ;;
    *)
      die "unsupported init system: need systemd or openrc"
      ;;
  esac
}

show_combined_logs() {
  detect_init_system
  lines="${1:-80}"
  case "$INIT_SYSTEM" in
    systemd)
      journalctl -u litebox.service -u litebox-argo.service -n "$lines" --no-pager
      ;;
    openrc)
      [ -f "$MAIN_LOG" ] && tail -n "$lines" "$MAIN_LOG"
      [ -f "$ARGO_LOG" ] && tail -n "$lines" "$ARGO_LOG"
      ;;
    *)
      die "unsupported init system: need systemd or openrc"
      ;;
  esac
}

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

public_ipv6() {
  for url in https://api64.ipify.org https://ifconfig.me; do
    ip="$(curl -6 -fsSL --connect-timeout 3 "$url" 2>/dev/null || true)"
    [ -n "$ip" ] && {
      printf '%s\n' "$ip"
      return
    }
  done
  if has ip; then
    ip -6 addr show scope global 2>/dev/null |
      awk '/inet6/ {print $2}' |
      cut -d/ -f1 |
      head -n 1
  fi
}

local_ipv4() {
  if has ip; then
    ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
    return
  fi
  hostname -I 2>/dev/null | awk '{print $1}'
}

local_ipv6() {
  if has ip; then
    ip -6 addr show scope global 2>/dev/null |
      awk '/inet6/ {print $2}' |
      cut -d/ -f1 |
      head -n 1
    return
  fi
  true
}

download_url() {
  repo="$1"
  pattern="$2"
  curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
    sed -n 's/.*"browser_download_url": "\(.*\)".*/\1/p' |
    grep "$pattern" | head -n 1
}

release_asset_urls() {
  repo="$1"
  version="$2"
  if [ "$version" = "latest" ]; then
    api_url="https://api.github.com/repos/$repo/releases/latest"
  else
    case "$version" in
      v*) tag="$version" ;;
      *) tag="v$version" ;;
    esac
    api_url="https://api.github.com/repos/$repo/releases/tags/$tag"
  fi
  curl -fsSL "$api_url" |
    sed -n 's/.*"browser_download_url": "\(.*\)".*/\1/p'
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
  for c in curl tar openssl sed grep awk; do
    has "$c" || die "missing $c"
  done
  detect_init_system
  [ "$INIT_SYSTEM" != "unknown" ] || die "missing service manager: need systemd or openrc"
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

is_reserved_port() {
  case "$1" in
    80|443|8443) return 0 ;;
    *) return 1 ;;
  esac
}

random_list_port() {
  set -- "$@"
  count="$#"
  [ "$count" -gt 0 ] || return 1
  idx="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
  idx="$(( idx % count + 1 ))"
  eval "printf '%s\n' \"\${$idx}\""
}

random_service_port() {
  while :; do
    port="$(random_port_between 10000 60000)"
    is_reserved_port "$port" && continue
    printf '%s\n' "$port"
    return
  done
}

is_forbidden_reality_sni() {
  domain="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$domain" in
    cloudflare.com|*.cloudflare.com|trycloudflare.com|*.trycloudflare.com|workers.dev|*.workers.dev|pages.dev|*.pages.dev|cloudflare-ech.com|*.cloudflare-ech.com|saas.sin.fan)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_security_settings() {
  if is_forbidden_reality_sni "$REALITY_SNI"; then
    die "Reality 伪装域名不能使用 Cloudflare/Argo/优选域名: $REALITY_SNI"
  fi
}

apply_saved_settings() {
  REALITY_SNI="${REALITY_SNI:-${LB_REALITY_SNI:-www.microsoft.com}}"
  TLS_SNI="${TLS_SNI:-${LB_TLS_SNI:-bing.com}}"
  VMESS_WS_PATH="${VMESS_WS_PATH:-${LB_VMESS_WS_PATH:-}}"
  ARGO_DOMAIN="${ARGO_DOMAIN:-${LB_ARGO_DOMAIN:-}}"
  ARGO_TOKEN="${ARGO_TOKEN:-${LB_ARGO_TOKEN:-}}"
  ENABLE_TEMP_ARGO="${ENABLE_TEMP_ARGO:-${LB_ENABLE_TEMP_ARGO:-0}}"
  ANYTLS_PORT="${ANYTLS_PORT:-${LB_ANYTLS_PORT:-}}"
  TUIC_PORT="${TUIC_PORT:-${LB_TUIC_PORT:-}}"
  VLESS_PORT="${VLESS_PORT:-${LB_VLESS_PORT:-}}"
  HY2_PORT="${HY2_PORT:-${LB_HY2_PORT:-}}"
  VMESS_LOCAL_PORT="${VMESS_LOCAL_PORT:-${LB_VMESS_LOCAL_PORT:-}}"
  OUTBOUND_MODE="${OUTBOUND_MODE:-${LB_OUTBOUND_MODE:-auto}}"
  TUIC_HOP_PORTS="${TUIC_HOP_PORTS:-${LB_TUIC_HOP_PORTS:-}}"
  HY2_HOP_PORTS="${HY2_HOP_PORTS:-${LB_HY2_HOP_PORTS:-}}"
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
LB_OUTBOUND_MODE='$OUTBOUND_MODE'
LB_TUIC_HOP_PORTS='$TUIC_HOP_PORTS'
LB_HY2_HOP_PORTS='$HY2_HOP_PORTS'
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
  if [ -z "${VLESS_PORT:-}" ] || [ -z "${ANYTLS_PORT:-}" ] || [ -z "${TUIC_PORT:-}" ] || [ -z "${HY2_PORT:-}" ] || [ -z "${VMESS_LOCAL_PORT:-}" ]; then
    set_default_ports
  fi
  case "$VMESS_WS_PATH" in
    ""|"/vmess") VMESS_WS_PATH="/${LB_UUID}-vm" ;;
  esac
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

  validate_security_settings
  save_env
}

uuid_valid() {
  printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

reset_identity() {
  mkdir -p "$BASE_DIR"
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  fi
  apply_saved_settings
  LB_SERVER="${LB_SERVER:-$(public_ip)}"
  LB_UUID="${CUSTOM_UUID:-}"
  LB_PASSWORD=""
  LB_ANYTLS_PASSWORD=""
  LB_TUIC_PASSWORD=""
  LB_HY2_PASSWORD=""
  LB_HY2_OBFS=""
  LB_SHORT_ID=""
  LB_REALITY_PRIVATE=""
  LB_REALITY_PUBLIC=""
  VMESS_WS_PATH=""
  save_env
}

install_sing_box() {
  arch="$(arch_name)"
  if is_alpine && has apk; then
    log "detected Alpine Linux, trying apk add sing-box first"
    if apk add --no-cache sing-box >/dev/null 2>&1; then
      found="$(command -v sing-box || true)"
      [ -n "$found" ] || die "apk installed sing-box but binary was not found in PATH"
      if [ "$found" != "$BIN" ]; then
        ln -sf "$found" "$BIN"
      fi
      return 0
    fi
    log "apk add sing-box unavailable, falling back to upstream tarball"
  fi
  tmp="$(mktemp -d)"
  urls="$(release_asset_urls SagerNet/sing-box "$SING_BOX_VERSION")"
  exact_url="$(printf '%s\n' "$urls" | grep -E "/sing-box-[^/]+-linux-${arch}\.tar\.gz$" | head -n 1)"
  musl_url="$(printf '%s\n' "$urls" | grep -E "/sing-box-[^/]+-linux-${arch}-musl\.tar\.gz$" | head -n 1)"
  anylinux_url="$(printf '%s\n' "$urls" | grep -E "/sing-box-[^/]+-linux-${arch}-anylinux\.tar\.gz$" | head -n 1)"
  other_url="$(printf '%s\n' "$urls" | grep -E "/sing-box-[^/]+-linux-${arch}[^/]*\.tar\.gz$" | grep -Ev '(-glibc|-gnu)\.tar\.gz$' | head -n 1)"
  glibc_url="$(printf '%s\n' "$urls" | grep -E "/sing-box-[^/]+-linux-${arch}-(glibc|gnu)\.tar\.gz$" | head -n 1)"

  if is_alpine; then
    url="${exact_url:-${musl_url:-${anylinux_url:-$other_url}}}"
  else
    url="${exact_url:-${other_url:-${glibc_url:-${musl_url:-$anylinux_url}}}}"
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
  [ -x "$CLOUDFLARED_BIN" ] && return 0
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
  dns_block=""
  direct_resolver_line=""
  if [ "$OUTBOUND_MODE" != "auto" ]; then
    dns_block="$(cat <<EOF
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "local"
      }
    ]
  },
EOF
)"
    direct_resolver_line="$(printf ',\n      "domain_resolver": {\n        "server": "local",\n        "strategy": "%s"\n      }' "$OUTBOUND_MODE")"
  fi
  cat >"$CONF" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": false
  },
$dns_block
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
      "tag": "direct"$direct_resolver_line
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
  detect_init_system
  mkdir -p "$BASE_DIR"

  cat >"$RUN_LITEBOX" <<EOF
#!/bin/sh
exec "$BIN" run -c "$CONF" >>"$MAIN_LOG" 2>&1
EOF
  chmod 0755 "$RUN_LITEBOX"

  if [ "$INIT_SYSTEM" = "systemd" ]; then
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
  else
    cat >"$SERVICE" <<EOF
#!/sbin/openrc-run
description="Litebox sing-box nodes"
supervisor="supervise-daemon"
command="$BIN"
command_args="run -c $CONF"
pidfile="$LITEBOX_PID"
output_log="$MAIN_LOG"
error_log="$MAIN_LOG"
respawn_delay=5

depend() {
  need net
}
EOF
    chmod 0755 "$SERVICE"
  fi

  if [ -n "$ARGO_TOKEN" ] || [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    if [ -n "$ARGO_TOKEN" ]; then
      argo_cmd="$CLOUDFLARED_BIN tunnel --no-autoupdate run --token $ARGO_TOKEN"
    else
      argo_cmd="$CLOUDFLARED_BIN tunnel --no-autoupdate --url http://127.0.0.1:$VMESS_LOCAL_PORT"
    fi
    cat >"$RUN_ARGO" <<EOF
#!/bin/sh
exec $argo_cmd >>"$ARGO_LOG" 2>&1
EOF
    chmod 0755 "$RUN_ARGO"
    : >"$ARGO_LOG"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
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
StandardOutput=append:$BASE_DIR/argo.log
StandardError=append:$BASE_DIR/argo.log

[Install]
WantedBy=multi-user.target
EOF
    else
      cat >"$ARGO_SERVICE" <<EOF
#!/sbin/openrc-run
description="Litebox Cloudflare Argo tunnel"
supervisor="supervise-daemon"
command="$RUN_ARGO"
pidfile="$ARGO_PID"
output_log="$ARGO_LOG"
error_log="$ARGO_LOG"
respawn_delay=5

depend() {
  need net litebox
}
EOF
      chmod 0755 "$ARGO_SERVICE"
    fi
  else
    rm -f "$ARGO_SERVICE" "$RUN_ARGO"
  fi

  service_reload
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
  rm -f "$OLD_SB_CLI"
  ln -sf "$CLI" "$LB_CLI"
  ln -sf "$CLI" "$LB_CLI_UPPER"
}

extract_temp_argo_domain() {
  extract_best_domain_stream() {
    grep -Eo '[A-Za-z0-9-]+\.trycloudflare\.com' |
      awk '$0 != "s.trycloudflare.com" {print length($0), $0}' |
      sort -n |
      tail -n 1 |
      awk '{print $2}'
  }
  if [ -f "$BASE_DIR/argo.log" ]; then
    domain="$(extract_best_domain_stream <"$BASE_DIR/argo.log" || true)"
    [ -n "$domain" ] && {
      printf '%s\n' "$domain"
      return
    }
  fi
  if has journalctl; then
    journalctl -u litebox-argo.service -n 120 --no-pager 2>/dev/null | extract_best_domain_stream
  fi
}

wait_temp_argo_domain() {
  tries="${1:-12}"
  i=0
  while [ "$i" -lt "$tries" ]; do
    domain="$(extract_temp_argo_domain)"
    [ -n "$domain" ] && {
      printf '%s\n' "$domain"
      return 0
    }
    sleep 1
    i=$((i + 1))
  done
  return 1
}

current_argo_host() {
  if [ -n "${ARGO_DOMAIN:-}" ]; then
    printf '%s\n' "$ARGO_DOMAIN"
    return
  fi
  if [ "${ENABLE_TEMP_ARGO:-0}" = "1" ]; then
    extract_temp_argo_domain
  fi
}

refresh_temp_argo_links() {
  [ "$ENABLE_TEMP_ARGO" = "1" ] || return 0
  service_restart_cmd litebox-argo >/dev/null 2>&1 || true
  if host="$(wait_temp_argo_domain 20)"; then
    write_links
    log "临时 Argo HOST: $host"
    return 0
  fi
  write_links
  log "临时 Argo HOST 暂未获取到，请稍后用 'sudo LB logs 120' 查看 cloudflared 日志。"
  return 1
}

write_links() {
  server="$LB_SERVER"
  vless="vless://$LB_UUID@$server:$VLESS_PORT?encryption=none&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$LB_REALITY_PUBLIC&sid=$LB_SHORT_ID&type=tcp&flow=xtls-rprx-vision#$NAME-vless-reality"
  anytls="anytls://$LB_ANYTLS_PASSWORD@$server:$ANYTLS_PORT?security=tls&sni=$TLS_SNI&insecure=1#$NAME-anytls"
  tuic="tuic://$LB_UUID:$LB_TUIC_PASSWORD@$server:$TUIC_PORT?congestion_control=bbr&alpn=h3&allow_insecure=1#$NAME-tuic-v5"
  hy2="hysteria2://$LB_HY2_PASSWORD@$server:$HY2_PORT?obfs=salamander&obfs-password=$LB_HY2_OBFS&sni=$TLS_SNI&insecure=1#$NAME-hysteria2"

  if [ -n "$ARGO_DOMAIN" ]; then
    vmess_add="$ARGO_DOMAIN"
    vmess_port="443"
    vmess_host="$ARGO_DOMAIN"
    vmess_sni="$ARGO_DOMAIN"
  elif [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    temp_argo_domain="$(extract_temp_argo_domain)"
    vmess_add="saas.sin.fan"
    vmess_port="8443"
    vmess_host="${temp_argo_domain:-<your-trycloudflare-domain>}"
    vmess_sni="$vmess_host"
  else
    vmess_add="<argo-not-enabled>"
    vmess_port="443"
    vmess_host="<argo-not-enabled>"
    vmess_sni="$vmess_host"
  fi
  vmess_path="${VMESS_WS_PATH#/}"
  vmess_json="$(printf '{"v":"2","ps":"%s-vmess-ws-argo","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","fp":"chrome"}' "$NAME" "$vmess_add" "$vmess_port" "$LB_UUID" "$vmess_host" "$vmess_path" "$vmess_sni" | b64_nowrap)"

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
Outbound mode: $OUTBOUND_MODE
Shortcut: sudo LB
EOF
  chmod 600 "$LINKS_FILE"
}

enable_services() {
  service_enable_start litebox
  if [ -n "$ARGO_TOKEN" ] || [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    service_enable_start litebox-argo || true
  else
    service_disable_stop litebox-argo
  fi
}

outbound_mode_text() {
  case "$OUTBOUND_MODE" in
    auto) printf '自动' ;;
    prefer_ipv4) printf 'IPv4 优先' ;;
    prefer_ipv6) printf 'IPv6 优先' ;;
    ipv4_only) printf '仅 IPv4' ;;
    ipv6_only) printf '仅 IPv6' ;;
    *) printf '%s' "$OUTBOUND_MODE" ;;
  esac
}

restart_all() {
  require_installed
  service_restart_cmd litebox
  if [ -f "$ARGO_SERVICE" ]; then
    service_restart_cmd litebox-argo || true
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
  apply_port_hops
  if [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    refresh_temp_argo_links || true
  fi
}

set_random_ports() {
  VLESS_PORT="$(random_service_port)"
  ANYTLS_PORT="$(random_service_port)"
  while [ "$ANYTLS_PORT" = "$VLESS_PORT" ]; do
    ANYTLS_PORT="$(random_service_port)"
  done
  TUIC_PORT="$(random_service_port)"
  while [ "$TUIC_PORT" = "$VLESS_PORT" ] || [ "$TUIC_PORT" = "$ANYTLS_PORT" ]; do
    TUIC_PORT="$(random_service_port)"
  done
  HY2_PORT="$(random_service_port)"
  while [ "$HY2_PORT" = "$VLESS_PORT" ] || [ "$HY2_PORT" = "$ANYTLS_PORT" ] || [ "$HY2_PORT" = "$TUIC_PORT" ]; do
    HY2_PORT="$(random_service_port)"
  done
  VMESS_LOCAL_PORT="$(random_list_port 8080 2052 2053 2082 2083 2086 2087 2095 2096 8880)"
}

set_default_ports() {
  set_random_ports
}

open_service_ports() {
  tcp_ports="$VLESS_PORT,$ANYTLS_PORT"
  udp_ports="$TUIC_PORT,$HY2_PORT"
  [ -n "$TUIC_HOP_PORTS" ] && udp_ports="$udp_ports,$TUIC_HOP_PORTS"
  [ -n "$HY2_HOP_PORTS" ] && udp_ports="$udp_ports,$HY2_HOP_PORTS"

  if has ufw; then
    ufw --force disable >/dev/null 2>&1 || true
  fi
  if has systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^firewalld\.service'; then
    systemctl disable --now firewalld >/dev/null 2>&1 || true
  fi
  if has iptables; then
    iptables -C INPUT -p tcp -m multiport --dports "$tcp_ports" -j ACCEPT >/dev/null 2>&1 ||
      iptables -I INPUT -p tcp -m multiport --dports "$tcp_ports" -j ACCEPT >/dev/null 2>&1 || true
    iptables -C INPUT -p udp -m multiport --dports "$udp_ports" -j ACCEPT >/dev/null 2>&1 ||
      iptables -I INPUT -p udp -m multiport --dports "$udp_ports" -j ACCEPT >/dev/null 2>&1 || true
  fi
  if has ip6tables; then
    ip6tables -C INPUT -p tcp -m multiport --dports "$tcp_ports" -j ACCEPT >/dev/null 2>&1 ||
      ip6tables -I INPUT -p tcp -m multiport --dports "$tcp_ports" -j ACCEPT >/dev/null 2>&1 || true
    ip6tables -C INPUT -p udp -m multiport --dports "$udp_ports" -j ACCEPT >/dev/null 2>&1 ||
      ip6tables -I INPUT -p udp -m multiport --dports "$udp_ports" -j ACCEPT >/dev/null 2>&1 || true
  fi
}

clear_port_hops() {
  if has iptables; then
    oldifs="$IFS"
    IFS=','
    for port in $TUIC_HOP_PORTS; do
      [ -n "$port" ] || continue
      while iptables -t nat -C PREROUTING -p udp --dport "$port" -m comment --comment litebox-tuic-hop -j REDIRECT --to-ports "$TUIC_PORT" >/dev/null 2>&1; do
        iptables -t nat -D PREROUTING -p udp --dport "$port" -m comment --comment litebox-tuic-hop -j REDIRECT --to-ports "$TUIC_PORT" >/dev/null 2>&1 || break
      done
    done
    for port in $HY2_HOP_PORTS; do
      [ -n "$port" ] || continue
      while iptables -t nat -C PREROUTING -p udp --dport "$port" -m comment --comment litebox-hy2-hop -j REDIRECT --to-ports "$HY2_PORT" >/dev/null 2>&1; do
        iptables -t nat -D PREROUTING -p udp --dport "$port" -m comment --comment litebox-hy2-hop -j REDIRECT --to-ports "$HY2_PORT" >/dev/null 2>&1 || break
      done
    done
    IFS="$oldifs"
  fi
  if has ip6tables; then
    oldifs="$IFS"
    IFS=','
    for port in $TUIC_HOP_PORTS; do
      [ -n "$port" ] || continue
      while ip6tables -t nat -C PREROUTING -p udp --dport "$port" -m comment --comment litebox-tuic-hop -j REDIRECT --to-ports "$TUIC_PORT" >/dev/null 2>&1; do
        ip6tables -t nat -D PREROUTING -p udp --dport "$port" -m comment --comment litebox-tuic-hop -j REDIRECT --to-ports "$TUIC_PORT" >/dev/null 2>&1 || break
      done
    done
    for port in $HY2_HOP_PORTS; do
      [ -n "$port" ] || continue
      while ip6tables -t nat -C PREROUTING -p udp --dport "$port" -m comment --comment litebox-hy2-hop -j REDIRECT --to-ports "$HY2_PORT" >/dev/null 2>&1; do
        ip6tables -t nat -D PREROUTING -p udp --dport "$port" -m comment --comment litebox-hy2-hop -j REDIRECT --to-ports "$HY2_PORT" >/dev/null 2>&1 || break
      done
    done
    IFS="$oldifs"
  fi
}

apply_port_hops() {
  clear_port_hops
  if has iptables; then
    oldifs="$IFS"
    IFS=','
    for port in $TUIC_HOP_PORTS; do
      [ -n "$port" ] || continue
      iptables -t nat -A PREROUTING -p udp --dport "$port" -m comment --comment litebox-tuic-hop -j REDIRECT --to-ports "$TUIC_PORT" >/dev/null 2>&1 || true
    done
    for port in $HY2_HOP_PORTS; do
      [ -n "$port" ] || continue
      iptables -t nat -A PREROUTING -p udp --dport "$port" -m comment --comment litebox-hy2-hop -j REDIRECT --to-ports "$HY2_PORT" >/dev/null 2>&1 || true
    done
    IFS="$oldifs"
  fi
  if has ip6tables; then
    oldifs="$IFS"
    IFS=','
    for port in $TUIC_HOP_PORTS; do
      [ -n "$port" ] || continue
      ip6tables -t nat -A PREROUTING -p udp --dport "$port" -m comment --comment litebox-tuic-hop -j REDIRECT --to-ports "$TUIC_PORT" >/dev/null 2>&1 || true
    done
    for port in $HY2_HOP_PORTS; do
      [ -n "$port" ] || continue
      ip6tables -t nat -A PREROUTING -p udp --dport "$port" -m comment --comment litebox-hy2-hop -j REDIRECT --to-ports "$HY2_PORT" >/dev/null 2>&1 || true
    done
    IFS="$oldifs"
  fi
}

hop_ports_valid() {
  input="$(printf '%s' "$1" | tr '，' ',')"
  [ -z "$input" ] && return 0
  oldifs="$IFS"
  IFS=','
  for port in $input; do
    [ -n "$port" ] || {
      IFS="$oldifs"
      return 1
    }
    port_valid "$port" || {
      IFS="$oldifs"
      return 1
    }
  done
  IFS="$oldifs"
  return 0
}

prompt_hop_ports() {
  label="$1"
  current="$2"
  while :; do
    printf '%s [%s]: ' "$label" "${current:-留空表示关闭}" >&2
    read -r value || exit 1
    [ -z "$value" ] && value="$current"
    value="$(printf '%s' "$value" | tr '，' ',')"
    if hop_ports_valid "$value"; then
      printf '%s\n' "$value"
      return
    fi
    log "端口格式无效，请输入逗号分隔的端口列表，例如 30000,30001" >&2
  done
}

choose_firewall_action() {
  while :; do
    printf '\n'
    log "是否开放端口，关闭防火墙？"
    log "1、是，执行 (回车默认)"
    log "2、否，跳过！自行处理"
    printf '请选择【1-2】：'
    read -r firewall_choice || exit 1
    case "${firewall_choice:-1}" in
      1)
        FIREWALL_ACTION=1
        return 0
        ;;
      2)
        FIREWALL_ACTION=2
        return 0
        ;;
      *)
        log "无效选择"
        ;;
    esac
  done
}

switch_outbound_menu() {
  if is_installed; then
    load_or_create_env
  else
    apply_saved_settings
  fi
  while :; do
    printf '\n'
    log "IPv4 / IPv6 出口切换"
    log "当前模式: $(outbound_mode_text)"
    log "1. 自动"
    log "2. IPv4 优先"
    log "3. IPv6 优先"
    log "4. 仅 IPv4"
    log "5. 仅 IPv6"
    log "0. 返回上层"
    printf '请选择 [0-5]: '
    read -r action || exit 1
    case "$action" in
      1) OUTBOUND_MODE="auto" ;;
      2) OUTBOUND_MODE="prefer_ipv4" ;;
      3) OUTBOUND_MODE="prefer_ipv6" ;;
      4) OUTBOUND_MODE="ipv4_only" ;;
      5) OUTBOUND_MODE="ipv6_only" ;;
      0) break ;;
      *) log "无效选择"; continue ;;
    esac
    if [ "$action" != "0" ]; then
      if is_installed; then
        apply_changes
      fi
      log "出口模式已切换为: $(outbound_mode_text)"
      break
    fi
  done
}

prompt_port() {
  label="$1"
  current="$2"
  while :; do
    printf '%s [%s]: ' "$label" "$current" >&2
    read -r value || exit 1
    [ -z "$value" ] && value="$current"
    if port_valid "$value"; then
      printf '%s\n' "$value"
      return
    fi
    log "端口无效，请重新输入" >&2
  done
}

change_ports_menu() {
  if is_installed; then
    load_or_create_env
  else
    apply_saved_settings
  fi
  while :; do
    printf '\n'
    log "端口设置"
    log "1. 重新随机推荐端口"
    log "2. 手动自定义端口"
    log "3. 设置 TUIC / Hysteria2 端口跳跃"
    log "0. 返回上层"
    printf '请选择 [0-3] (默认 1): '
    read -r action || exit 1
    case "${action:-1}" in
      1)
        set_default_ports
        if is_installed; then
          apply_changes
        fi
        log "已切换为随机推荐端口"
        break
        ;;
      2)
        VLESS_PORT="$(prompt_port 'VLESS Reality 端口' "$VLESS_PORT")"
        ANYTLS_PORT="$(prompt_port 'AnyTLS 端口' "$ANYTLS_PORT")"
        TUIC_PORT="$(prompt_port 'TUIC v5 端口' "$TUIC_PORT")"
        HY2_PORT="$(prompt_port 'Hysteria2 端口' "$HY2_PORT")"
        VMESS_LOCAL_PORT="$(prompt_port 'WS 本地端口(仅 127.0.0.1)' "$VMESS_LOCAL_PORT")"
        if is_installed; then
          apply_changes
        fi
        log "端口已更新"
        break
        ;;
      3)
        TUIC_HOP_PORTS="$(prompt_hop_ports 'TUIC v5 跳跃端口(逗号分隔)' "$TUIC_HOP_PORTS")"
        HY2_HOP_PORTS="$(prompt_hop_ports 'Hysteria2 跳跃端口(逗号分隔)' "$HY2_HOP_PORTS")"
        if is_installed; then
          apply_changes
        fi
        log "TUIC / Hysteria2 跳跃端口已更新"
        break
        ;;
      0) break ;;
      *) log "无效选择" ;;
    esac
  done
}

argo_mode_text() {
  if [ -n "${ARGO_TOKEN:-${LB_ARGO_TOKEN:-}}" ]; then
    printf '固定隧道'
  elif [ "${ENABLE_TEMP_ARGO:-${LB_ENABLE_TEMP_ARGO:-0}}" = "1" ]; then
    printf '临时隧道'
  else
    printf '已关闭'
  fi
}

set_argo_temp() {
  ARGO_TOKEN=""
  ARGO_DOMAIN=""
  ENABLE_TEMP_ARGO=1
  apply_changes
  log "已启用临时 Argo。"
}

set_argo_fixed() {
  printf '请输入 Argo 隧道 Token: '
  read -r token || exit 1
  [ -n "$token" ] || die "Token 不能为空"
  printf '请输入固定 Argo 域名: '
  read -r domain || exit 1
  [ -n "$domain" ] || die "域名不能为空"
  ARGO_TOKEN="$token"
  ARGO_DOMAIN="$domain"
  ENABLE_TEMP_ARGO=0
  apply_changes
  log "已启用固定 Argo。"
}

disable_argo() {
  ARGO_TOKEN=""
  ARGO_DOMAIN=""
  ENABLE_TEMP_ARGO=0
  apply_changes
  log "已关闭 Argo。"
}

disable_temp_argo() {
  [ "$ENABLE_TEMP_ARGO" = "1" ] || {
    log "当前没有启用 Argo 临时隧道。"
    return 0
  }
  ARGO_TOKEN=""
  ARGO_DOMAIN=""
  ENABLE_TEMP_ARGO=0
  apply_changes
  log "已停止 Argo 临时隧道。"
}

disable_fixed_argo() {
  [ -n "$ARGO_TOKEN" ] || {
    log "当前没有启用 Argo 固定隧道。"
    return 0
  }
  ARGO_TOKEN=""
  ARGO_DOMAIN=""
  ENABLE_TEMP_ARGO=0
  apply_changes
  log "已停止 Argo 固定隧道。"
}

temp_argo_menu() {
  while :; do
    printf '\n'
    log "Argo 临时隧道"
    argo_host="$(current_argo_host)"
    [ -n "$argo_host" ] && log "当前 HOST: $argo_host"
    log "1. 重置 Argo 临时隧道域名"
    log "2. 停止 Argo 临时隧道"
    log "0. 返回上层"
    printf '请选择 [0-2] (默认 1): '
    read -r action || exit 1
    case "${action:-1}" in
      1) set_argo_temp; break ;;
      2) disable_temp_argo; break ;;
      0) break ;;
      *) log "无效选择" ;;
    esac
  done
}

fixed_argo_menu() {
  while :; do
    printf '\n'
    log "Argo 固定隧道"
    [ -n "$ARGO_DOMAIN" ] && log "当前固定域名: $ARGO_DOMAIN"
    log "1. 添加或更新 Argo 固定隧道"
    log "2. 停止 Argo 固定隧道"
    log "0. 返回上层"
    printf '请选择 [0-2] (默认 1): '
    read -r action || exit 1
    case "${action:-1}" in
      1) set_argo_fixed; break ;;
      2) disable_fixed_argo; break ;;
      0) break ;;
      *) log "无效选择" ;;
    esac
  done
}

argo_menu() {
  require_installed
  load_or_create_env
  while :; do
    printf '\n'
    log "Argo 隧道设置"
    log "当前模式: $(argo_mode_text)"
    argo_host="$(current_argo_host)"
    [ -n "$argo_host" ] && log "当前 HOST: $argo_host"
    log "1. 添加或者删除 Argo 临时隧道"
    log "2. 添加或者删除 Argo 固定隧道"
    log "0. 返回上层"
    printf '请选择 [0-2] (默认 1): '
    read -r action || exit 1
    case "${action:-1}" in
      1) temp_argo_menu ;;
      2) fixed_argo_menu ;;
      0) break ;;
      *) log "无效选择" ;;
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
    log "临时 Argo 提示:"
    log "请用 'sudo litebox logs 80'、'sudo LB logs 80' 或 'sudo lb logs 80' 查看 trycloudflare.com 域名。"
  fi
  printf '\n按回车返回主菜单...'
  read -r _ || exit 1
}

show_logs() {
  show_combined_logs "${1:-80}"
}

status_all() {
  service_status_cmd litebox || true
  if [ -f "$ARGO_SERVICE" ]; then
    service_status_cmd litebox-argo || true
  fi
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
  service_disable_stop litebox
  service_disable_stop litebox-argo
  clear_port_hops
  rm -f "$SERVICE" "$ARGO_SERVICE" "$CLI" "$LB_CLI" "$LB_CLI_UPPER" "$OLD_SB_CLI" "$BIN" "$CLOUDFLARED_BIN" "$RUN_LITEBOX" "$RUN_ARGO"
  rm -rf "$BASE_DIR"
  service_reload
  log "Litebox 已彻底卸载完成。"
}

install_menu() {
  apply_saved_settings
  CUSTOM_UUID=""
  while :; do
    printf '\n'
    log "安装设置"
    log "1. 使用随机推荐端口安装"
    log "2. 自定义端口后安装"
    log "0. 返回主菜单"
    if is_installed; then
      printf '\n'
      log "Litebox 当前已经安装。"
      log "如果要重新安装，请先选择主菜单里的“8. 彻底卸载 Litebox”，再重新执行安装。"
    fi
    printf '请选择 [0-2] (默认 1): '
    read -r action || exit 1
    case "${action:-1}" in
      1)
        if is_installed; then
          break
        fi
        set_default_ports
        choose_uuid_mode
        choose_firewall_action
        install_all
        break
        ;;
      2)
        if is_installed; then
          break
        fi
        set_default_ports
        change_ports_menu
        choose_uuid_mode
        choose_firewall_action
        install_all
        break
        ;;
      0) break ;;
      *) log "无效选择" ;;
    esac
  done
}

choose_uuid_mode() {
  while :; do
    printf '\n'
    log "UUID 设置"
    log "1. 每次重新随机生成 UUID"
    log "2. 手动输入 UUID"
    printf '请选择 [1-2] (默认 1): '
    read -r uuid_mode || exit 1
    case "${uuid_mode:-1}" in
      1)
        CUSTOM_UUID=""
        reset_identity
        return 0
        ;;
      2)
        printf '请输入自定义 UUID: '
        read -r custom_uuid_input || exit 1
        if uuid_valid "$custom_uuid_input"; then
          CUSTOM_UUID="$custom_uuid_input"
          reset_identity
          return 0
        fi
        log "UUID 格式无效，请重新输入。"
        ;;
      *)
        log "无效选择"
        ;;
    esac
  done
}

show_menu() {
  while :; do
    printf '\n'
    log "Litebox 快捷菜单"
    current_ipv4="$(local_ipv4 || true)"
    current_ipv6="$(local_ipv6 || true)"
    if is_installed; then
      load_or_create_env
      current_ipv4="${LB_SERVER:-$current_ipv4}"
      log "安装状态: 已安装"
      log "快捷命令: sudo LB / sudo lb"
      log "Argo 状态: $(argo_mode_text)"
      argo_host="$(current_argo_host)"
      [ -n "$argo_host" ] && log "Argo HOST: $argo_host"
      log "本机 IPv4: ${current_ipv4:-未检测到}"
      log "本机 IPv6: ${current_ipv6:-未检测到}"
      log "出口模式: $(outbound_mode_text)"
      log "端口: vless=$VLESS_PORT anytls=$ANYTLS_PORT tuic=$TUIC_PORT hy2=$HY2_PORT ws=$VMESS_LOCAL_PORT"
      [ -n "$TUIC_HOP_PORTS" ] && log "TUIC 跳跃端口: $TUIC_HOP_PORTS"
      [ -n "$HY2_HOP_PORTS" ] && log "HY2 跳跃端口: $HY2_HOP_PORTS"
    else
      apply_saved_settings
      if [ -z "${VLESS_PORT:-}" ] || [ -z "${ANYTLS_PORT:-}" ] || [ -z "${TUIC_PORT:-}" ] || [ -z "${HY2_PORT:-}" ] || [ -z "${VMESS_LOCAL_PORT:-}" ]; then
        set_default_ports
      fi
      current_ipv4="$(public_ip || printf '%s' "$current_ipv4")"
      log "安装状态: 未安装"
      log "安装后快捷命令: sudo LB / sudo lb"
      log "本机 IPv4: ${current_ipv4:-未检测到}"
      log "本机 IPv6: ${current_ipv6:-未检测到}"
      log "出口模式: $(outbound_mode_text)"
      log "默认端口: vless=$VLESS_PORT anytls=$ANYTLS_PORT tuic=$TUIC_PORT hy2=$HY2_PORT ws=$VMESS_LOCAL_PORT"
    fi
    printf '\n'
    log "1. 安装 Litebox"
    log "2. Argo 隧道设置"
    log "3. 端口设置"
    log "4. IPv4 / IPv6 出口切换"
    log "5. 重启 Litebox"
    log "6. 刷新并查看节点"
    log "7. 查看运行日志"
    log "8. 彻底卸载 Litebox"
    log "0. 退出脚本"
    printf '请选择 [0-8]: '
    read -r action || exit 1
    case "$action" in
      1) install_menu ;;
      2) argo_menu ;;
      3) change_ports_menu ;;
      4) switch_outbound_menu ;;
      5) restart_all; log "服务已重启" ;;
      6) show_links ;;
      7) show_logs 80 ;;
      8)
        uninstall_all
        break
        ;;
      0) break ;;
      *) log "无效选择" ;;
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
  if [ "${FIREWALL_ACTION:-1}" = "1" ]; then
    open_service_ports
  fi
  apply_port_hops
  enable_services
  if [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    refresh_temp_argo_links || true
  fi
  log "安装完成，节点信息文件: $LINKS_FILE"
  cat "$LINKS_FILE"
}

default_action() {
  printf 'menu'
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
  *) die "用法: $0 [install|status|config|info|logs [lines]|restart|uninstall|ports|argo|menu]" ;;
esac
