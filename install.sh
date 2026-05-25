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

SING_BOX_VERSION="${SING_BOX_VERSION:-latest}"
SERVER="${SERVER:-}"
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
TLS_SNI="${TLS_SNI:-bing.com}"
VMESS_WS_PATH="${VMESS_WS_PATH:-/vmess}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_TOKEN="${ARGO_TOKEN:-}"
ENABLE_TEMP_ARGO="${ENABLE_TEMP_ARGO:-0}"

ANYTLS_PORT="${ANYTLS_PORT:-8443}"
TUIC_PORT="${TUIC_PORT:-9443}"
VLESS_PORT="${VLESS_PORT:-443}"
HY2_PORT="${HY2_PORT:-8444}"
VMESS_LOCAL_PORT="${VMESS_LOCAL_PORT:-18080}"

log() { printf '%s\n' "$*"; }
die() { log "error: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = "0" ] || die "please run as root"; }
has() { command -v "$1" >/dev/null 2>&1; }

rand_hex() {
  if has openssl; then openssl rand -hex "$1"; else tr -dc 'a-f0-9' </dev/urandom | head -c "$(( $1 * 2 ))"; fi
}

rand_b64() {
  if has openssl; then openssl rand -base64 "$1" | tr -d '\n=' | tr '+/' '-_'; else rand_hex "$1"; fi
}

uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid; else
    printf '%s-%s-%s-%s-%s\n' "$(rand_hex 4)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 6)"
  fi
}

b64_nowrap() {
  if base64 --help 2>&1 | grep -q -- '-w'; then base64 -w 0; else base64 | tr -d '\n'; fi
}

public_ip() {
  [ -n "$SERVER" ] && { printf '%s\n' "$SERVER"; return; }
  for url in https://api.ipify.org https://ifconfig.me; do
    ip="$(curl -fsSL --connect-timeout 3 "$url" 2>/dev/null || true)"
    [ -n "$ip" ] && { printf '%s\n' "$ip"; return; }
  done
  hostname -I 2>/dev/null | awk '{print $1}'
}

download_url() {
  repo="$1"; pattern="$2"
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
  for c in curl tar openssl sed grep awk systemctl; do has "$c" || die "missing $c"; done
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
  [ -s "$CERT_DIR/cert.pem" ] && [ -s "$CERT_DIR/key.pem" ] && return 0
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -nodes -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
    -subj "/CN=$TLS_SNI" >/dev/null 2>&1
}

load_or_create_env() {
  mkdir -p "$BASE_DIR"
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  fi

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
EOF
  chmod 600 "$ENV_FILE"
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
  systemctl daemon-reload
}

write_cli() {
  cat >"$CLI" <<'EOF'
#!/usr/bin/env bash
set -eu

case "${1:-info}" in
  info)
    cat /etc/litebox/links.txt
    ;;
  config)
    cat /etc/litebox/config.json
    ;;
  status)
    systemctl --no-pager --full status litebox.service || true
    systemctl --no-pager --full status litebox-argo.service 2>/dev/null || true
    ;;
  restart)
    systemctl restart litebox.service
    systemctl restart litebox-argo.service 2>/dev/null || true
    ;;
  logs)
    journalctl -u litebox.service -u litebox-argo.service -n "${2:-80}" --no-pager
    ;;
  uninstall)
    systemctl disable --now litebox.service 2>/dev/null || true
    systemctl disable --now litebox-argo.service 2>/dev/null || true
    rm -f /etc/systemd/system/litebox.service /etc/systemd/system/litebox-argo.service
    systemctl daemon-reload
    echo "kept /etc/litebox for credentials. remove it manually if you no longer need links."
    ;;
  *)
    echo "usage: litebox [info|config|status|restart|logs [lines]|uninstall]" >&2
    exit 1
    ;;
esac
EOF
  chmod 0755 "$CLI"
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
EOF
  chmod 600 "$LINKS_FILE"
}

install_all() {
  need_root
  install_deps_hint
  install_sing_box
  install_cloudflared
  gen_cert
  load_or_create_env
  write_config
  write_services
  write_cli
  write_links
  systemctl enable --now litebox.service
  if [ -n "$ARGO_TOKEN" ] || [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    systemctl enable --now litebox-argo.service || true
  fi
  log "done. links: $LINKS_FILE"
  cat "$LINKS_FILE"
}

status_all() {
  systemctl --no-pager --full status litebox.service || true
  [ -f "$ARGO_SERVICE" ] && systemctl --no-pager --full status litebox-argo.service || true
}

info_all() {
  [ -f "$LINKS_FILE" ] && cat "$LINKS_FILE" || die "not installed"
}

uninstall_all() {
  need_root
  systemctl disable --now litebox.service 2>/dev/null || true
  systemctl disable --now litebox-argo.service 2>/dev/null || true
  rm -f "$SERVICE" "$ARGO_SERVICE"
  systemctl daemon-reload
  log "kept $BASE_DIR for credentials. remove it manually if you no longer need links."
}

case "${1:-install}" in
  install) install_all ;;
  status) status_all ;;
  info) info_all ;;
  uninstall) uninstall_all ;;
  *) die "usage: $0 [install|status|info|uninstall]" ;;
esac
