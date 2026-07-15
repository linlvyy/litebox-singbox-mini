#!/usr/bin/env bash
set -eu

NAME="litebox"
HOP_PORTS_MAX=50
BIN="/usr/local/bin/sing-box"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
BASE_DIR="/etc/litebox"
CONF="$BASE_DIR/config.json"
ENV_FILE="$BASE_DIR/env"
LINKS_FILE="$BASE_DIR/links.txt"
CERT_DIR="$BASE_DIR/cert"
SING_BOX_MARKER="$BASE_DIR/installed-by-litebox.sing-box"
CF_MARKER="$BASE_DIR/installed-by-litebox.cloudflared"
WARP_DIR="$BASE_DIR/warp"
WARP_CONF="$WARP_DIR/wgcf.conf"
WARP_SYSTEM_DIR="/etc/wireguard"
WARP_SYSTEM_CONF="$WARP_SYSTEM_DIR/wgcf.conf"
WARP_SERVICE_NAME="wg-quick@wgcf"
WARP_OPENRC_SERVICE_NAME="litebox-warp"
WARP_OPENRC_SERVICE="/etc/init.d/$WARP_OPENRC_SERVICE_NAME"
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
WARP_PRIVATE_KEY="${WARP_PRIVATE_KEY:-}"
WARP_IPV4="${WARP_IPV4:-}"
WARP_IPV6="${WARP_IPV6:-}"
WARP_PEER_PUBLIC_KEY="${WARP_PEER_PUBLIC_KEY:-}"
WARP_ENDPOINT_HOST="${WARP_ENDPOINT_HOST:-engage.cloudflareclient.com}"
WARP_ENDPOINT_PORT="${WARP_ENDPOINT_PORT:-2408}"
WARP_ENABLED="${WARP_ENABLED:-0}"
WARP_SPLIT_ENABLED="${WARP_SPLIT_ENABLED:-0}"
WARP_SPLIT_RULES="${WARP_SPLIT_RULES:-}"
WARP_CLIENT_VERSION="${WARP_CLIENT_VERSION:-a-6.11-2223}"

log() { printf '%s\n' "$*"; }
die() { log "error: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = "0" ] || die "please run as root"; }
has() { command -v "$1" >/dev/null 2>&1; }

progress_step() {
  current="$1"
  total="$2"
  shift 2
  filled="$(( current * 10 / total ))"
  bar=""
  i=1
  while [ "$i" -le 10 ]; do
    if [ "$i" -le "$filled" ]; then
      bar="${bar}#"
    else
      bar="${bar}-"
    fi
    i="$((i + 1))"
  done
  log "[$bar] $current/$total $*"
}

file_sha256() {
  if has sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif has shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "missing sha256sum or shasum"
  fi
}

short_hash() {
  printf '%s' "$1" | cut -c1-7
}

current_script_hash() {
  if [ -f "$CLI" ]; then
    file_sha256 "$CLI" 2>/dev/null | cut -c1-7
  elif [ -f "${BASH_SOURCE[0]:-$0}" ]; then
    file_sha256 "${BASH_SOURCE[0]:-$0}" 2>/dev/null | cut -c1-7
  else
    printf 'unknown'
  fi
}

pkg_install() {
  if is_alpine && has apk; then
    apk add --no-cache "$@"
    return 0
  fi
  if has apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "$@"
    return 0
  fi
  die "unsupported package manager: need apk or apt-get"
}

detect_os() {
  if [ -n "$OS_ID" ]; then
    return 0
  fi
  if [ -r /etc/os-release ]; then
    OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | head -n 1 | tr -d '"' || true)"
    OS_LIKE="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | head -n 1 | tr -d '"' || true)"
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
      systemctl enable "$name"
      if systemctl is-active --quiet "$name"; then
        systemctl restart "$name"
      else
        systemctl start "$name"
      fi
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

service_enable_start_best_effort() {
  detect_init_system
  name="$1"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl enable "$name" >/dev/null 2>&1 || true
      if systemctl is-active --quiet "$name" >/dev/null 2>&1; then
        systemctl restart "$name" >/dev/null 2>&1 || true
      else
        systemctl start "$name" >/dev/null 2>&1 || true
      fi
      ;;
    openrc)
      rc-update add "$name" default >/dev/null 2>&1 || true
      rc-service "$name" restart >/dev/null 2>&1 || rc-service "$name" start >/dev/null 2>&1 || true
      ;;
    *)
      true
      ;;
  esac
}

service_disable_stop_best_effort() {
  detect_init_system
  name="$1"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl disable --now "$name" >/dev/null 2>&1 || true
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

service_is_active() {
  detect_init_system
  name="$1"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl is-active --quiet "$name"
      ;;
    openrc)
      rc-service "$name" status >/dev/null 2>&1
      ;;
    *)
      return 1
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
  ip="$(local_ipv4 2>/dev/null || true)"
  if [ -n "$ip" ] && ! private_or_nat_ipv4 "$ip"; then
    printf '%s\n' "$ip"
  fi
}

has_public_ipv4() {
  ip="$(public_ip 2>/dev/null || true)"
  printf '%s\n' "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && ! private_or_nat_ipv4 "$ip"
}

has_public_ipv6() {
  ip="$(public_ipv6 2>/dev/null || true)"
  printf '%s\n' "$ip" | grep -q ':'
}

node_server_host() {
  if [ -n "${LB_SERVER:-}" ]; then
    server="$LB_SERVER"
  else
    server="$(public_ip)"
    [ -n "$server" ] || server="$(public_ipv6)"
  fi
  [ -n "$server" ] || die "cannot detect public IPv4 or IPv6"
  if printf '%s\n' "$server" | grep -q ':'; then
    printf '[%s]\n' "$server"
  else
    printf '%s\n' "$server"
  fi
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

private_or_nat_ipv4() {
  case "$1" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;;
    *) return 1 ;;
  esac
}

default_server_addr() {
  if [ -n "$SERVER" ]; then
    printf '%s\n' "$SERVER"
    return 0
  fi
  public_v4="$(public_ip 2>/dev/null || true)"
  public_v6="$(public_ipv6 2>/dev/null || true)"
  if [ -n "$public_v4" ]; then
    printf '%s\n' "$public_v4"
    return 0
  fi
  printf '%s\n' "$public_v6"
}

nat_dual_stack_info() {
  nat_local_v4="$(local_ipv4 2>/dev/null || true)"
  nat_public_v4="$(public_ip 2>/dev/null || true)"
  nat_public_v6="$(public_ipv6 2>/dev/null || true)"
  [ -n "$nat_public_v4" ] || return 1
  [ -n "$nat_public_v6" ] || return 1
  [ -n "$nat_local_v4" ] || return 1
  private_or_nat_ipv4 "$nat_local_v4" || return 1
  [ "$nat_public_v4" != "$nat_local_v4" ] || return 1
  return 0
}

cloud_public_ipv4_mapping() {
  [ -n "${nat_local_v4:-}" ] || return 1
  [ -n "${nat_public_v4:-}" ] || return 1
  if curl -fsS --connect-timeout 1 --max-time 2 -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" >/dev/null 2>&1; then
    return 0
  fi
  if curl -fsS --connect-timeout 1 --max-time 2 \
    "http://169.254.169.254/latest/meta-data/public-ipv4" >/dev/null 2>&1; then
    return 0
  fi
  if curl -fsS --connect-timeout 1 --max-time 2 -H "Metadata:true" \
    "http://169.254.169.254/metadata/instance?api-version=2021-02-01" >/dev/null 2>&1; then
    return 0
  fi
  if curl -fsS --connect-timeout 1 --max-time 2 \
    "http://100.100.100.200/latest/meta-data/eipv4" >/dev/null 2>&1; then
    return 0
  fi
  return 1
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

resolve_ipv4only_aaaa() {
  if has getent; then
    addr="$(getent ahostsv6 ipv4only.arpa 2>/dev/null | awk '/:/ {print $1; exit}')"
    [ -n "$addr" ] && {
      printf '%s\n' "$addr"
      return 0
    }
  fi
  if has ping6; then
    addr="$(ping6 -c 1 -w 2 ipv4only.arpa 2>/dev/null | sed -n 's/^PING[^(]*(\([^)]*\)).*/\1/p' | head -n 1)"
    [ -n "$addr" ] && {
      printf '%s\n' "$addr"
      return 0
    }
  fi
  if has ping; then
    addr="$(ping -6 -c 1 -w 2 ipv4only.arpa 2>/dev/null | sed -n 's/^PING[^(]*(\([^)]*\)).*/\1/p' | head -n 1)"
    [ -n "$addr" ] && {
      printf '%s\n' "$addr"
      return 0
    }
  fi
  return 1
}

has_dns64() {
  addr="$(resolve_ipv4only_aaaa 2>/dev/null || true)"
  printf '%s\n' "$addr" | grep -q ':'
}

has_nat64() {
  addr="$(resolve_ipv4only_aaaa 2>/dev/null || true)"
  printf '%s\n' "$addr" | grep -q ':'
}

ipv4_status_text() {
  if has_public_ipv4; then
    printf '有'
  else
    printf '无'
  fi
}

ipv6_status_text() {
  if has_public_ipv6 || [ -n "$(local_ipv6 2>/dev/null || true)" ]; then
    printf '有'
  else
    printf '无'
  fi
}

nat64_status_text() {
  if has_nat64; then
    printf '可用'
  else
    printf '不可用'
  fi
}

dns64_status_text() {
  if has_dns64; then
    printf '可用'
  else
    printf '不可用'
  fi
}

warp_status_text() {
  if [ "$WARP_ENABLED" = "1" ]; then
    if service_is_active "$WARP_SERVICE_NAME" || service_is_active "$WARP_OPENRC_SERVICE_NAME"; then
      printf '已启用'
    else
      printf '已配置'
    fi
  else
    printf '未启用'
  fi
}

warp_split_status_text() {
  if [ -n "${WARP_SPLIT_RULES:-}" ]; then
    printf '已开启'
  else
    printf '未开启'
  fi
}

warp_split_all_rules() {
  printf 'gemini claude openai tiktok x google telegram youtube netflix'
}

warp_split_rule_label() {
  case "$1" in
    gemini) printf 'Gemini' ;;
    claude) printf 'Claude' ;;
    openai) printf 'OpenAI / ChatGPT' ;;
    tiktok) printf 'TikTok' ;;
    x) printf 'Twitter / X' ;;
    google) printf 'Google' ;;
    telegram) printf 'Telegram' ;;
    youtube) printf 'YouTube' ;;
    netflix) printf 'Netflix' ;;
    *) printf '%s' "$1" ;;
  esac
}

warp_split_rule_url() {
  case "$1" in
    gemini) printf 'https://github.com/vernette/rulesets/raw/master/srs/gemini.srs' ;;
    claude) printf 'https://github.com/vernette/rulesets/raw/master/srs/claude.srs' ;;
    openai) printf 'https://github.com/vernette/rulesets/raw/master/srs/openai.srs' ;;
    tiktok) printf 'https://github.com/vernette/rulesets/raw/master/srs/tiktok.srs' ;;
    x) printf 'https://github.com/vernette/rulesets/raw/master/srs/x.srs' ;;
    google) printf 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/google.srs' ;;
    telegram) printf 'https://github.com/vernette/rulesets/raw/master/srs/telegram.srs' ;;
    youtube) printf 'https://github.com/vernette/rulesets/raw/master/srs/youtube.srs' ;;
    netflix) printf 'https://github.com/vernette/rulesets/raw/master/srs/netflix.srs' ;;
  esac
}

warp_split_rule_domains() {
  case "$1" in
    gemini) printf '%s\n' gemini.google.com generativelanguage.googleapis.com ai.google.dev makersuite.google.com ;;
    claude) printf '%s\n' claude.ai anthropic.com ;;
    openai) printf '%s\n' openai.com chatgpt.com chat.com sora.com oaiusercontent.com oaistatic.com ;;
    tiktok) printf '%s\n' tiktok.com tiktokv.com tiktokcdn.com byteoversea.com ibytedtos.com ;;
    x) printf '%s\n' x.com twitter.com twimg.com t.co ;;
    google) printf '%s\n' google.com googleapis.com gstatic.com googleusercontent.com googlevideo.com googlesyndication.com ;;
    telegram) printf '%s\n' telegram.org t.me tdesktop.com telegra.ph telegram.me ;;
    youtube) printf '%s\n' youtube.com youtu.be youtube-nocookie.com ytimg.com googlevideo.com ;;
    netflix) printf '%s\n' netflix.com netflix.net nflxext.com nflximg.com nflximg.net nflxso.net nflxvideo.net ;;
  esac
}

warp_split_rule_enabled() {
  case " $WARP_SPLIT_RULES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

warp_split_rule_status() {
  if warp_split_rule_enabled "$1"; then
    printf 'WARP'
  else
    printf '直连'
  fi
}

warp_split_normalize_rules() {
  normalized=""
  for rule in $(warp_split_all_rules); do
    if warp_split_rule_enabled "$rule"; then
      normalized="${normalized:+$normalized }$rule"
    fi
  done
  WARP_SPLIT_RULES="$normalized"
  [ -n "$WARP_SPLIT_RULES" ] && WARP_SPLIT_ENABLED=1 || WARP_SPLIT_ENABLED=0
}

warp_split_toggle_rule() {
  target="$1"
  if warp_split_rule_enabled "$target"; then
    new_rules=""
    for rule in $WARP_SPLIT_RULES; do
      [ "$rule" = "$target" ] && continue
      new_rules="${new_rules:+$new_rules }$rule"
    done
    WARP_SPLIT_RULES="$new_rules"
  else
    WARP_SPLIT_RULES="${WARP_SPLIT_RULES:+$WARP_SPLIT_RULES }$target"
  fi
  warp_split_normalize_rules
}

vendor_short_name() {
  vendor_info=""
  for file in /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/board_vendor; do
    [ -r "$file" ] && vendor_info="$vendor_info $(cat "$file" 2>/dev/null || true)"
  done
  vendor_info="$vendor_info $(hostname 2>/dev/null || true)"
  vendor_info="$(printf '%s' "$vendor_info" | tr '[:upper:]' '[:lower:]')"
  case "$vendor_info" in
    *amazon*|*ec2*) printf 'aws' ;;
    *google*|*gce*) printf 'gcp' ;;
    *microsoft*|*azure*) printf 'azure' ;;
    *oracle*|*oci*) printf 'oci' ;;
    *alibaba*|*aliyun*) printf 'aliyun' ;;
    *tencent*) printf 'tencent' ;;
    *huawei*) printf 'huawei' ;;
    *digitalocean*) printf 'do' ;;
    *vultr*) printf 'vultr' ;;
    *linode*) printf 'linode' ;;
    *hetzner*) printf 'hetzner' ;;
    *) printf 'vps' ;;
  esac
}

public_country_code() {
  for url in \
    https://ipapi.co/country/ \
    https://ifconfig.co/country-iso \
    https://ipinfo.io/country \
    https://ifconfig.me/country_code; do
    code="$(curl -fsSL --connect-timeout 3 "$url" 2>/dev/null | tr -d '\r\n' || true)"
    printf '%s\n' "$code" | grep -Eq '^[A-Za-z]{2}$' && {
      printf '%s\n' "$(printf '%s' "$code" | tr '[:lower:]' '[:upper:]')"
      return 0
    }
  done
  printf '未知\n'
}

country_name_zh() {
  case "$1" in
    SG) printf '新加坡' ;;
    JP) printf '日本' ;;
    HK) printf '香港' ;;
    US) printf '美国' ;;
    KR) printf '韩国' ;;
    DE) printf '德国' ;;
    GB) printf '英国' ;;
    NL) printf '荷兰' ;;
    FR) printf '法国' ;;
    CA) printf '加拿大' ;;
    AU) printf '澳大利亚' ;;
    IN) printf '印度' ;;
    RU) printf '俄罗斯' ;;
    TW) printf '台湾' ;;
    MO) printf '澳门' ;;
    MY) printf '马来西亚' ;;
    TH) printf '泰国' ;;
    VN) printf '越南' ;;
    ID) printf '印度尼西亚' ;;
    PH) printf '菲律宾' ;;
    *) printf '%s' "$1" ;;
  esac
}

node_name_prefix() {
  vendor="$(vendor_short_name)"
  country_code="$(public_country_code)"
  country_name="$(country_name_zh "$country_code")"
  printf '%s%s\n' "$vendor" "$country_name"
}

hop_status_text() {
  if [ -n "$1" ]; then
    printf '%s\n' "$1"
  else
    printf '关闭\n'
  fi
}

hop_ports_count() {
  input="$(printf '%s' "$1" | tr '，' ',')"
  [ -z "$input" ] && {
    printf '0\n'
    return 0
  }
  case "$input" in
    *:*)
      start_port="${input%%:*}"
      end_port="${input##*:}"
      printf '%s\n' "$(( end_port - start_port + 1 ))"
      ;;
    *)
      printf '1\n'
      ;;
  esac
}

warp_auto_register() {
  install_warp_deps
  ensure_warp_keys
  warp_public_key="$(printf '%s\n' "$WARP_PRIVATE_KEY" | wg pubkey)"
  warp_payload="$(printf '{"key":"%s","install_id":"","fcm_token":"","tos":"%s","model":"Linux","serial_number":"%s"}' "$warp_public_key" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$(uuid)")"
  warp_response="$(curl -fsSL -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
    -H "Content-Type: application/json" \
    -H "CF-Client-Version: $WARP_CLIENT_VERSION" \
    -d "$warp_payload" 2>/dev/null || true)"
  [ -n "$warp_response" ] || return 1
  WARP_IPV4="$(printf '%s' "$warp_response" | tr -d '\n' | sed -n 's/.*"addresses":{"v4":"\([^"]*\)","v6":"\([^"]*\)".*/\1/p' | head -n 1)"
  WARP_IPV6="$(printf '%s' "$warp_response" | tr -d '\n' | sed -n 's/.*"addresses":{"v4":"\([^"]*\)","v6":"\([^"]*\)".*/\2/p' | head -n 1)"
  WARP_PEER_PUBLIC_KEY="$(printf '%s' "$warp_response" | tr -d '\n' | sed -n 's/.*"peers":\[{"public_key":"\([^"]*\)".*/\1/p' | head -n 1)"
  WARP_ENDPOINT_HOST="$(printf '%s' "$warp_response" | tr -d '\n' | sed -n 's/.*"endpoint":{"v4":"[^"]*","v6":"[^"]*","host":"\([^":]*\).*/\1/p' | head -n 1)"
  [ -n "$WARP_IPV4" ] || return 1
  [ -n "$WARP_IPV6" ] || return 1
  [ -n "$WARP_PEER_PUBLIC_KEY" ] || return 1
  [ -n "$WARP_ENDPOINT_HOST" ] || WARP_ENDPOINT_HOST="engage.cloudflareclient.com"
  WARP_ENDPOINT_PORT="${WARP_ENDPOINT_PORT:-2408}"
  write_warp_config
  warp_service_enable_start
  WARP_ENABLED=1
  return 0
}

load_warp_from_conf() {
  [ -f "$WARP_CONF" ] || return 1
  conf_private_key="$(sed -n 's/^PrivateKey = //p' "$WARP_CONF" | head -n 1)"
  conf_address_line="$(sed -n 's/^Address = //p' "$WARP_CONF" | head -n 1)"
  conf_peer_key="$(sed -n 's/^PublicKey = //p' "$WARP_CONF" | tail -n 1)"
  conf_endpoint="$(sed -n 's/^Endpoint = //p' "$WARP_CONF" | tail -n 1)"
  [ -n "$conf_private_key" ] || return 1
  [ -n "$conf_address_line" ] || return 1
  [ -n "$conf_peer_key" ] || return 1
  [ -n "$conf_endpoint" ] || return 1
  conf_ipv4="$(printf '%s' "$conf_address_line" | cut -d',' -f1 | sed 's#/32##' | xargs)"
  conf_ipv6="$(printf '%s' "$conf_address_line" | cut -d',' -f2 | sed 's#/128##' | xargs)"
  conf_endpoint_host="$(printf '%s' "$conf_endpoint" | awk -F: '{print $1}')"
  conf_endpoint_port="$(printf '%s' "$conf_endpoint" | awk -F: '{print $NF}')"
  [ -n "$conf_ipv4" ] || return 1
  [ -n "$conf_ipv6" ] || return 1
  port_valid "$conf_endpoint_port" || return 1
  WARP_PRIVATE_KEY="$conf_private_key"
  WARP_IPV4="$conf_ipv4"
  WARP_IPV6="$conf_ipv6"
  WARP_PEER_PUBLIC_KEY="$conf_peer_key"
  WARP_ENDPOINT_HOST="$conf_endpoint_host"
  WARP_ENDPOINT_PORT="$conf_endpoint_port"
  WARP_ENABLED=1
  return 0
}

enable_warp_auto_or_manual() {
  if load_warp_from_conf; then
    install_warp_deps
    write_warp_config
    warp_service_enable_start
    WARP_ENABLED=1
    log "已从现有 WARP 配置恢复并启用。"
    return 0
  fi
  if warp_ready; then
    write_warp_config
    warp_service_enable_start
    WARP_ENABLED=1
    log "已复用现有 WARP 配置并重新启用。"
    return 0
  fi
  if warp_auto_register; then
    log "WARP 已自动注册并启用。"
    return 0
  fi
  log "自动获取 WARP 配置失败，回退到手动输入。"
  printf '请输入 WARP Interface PrivateKey [留空自动生成]: '
  read -r warp_private_key_input || exit 1
  [ -n "$warp_private_key_input" ] && WARP_PRIVATE_KEY="$warp_private_key_input"
  printf '请输入 WARP IPv4 地址，例如 172.16.0.2: '
  read -r warp_ipv4_input || exit 1
  [ -n "$warp_ipv4_input" ] || die "WARP IPv4 地址不能为空"
  printf '请输入 WARP IPv6 地址，例如 2606:4700:110:xxxx:xxxx:xxxx:xxxx:xxxx: '
  read -r warp_ipv6_input || exit 1
  [ -n "$warp_ipv6_input" ] || die "WARP IPv6 地址不能为空"
  printf '请输入 WARP Peer PublicKey: '
  read -r warp_peer_key_input || exit 1
  [ -n "$warp_peer_key_input" ] || die "WARP Peer PublicKey 不能为空"
  printf '请输入 WARP Endpoint Host [%s]: ' "$WARP_ENDPOINT_HOST"
  read -r warp_endpoint_host_input || exit 1
  printf '请输入 WARP Endpoint Port [%s]: ' "$WARP_ENDPOINT_PORT"
  read -r warp_endpoint_port_input || exit 1
  WARP_IPV4="$warp_ipv4_input"
  WARP_IPV6="$warp_ipv6_input"
  WARP_PEER_PUBLIC_KEY="$warp_peer_key_input"
  [ -n "$warp_endpoint_host_input" ] && WARP_ENDPOINT_HOST="$warp_endpoint_host_input"
  [ -n "$warp_endpoint_port_input" ] && WARP_ENDPOINT_PORT="$warp_endpoint_port_input"
  enable_warp
  return 0
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

install_base_deps() {
  if is_alpine && has apk; then
    apk add --no-cache bash curl tar openssl sed grep gawk ca-certificates openrc
    return 0
  fi
  if has apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl tar openssl sed grep gawk ca-certificates
    return 0
  fi
  true
}

install_port_hop_deps() {
  has iptables && has ip6tables && return 0
  log "正在安装端口跳跃依赖 iptables..."
  if is_alpine && has apk; then
    apk add --no-cache iptables
    return 0
  fi
  if has apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y iptables
    return 0
  fi
  die "端口跳跃需要 iptables/ip6tables，请先手动安装"
}

is_installed() {
  [ -x "$BIN" ] && [ -f "$CONF" ] && [ -f "$ENV_FILE" ]
}

require_installed() {
  is_installed || die "litebox is not installed yet"
}

sing_box_usable() {
  [ -x "$1" ] && "$1" version >/dev/null 2>&1
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
  REALITY_SNI="${REALITY_SNI:-${LB_REALITY_SNI:-www.yahoo.com}}"
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
  WARP_PRIVATE_KEY="${WARP_PRIVATE_KEY:-${LB_WARP_PRIVATE_KEY:-}}"
  WARP_IPV4="${WARP_IPV4:-${LB_WARP_IPV4:-}}"
  WARP_IPV6="${WARP_IPV6:-${LB_WARP_IPV6:-}}"
  WARP_PEER_PUBLIC_KEY="${WARP_PEER_PUBLIC_KEY:-${LB_WARP_PEER_PUBLIC_KEY:-}}"
  WARP_ENDPOINT_HOST="${WARP_ENDPOINT_HOST:-${LB_WARP_ENDPOINT_HOST:-engage.cloudflareclient.com}}"
  WARP_ENDPOINT_PORT="${WARP_ENDPOINT_PORT:-${LB_WARP_ENDPOINT_PORT:-2408}}"
  WARP_ENABLED="${WARP_ENABLED:-${LB_WARP_ENABLED:-0}}"
  WARP_SPLIT_ENABLED="${WARP_SPLIT_ENABLED:-${LB_WARP_SPLIT_ENABLED:-0}}"
  WARP_SPLIT_RULES="${WARP_SPLIT_RULES:-${LB_WARP_SPLIT_RULES:-}}"
  if [ -z "$WARP_SPLIT_RULES" ] && [ "$WARP_SPLIT_ENABLED" = "1" ]; then
    WARP_SPLIT_RULES="$(warp_split_all_rules)"
  fi
  warp_split_normalize_rules
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
LB_WARP_PRIVATE_KEY='$WARP_PRIVATE_KEY'
LB_WARP_IPV4='$WARP_IPV4'
LB_WARP_IPV6='$WARP_IPV6'
LB_WARP_PEER_PUBLIC_KEY='$WARP_PEER_PUBLIC_KEY'
LB_WARP_ENDPOINT_HOST='$WARP_ENDPOINT_HOST'
LB_WARP_ENDPOINT_PORT='$WARP_ENDPOINT_PORT'
LB_WARP_ENABLED='$WARP_ENABLED'
LB_WARP_SPLIT_ENABLED='$WARP_SPLIT_ENABLED'
LB_WARP_SPLIT_RULES='$WARP_SPLIT_RULES'
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
  if { [ -z "$WARP_PRIVATE_KEY" ] || [ -z "$WARP_IPV4" ] || [ -z "$WARP_IPV6" ] || [ -z "$WARP_PEER_PUBLIC_KEY" ]; } && [ -f "$WARP_CONF" ]; then
    load_warp_from_conf || true
  fi
  if [ "$WARP_ENABLED" != "1" ] && [ -f "$WARP_CONF" ] && { [ "$OUTBOUND_MODE" = "warp_ipv4" ] || [ -n "$WARP_SPLIT_RULES" ]; }; then
    load_warp_from_conf || true
  fi

  if [ -z "${LB_SERVER:-}" ]; then
    LB_SERVER="$(default_server_addr)"
  fi
  [ -n "$LB_SERVER" ] || die "cannot detect public IPv4 or IPv6"
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
  if [ -z "${LB_SERVER:-}" ]; then
    LB_SERVER="$(default_server_addr)"
  fi
  [ -n "$LB_SERVER" ] || die "cannot detect public IPv4 or IPv6"
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
  mkdir -p "$BASE_DIR"
  if is_alpine && [ -e "$BIN" ] && ! sing_box_usable "$BIN"; then
    log "removing unusable Alpine sing-box residue: $BIN"
    rm -f "$BIN" "$SING_BOX_MARKER"
  fi
  if is_alpine && has apk; then
    log "detected Alpine Linux, trying apk add sing-box first"
    if apk add --no-cache sing-box >/dev/null 2>&1; then
      found="$(command -v sing-box || true)"
      [ -n "$found" ] || die "apk installed sing-box but binary was not found in PATH"
      sing_box_usable "$found" || die "apk installed sing-box but binary cannot run"
      if [ "$found" != "$BIN" ]; then
        ln -sf "$found" "$BIN"
      fi
      rm -f "$SING_BOX_MARKER"
      return 0
    fi
    log "apk add sing-box unavailable, falling back to upstream tarball"
  fi
  if [ -x "$BIN" ]; then
    if sing_box_usable "$BIN"; then
      rm -f "$SING_BOX_MARKER"
      return 0
    fi
    log "existing sing-box cannot run, reinstalling"
    rm -f "$BIN"
  fi
  tmp="$(mktemp -d)"
  urls="$(release_asset_urls SagerNet/sing-box "$SING_BOX_VERSION")"
  exact_url="$(printf '%s\n' "$urls" | grep -E "/sing-box-[^/]+-linux-${arch}\.tar\.gz$" | head -n 1)"
  musl_url="$(printf '%s\n' "$urls" | grep -E "/sing-box-[^/]+-linux-${arch}-musl\.tar\.gz$" | head -n 1)"
  anylinux_url="$(printf '%s\n' "$urls" | grep -E "/sing-box-[^/]+-linux-${arch}-anylinux\.tar\.gz$" | head -n 1)"
  other_url="$(printf '%s\n' "$urls" | grep -E "/sing-box-[^/]+-linux-${arch}[^/]*\.tar\.gz$" | grep -Ev "(linux-${arch}|-glibc|-gnu)\.tar\.gz$" | head -n 1)"
  glibc_url="$(printf '%s\n' "$urls" | grep -E "/sing-box-[^/]+-linux-${arch}-(glibc|gnu)\.tar\.gz$" | head -n 1)"

  if is_alpine; then
    url="${musl_url:-${anylinux_url:-$other_url}}"
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
  sing_box_usable "$BIN" || die "installed sing-box cannot run on this system"
  : >"$SING_BOX_MARKER"
  rm -rf "$tmp"
}

install_cloudflared() {
  [ -n "$ARGO_TOKEN" ] || [ "$ENABLE_TEMP_ARGO" = "1" ] || return 0
  mkdir -p "$BASE_DIR"
  if [ -x "$CLOUDFLARED_BIN" ]; then
    rm -f "$CF_MARKER"
    return 0
  fi
  arch="$(arch_name)"
  tmp="$(mktemp -d)"
  url="$(download_url cloudflare/cloudflared "linux-$arch$")"
  [ -n "$url" ] || die "cannot find cloudflared release for $arch"
  log "download cloudflared: $url"
  curl -fL "$url" -o "$tmp/cloudflared"
  install -m 0755 "$tmp/cloudflared" "$CLOUDFLARED_BIN"
  : >"$CF_MARKER"
  rm -rf "$tmp"
}

warp_ready() {
  [ "$WARP_ENABLED" = "1" ] &&
  [ -n "$WARP_PRIVATE_KEY" ] &&
  [ -n "$WARP_IPV4" ] &&
  [ -n "$WARP_IPV6" ] &&
  [ -n "$WARP_PEER_PUBLIC_KEY" ] &&
  [ -f "$WARP_CONF" ]
}

install_warp_deps() {
  pkg_install wireguard-tools
}

ensure_warp_keys() {
  [ -n "$WARP_PRIVATE_KEY" ] && return 0
  mkdir -p "$WARP_DIR"
  umask 077
  WARP_PRIVATE_KEY="$(wg genkey)"
}

write_warp_config() {
  ensure_warp_keys
  mkdir -p "$WARP_DIR"
  cat >"$WARP_CONF" <<EOF
[Interface]
PrivateKey = $WARP_PRIVATE_KEY
Address = $WARP_IPV4/32, $WARP_IPV6/128
MTU = 1280
Table = off
PostUp = ip -4 rule add pref 10010 from all table main
PostUp = ip -4 route add default dev %i table 51820
PostDown = ip -4 rule del pref 10010 from all table main
PostDown = ip -4 route del default dev %i table 51820

[Peer]
PublicKey = $WARP_PEER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0
Endpoint = $WARP_ENDPOINT_HOST:$WARP_ENDPOINT_PORT
PersistentKeepalive = 25
EOF
  chmod 600 "$WARP_CONF"
  mkdir -p "$WARP_SYSTEM_DIR"
  cp "$WARP_CONF" "$WARP_SYSTEM_CONF"
  chmod 600 "$WARP_SYSTEM_CONF"
}

write_warp_service() {
  detect_init_system
  [ "$INIT_SYSTEM" = "openrc" ] || return 0
  cat >"$WARP_OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run
description="Litebox WARP WireGuard"

depend() {
  need net
  after litebox
}

start() {
  ebegin "Starting Litebox WARP"
  if wg show wgcf >/dev/null 2>&1; then
    eend 0
    return 0
  fi
  wg-quick up "$WARP_CONF" >/dev/null 2>&1
  eend \$?
}

stop() {
  ebegin "Stopping Litebox WARP"
  if wg show wgcf >/dev/null 2>&1; then
    wg-quick down "$WARP_CONF" >/dev/null 2>&1 || true
  fi
  eend 0
}

status() {
  if wg show wgcf >/dev/null 2>&1; then
    ebegin "status: started"
    eend 0
    return 0
  fi
  ebegin "status: stopped"
  eend 3
  return 3
}
EOF
  chmod 0755 "$WARP_OPENRC_SERVICE"
}

warp_service_enable_start() {
  detect_init_system
  write_warp_service
  case "$INIT_SYSTEM" in
    systemd) service_enable_start_best_effort "$WARP_SERVICE_NAME" ;;
    openrc) service_enable_start_best_effort "$WARP_OPENRC_SERVICE_NAME" ;;
  esac
}

warp_service_disable_stop() {
  service_disable_stop_best_effort "$WARP_SERVICE_NAME"
  service_disable_stop_best_effort "$WARP_OPENRC_SERVICE_NAME"
}

enable_warp() {
  install_warp_deps
  write_warp_config
  warp_service_enable_start
  WARP_ENABLED=1
}

disable_warp() {
  warp_service_disable_stop
  WARP_ENABLED=0
  WARP_SPLIT_ENABLED=0
  WARP_SPLIT_RULES=""
}

delete_warp() {
  warp_service_disable_stop
  rm -f "$WARP_SYSTEM_CONF" "$WARP_OPENRC_SERVICE"
  rm -rf "$WARP_DIR"
  WARP_PRIVATE_KEY=""
  WARP_IPV4=""
  WARP_IPV6=""
  WARP_PEER_PUBLIC_KEY=""
  WARP_ENDPOINT_HOST="engage.cloudflareclient.com"
  WARP_ENDPOINT_PORT="2408"
  WARP_ENABLED=0
  WARP_SPLIT_ENABLED=0
  WARP_SPLIT_RULES=""
  if [ "$OUTBOUND_MODE" = "warp_ipv4" ]; then
    OUTBOUND_MODE="auto"
  fi
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
  dns_strategy="prefer_ipv4"
  dns_server="1.1.1.1"
  direct_strategy="prefer_ipv4"
  warp_outbound_block=""
  warp_rule_set_block=""
  warp_route_rules_block=""
  warp_domain_exact_block=""
  warp_domain_exact_rule_block=""
  warp_domain_rule_block=""
  warp_domain_suffix_block=""
  warp_rule_names_block=""
  final_outbound="direct"
  auto_detect_interface=true
  case "$OUTBOUND_MODE" in
    prefer_ipv6|ipv6_only)
      dns_strategy="$OUTBOUND_MODE"
      dns_server="2606:4700:4700::1111"
      direct_strategy="$OUTBOUND_MODE"
      auto_detect_interface=false
      ;;
    prefer_ipv4|ipv4_only)
      dns_strategy="$OUTBOUND_MODE"
      direct_strategy="$OUTBOUND_MODE"
      ;;
  esac
  if ! has_public_ipv4 && [ "$OUTBOUND_MODE" = "auto" ]; then
    dns_strategy="prefer_ipv6"
    dns_server="2606:4700:4700::1111"
    direct_strategy="prefer_ipv6"
    auto_detect_interface=false
  fi
  warp_split_normalize_rules
  if warp_ready && { [ "$OUTBOUND_MODE" = "warp_ipv4" ] || [ -n "$WARP_SPLIT_RULES" ]; }; then
    auto_detect_interface=false
  fi
  direct_domain_resolver="$(printf ',\n      "domain_resolver": {\n        "server": "litebox-dns",\n        "strategy": "%s"\n      }' "$direct_strategy")"
  if warp_ready; then
    warp_outbound_block="$(cat <<EOF
,
    {
      "type": "direct",
      "tag": "warp",
      "bind_interface": "wgcf",
      "domain_resolver": {
        "server": "litebox-dns",
        "strategy": "ipv4_only"
      }
    }
EOF
)"
  fi
  if warp_ready && [ -n "$WARP_SPLIT_RULES" ]; then
    first_rule=1
    first_domain=1
    for rule in $WARP_SPLIT_RULES; do
      rule_url="$(warp_split_rule_url "$rule")"
      for domain in $(warp_split_rule_domains "$rule"); do
        [ -n "$domain" ] || continue
        if [ "$first_domain" -eq 1 ]; then
          warp_domain_exact_block="$(printf '          "%s"' "$domain")"
          warp_domain_suffix_block="$(printf '          "%s"' "$domain")"
          first_domain=0
        else
          warp_domain_exact_block="$warp_domain_exact_block,$(printf '\n          "%s"' "$domain")"
          warp_domain_suffix_block="$warp_domain_suffix_block,$(printf '\n          "%s"' "$domain")"
        fi
      done
      if [ -n "$rule_url" ]; then
        if [ "$first_rule" -eq 1 ]; then
          warp_rule_set_block="$(cat <<EOF
    {
      "type": "remote",
      "tag": "warp-$rule",
      "format": "binary",
      "url": "$rule_url",
      "download_detour": "direct"
    }
EOF
)"
          warp_rule_names_block="$(printf '          "warp-%s"' "$rule")"
          first_rule=0
        else
          warp_rule_set_block="$warp_rule_set_block$(cat <<EOF
,
    {
      "type": "remote",
      "tag": "warp-$rule",
      "format": "binary",
      "url": "$rule_url",
      "download_detour": "direct"
    }
EOF
)"
          warp_rule_names_block="$warp_rule_names_block,$(printf '\n          "warp-%s"' "$rule")"
        fi
      fi
    done
    [ -n "$warp_rule_set_block" ] || WARP_SPLIT_RULES=""
  fi
  if warp_ready && [ -n "$WARP_SPLIT_RULES" ]; then
    if [ -n "${warp_domain_exact_block:-}" ]; then
      warp_domain_exact_rule_block="$(cat <<EOF
      {
        "action": "route",
        "domain": [
$warp_domain_exact_block
        ],
        "outbound": "warp"
      },
EOF
)"
    fi
    if [ -n "${warp_domain_suffix_block:-}" ]; then
      warp_domain_rule_block="$(cat <<EOF
      {
        "action": "route",
        "domain_suffix": [
$warp_domain_suffix_block
        ],
        "outbound": "warp"
      },
EOF
)"
    fi
    warp_route_rules_block="$(cat <<EOF
    "rules": [
      {
        "action": "sniff"
      },
$warp_domain_exact_rule_block
$warp_domain_rule_block
      {
        "action": "route",
        "rule_set": [
$warp_rule_names_block
        ],
        "outbound": "warp"
      }
    ],
    "rule_set": [
      $warp_rule_set_block
    ],
EOF
)"
  fi
  dns_block="$(cat <<EOF
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "litebox-dns",
        "server": "$dns_server",
        "server_port": 53
      }
    ],
    "final": "litebox-dns",
    "strategy": "$dns_strategy"
  },
EOF
)"
  if [ "$OUTBOUND_MODE" = "warp_ipv4" ]; then
    warp_ready || die "WARP IPv4 出口未配置，请先在菜单中启用 WARP"
    final_outbound="warp"
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
      "tag": "direct"$direct_domain_resolver
    },
    {
      "type": "block",
      "tag": "block"
    }$warp_outbound_block
  ],
  "route": {
    "auto_detect_interface": $auto_detect_interface,
${warp_route_rules_block}
    "final": "$final_outbound"
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
  cli_source="${1:-}"
  if [ -n "$cli_source" ]; then
    install -m 0755 "$cli_source" "$CLI"
  elif ! curl -fsSL "$SCRIPT_URL" -o "$CLI"; then
    self_path="$0"
    if [ -r "$self_path" ] && [ "$(basename "$self_path")" != "bash" ]; then
      install -m 0755 "$self_path" "$CLI"
    else
      die "cannot install litebox cli"
    fi
  else
    chmod 0755 "$CLI"
  fi
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

argo_export_host() {
  if [ -n "$ARGO_TOKEN" ] && [ -n "$ARGO_DOMAIN" ]; then
    printf '%s\n' "$ARGO_DOMAIN"
    return 0
  fi
  if [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    host="$(extract_temp_argo_domain)"
    if [ -n "$host" ]; then
      printf '%s\n' "$host"
    else
      printf '<your-trycloudflare-domain>\n'
    fi
    return 0
  fi
  return 1
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
  node_prefix="$(node_name_prefix)"
  server="$(node_server_host)"
  vless="vless://$LB_UUID@$server:$VLESS_PORT?encryption=none&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$LB_REALITY_PUBLIC&sid=$LB_SHORT_ID&type=tcp&flow=xtls-rprx-vision#$node_prefix-reality"
  anytls="anytls://$LB_ANYTLS_PASSWORD@$server:$ANYTLS_PORT?security=tls&sni=$TLS_SNI&insecure=1#$node_prefix-anytls"
  if [ -n "$TUIC_HOP_PORTS" ]; then
    tuic="tuic://$LB_UUID:$LB_TUIC_PASSWORD@$server:$TUIC_PORT?congestion_control=bbr&alpn=h3&allow_insecure=1&port_hopping=$TUIC_HOP_PORTS#$node_prefix-tuic"
  else
    tuic="tuic://$LB_UUID:$LB_TUIC_PASSWORD@$server:$TUIC_PORT?congestion_control=bbr&alpn=h3&allow_insecure=1#$node_prefix-tuic"
  fi
  if [ -n "$HY2_HOP_PORTS" ]; then
    hy2_export_hop="$(printf '%s' "$HY2_HOP_PORTS" | tr ':' '-')"
    hy2="hysteria2://$LB_HY2_PASSWORD@$server:$HY2_PORT?obfs=salamander&obfs-password=$LB_HY2_OBFS&sni=$TLS_SNI&insecure=1&mport=$hy2_export_hop#$node_prefix-hy2"
  else
    hy2="hysteria2://$LB_HY2_PASSWORD@$server:$HY2_PORT?obfs=salamander&obfs-password=$LB_HY2_OBFS&sni=$TLS_SNI&insecure=1#$node_prefix-hy2"
  fi
  vmess_path="${VMESS_WS_PATH#/}"

  cat >"$LINKS_FILE" <<EOF
VLESS-REALITY:
$vless

AnyTLS:
$anytls

TUIC-v5:
$tuic

Hysteria2:
$hy2
EOF
  if argo_host="$(argo_export_host)"; then
    vmess_json="$(printf '{"v":"2","ps":"%s-vmess-argo","add":"saas.sin.fan","port":"8443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","fp":"chrome"}' "$node_prefix" "$LB_UUID" "$argo_host" "$vmess_path" "$argo_host" | b64_nowrap)"
    cat >>"$LINKS_FILE" <<EOF

VMess-WS-Argo:
vmess://$vmess_json
EOF
  fi
  cat >>"$LINKS_FILE" <<EOF

Server: $server
UUID: $LB_UUID
Reality public key: $LB_REALITY_PUBLIC
Reality short id: $LB_SHORT_ID
Outbound mode: $OUTBOUND_MODE
Shortcut: sudo LB
EOF
  chmod 600 "$LINKS_FILE"
}

display_links_screen() {
  title="${1:-节点信息}"
  require_installed
  load_or_create_env
  if [ "$ENABLE_TEMP_ARGO" = "1" ] && ! extract_temp_argo_domain >/dev/null 2>&1; then
    wait_temp_argo_domain 5 >/dev/null 2>&1 || true
  fi
  write_links
  printf '\n'
  log "$title"
  printf '\n'
  cat "$LINKS_FILE"
  if [ "$ENABLE_TEMP_ARGO" = "1" ] && ! argo_export_host >/dev/null 2>&1; then
    printf '\n'
    log "临时 Argo 提示:"
    log "请用 'sudo litebox logs 80'、'sudo LB logs 80' 或 'sudo lb logs 80' 查看 trycloudflare.com 域名。"
  fi
  printf '\n按回车返回主菜单...'
  read -r _ || exit 1
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
    warp_ipv4) printf 'WARP IPv4 出口' ;;
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
  progress_step 1 4 "正在更新 Litebox 配置..."
  load_or_create_env
  install_cloudflared
  gen_cert
  save_env
  write_config
  write_services
  write_links
  if [ "$WARP_ENABLED" = "1" ] && warp_ready; then
    write_warp_config
    warp_service_enable_start
  fi
  progress_step 2 4 "正在启用服务..."
  enable_services
  progress_step 3 4 "正在应用端口跳跃规则..."
  apply_port_hops
  if [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    refresh_temp_argo_links || true
  fi
  progress_step 4 4 "配置更新完成"
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
    while rule="$(iptables -t nat -S PREROUTING 2>/dev/null | grep -m 1 'litebox-tuic-hop' || true)"; [ -n "$rule" ]; do
      iptables -t nat -D ${rule#-A } >/dev/null 2>&1 || break
    done
    while rule="$(iptables -t nat -S PREROUTING 2>/dev/null | grep -m 1 'litebox-hy2-hop' || true)"; [ -n "$rule" ]; do
      iptables -t nat -D ${rule#-A } >/dev/null 2>&1 || break
    done
    while rule="$(iptables -t nat -S OUTPUT 2>/dev/null | grep -m 1 'litebox-tuic-hop-output' || true)"; [ -n "$rule" ]; do
      iptables -t nat -D ${rule#-A } >/dev/null 2>&1 || break
    done
    while rule="$(iptables -t nat -S OUTPUT 2>/dev/null | grep -m 1 'litebox-hy2-hop-output' || true)"; [ -n "$rule" ]; do
      iptables -t nat -D ${rule#-A } >/dev/null 2>&1 || break
    done
    while rule="$(iptables -S INPUT 2>/dev/null | grep -m 1 'litebox-tuic-hop-input' || true)"; [ -n "$rule" ]; do
      iptables -D ${rule#-A } >/dev/null 2>&1 || break
    done
    while rule="$(iptables -S INPUT 2>/dev/null | grep -m 1 'litebox-hy2-hop-input' || true)"; [ -n "$rule" ]; do
      iptables -D ${rule#-A } >/dev/null 2>&1 || break
    done
  fi
  if has ip6tables; then
    while rule="$(ip6tables -t nat -S PREROUTING 2>/dev/null | grep -m 1 'litebox-tuic-hop' || true)"; [ -n "$rule" ]; do
      ip6tables -t nat -D ${rule#-A } >/dev/null 2>&1 || break
    done
    while rule="$(ip6tables -t nat -S PREROUTING 2>/dev/null | grep -m 1 'litebox-hy2-hop' || true)"; [ -n "$rule" ]; do
      ip6tables -t nat -D ${rule#-A } >/dev/null 2>&1 || break
    done
    while rule="$(ip6tables -t nat -S OUTPUT 2>/dev/null | grep -m 1 'litebox-tuic-hop-output' || true)"; [ -n "$rule" ]; do
      ip6tables -t nat -D ${rule#-A } >/dev/null 2>&1 || break
    done
    while rule="$(ip6tables -t nat -S OUTPUT 2>/dev/null | grep -m 1 'litebox-hy2-hop-output' || true)"; [ -n "$rule" ]; do
      ip6tables -t nat -D ${rule#-A } >/dev/null 2>&1 || break
    done
    while rule="$(ip6tables -S INPUT 2>/dev/null | grep -m 1 'litebox-tuic-hop-input' || true)"; [ -n "$rule" ]; do
      ip6tables -D ${rule#-A } >/dev/null 2>&1 || break
    done
    while rule="$(ip6tables -S INPUT 2>/dev/null | grep -m 1 'litebox-hy2-hop-input' || true)"; [ -n "$rule" ]; do
      ip6tables -D ${rule#-A } >/dev/null 2>&1 || break
    done
  fi
}

apply_port_hops() {
  clear_port_hops
  if [ -n "$TUIC_HOP_PORTS" ] || [ -n "$HY2_HOP_PORTS" ]; then
    install_port_hop_deps
    has iptables || die "端口跳跃需要 iptables"
    has ip6tables || die "端口跳跃需要 ip6tables"
  fi
  if has iptables; then
    oldifs="$IFS"
    IFS=','
    expanded_tuic_hop_ports="$(expand_hop_ports "$TUIC_HOP_PORTS")"
    for port in $expanded_tuic_hop_ports; do
      [ -n "$port" ] || continue
      iptables -C INPUT -p udp --dport "$port" -m comment --comment litebox-tuic-hop-input -j ACCEPT >/dev/null 2>&1 ||
        iptables -I INPUT -p udp --dport "$port" -m comment --comment litebox-tuic-hop-input -j ACCEPT >/dev/null 2>&1 || true
      iptables -t nat -A PREROUTING -p udp --dport "$port" -m comment --comment litebox-tuic-hop -j REDIRECT --to-ports "$TUIC_PORT" >/dev/null 2>&1 || true
      if printf '%s\n' "$LB_SERVER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        iptables -t nat -A OUTPUT -d "$LB_SERVER" -p udp --dport "$port" -m comment --comment litebox-tuic-hop-output -j REDIRECT --to-ports "$TUIC_PORT" >/dev/null 2>&1 || true
      fi
    done
    expanded_hy2_hop_ports="$(expand_hop_ports "$HY2_HOP_PORTS")"
    for port in $expanded_hy2_hop_ports; do
      [ -n "$port" ] || continue
      iptables -C INPUT -p udp --dport "$port" -m comment --comment litebox-hy2-hop-input -j ACCEPT >/dev/null 2>&1 ||
        iptables -I INPUT -p udp --dport "$port" -m comment --comment litebox-hy2-hop-input -j ACCEPT >/dev/null 2>&1 || true
      iptables -t nat -A PREROUTING -p udp --dport "$port" -m comment --comment litebox-hy2-hop -j REDIRECT --to-ports "$HY2_PORT" >/dev/null 2>&1 || true
      if printf '%s\n' "$LB_SERVER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        iptables -t nat -A OUTPUT -d "$LB_SERVER" -p udp --dport "$port" -m comment --comment litebox-hy2-hop-output -j REDIRECT --to-ports "$HY2_PORT" >/dev/null 2>&1 || true
      fi
    done
    IFS="$oldifs"
  fi
  if has ip6tables; then
    oldifs="$IFS"
    IFS=','
    expanded_tuic_hop_ports="$(expand_hop_ports "$TUIC_HOP_PORTS")"
    for port in $expanded_tuic_hop_ports; do
      [ -n "$port" ] || continue
      ip6tables -C INPUT -p udp --dport "$port" -m comment --comment litebox-tuic-hop-input -j ACCEPT >/dev/null 2>&1 ||
        ip6tables -I INPUT -p udp --dport "$port" -m comment --comment litebox-tuic-hop-input -j ACCEPT >/dev/null 2>&1 || true
      ip6tables -t nat -A PREROUTING -p udp --dport "$port" -m comment --comment litebox-tuic-hop -j REDIRECT --to-ports "$TUIC_PORT" >/dev/null 2>&1 || true
      if printf '%s\n' "$LB_SERVER" | grep -q ':'; then
        ip6tables -t nat -A OUTPUT -d "$LB_SERVER" -p udp --dport "$port" -m comment --comment litebox-tuic-hop-output -j REDIRECT --to-ports "$TUIC_PORT" >/dev/null 2>&1 || true
      fi
    done
    expanded_hy2_hop_ports="$(expand_hop_ports "$HY2_HOP_PORTS")"
    for port in $expanded_hy2_hop_ports; do
      [ -n "$port" ] || continue
      ip6tables -C INPUT -p udp --dport "$port" -m comment --comment litebox-hy2-hop-input -j ACCEPT >/dev/null 2>&1 ||
        ip6tables -I INPUT -p udp --dport "$port" -m comment --comment litebox-hy2-hop-input -j ACCEPT >/dev/null 2>&1 || true
      ip6tables -t nat -A PREROUTING -p udp --dport "$port" -m comment --comment litebox-hy2-hop -j REDIRECT --to-ports "$HY2_PORT" >/dev/null 2>&1 || true
      if printf '%s\n' "$LB_SERVER" | grep -q ':'; then
        ip6tables -t nat -A OUTPUT -d "$LB_SERVER" -p udp --dport "$port" -m comment --comment litebox-hy2-hop-output -j REDIRECT --to-ports "$HY2_PORT" >/dev/null 2>&1 || true
      fi
    done
    IFS="$oldifs"
  fi
}

hop_ports_valid() {
  input="$(printf '%s' "$1" | tr '，' ',')"
  [ -z "$input" ] && return 0
  case "$input" in
    *','*)
      return 1
      ;;
    *:*)
      start_port="${input%%:*}"
      end_port="${input##*:}"
      port_valid "$start_port" || return 1
      port_valid "$end_port" || return 1
      [ "$start_port" -le "$end_port" ] || return 1
      ;;
    *)
      port_valid "$input" || return 1
      ;;
  esac
  [ "$(hop_ports_count "$input")" -le "$HOP_PORTS_MAX" ] || return 1
  return 0
}

expand_hop_ports() {
  input="$(printf '%s' "$1" | tr '，' ',')"
  [ -z "$input" ] && return 0
  case "$input" in
    *:*)
      start_port="${input%%:*}"
      end_port="${input##*:}"
      current_port="$start_port"
      first_item=1
      while [ "$current_port" -le "$end_port" ]; do
        if [ "$first_item" -eq 1 ]; then
          printf '%s' "$current_port"
          first_item=0
        else
          printf ',%s' "$current_port"
        fi
        current_port=$((current_port + 1))
      done
      ;;
    *)
      printf '%s' "$input"
      ;;
  esac
}

prompt_hop_ports() {
  label="$1"
  current="$2"
  while :; do
    printf '%s [%s]: ' "$label" "$(hop_status_text "$current")" >&2
    read -r value || exit 1
    [ -z "$value" ] && value="$current"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr '，' ',')"
    case "$value" in
      0)
        printf '\n'
        return
        ;;
    esac
    if hop_ports_valid "$value"; then
      printf '%s\n' "$value"
      return
    fi
    log "端口格式无效，跳跃端口最多允许 $HOP_PORTS_MAX 个。请输入单端口、范围，或输入 0 关闭，例如 12310 或 12310:12350" >&2
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

choose_nat_entry_addr() {
  [ -z "$SERVER" ] || return 0
  nat_dual_stack_info || return 0
  if cloud_public_ipv4_mapping; then
    LB_SERVER="$nat_public_v4"
    return 0
  fi
  while :; do
    printf '\n'
    log "检测到 NAT/CGNAT IPv4，同时存在公网 IPv6。"
    log "本机 IPv4: $nat_local_v4"
    log "公网 IPv4: $nat_public_v4"
    log "公网 IPv6: $nat_public_v6"
    log "1. 使用 IPv6 作为节点入口 (默认，适合无 IPv4 端口转发)"
    log "2. 使用 IPv4 作为节点入口 (适合已有 IPv4 端口转发)"
    log "3. 手动输入入口地址"
    printf '请选择 [1-3] (默认 1): '
    read -r entry_choice || exit 1
    case "${entry_choice:-1}" in
      1)
        LB_SERVER="$nat_public_v6"
        return 0
        ;;
      2)
        LB_SERVER="$nat_public_v4"
        return 0
        ;;
      3)
        printf '请输入节点入口地址(IP 或域名): '
        read -r custom_entry || exit 1
        [ -n "$custom_entry" ] || {
          log "入口地址不能为空。"
          continue
        }
        LB_SERVER="$custom_entry"
        return 0
        ;;
      *)
        log "无效选择"
        ;;
    esac
  done
}

apply_warp_split_change() {
  warp_split_normalize_rules
  if is_installed; then
    save_env
    progress_step 1 2 "正在更新 WARP 分流配置..."
    apply_changes
  else
    save_env
  fi
  progress_step 2 2 "WARP 分流配置已更新"
}

warp_split_menu() {
  warp_ready || die "请先安装或启用 WARP"
  while :; do
    printf '\n'
    log "WARP 分流规则"
    log "1. 全部规则走 WARP"
    log "2. 全部规则直连"
    idx=3
    for rule in $(warp_split_all_rules); do
      log "$idx. $(warp_split_rule_label "$rule") -> $(warp_split_rule_status "$rule")"
      idx=$((idx + 1))
    done
    log "0. 返回上层"
    printf '请选择 [0-11]: '
    read -r action || exit 1
    case "$action" in
      1)
        WARP_SPLIT_RULES="$(warp_split_all_rules)"
        apply_warp_split_change
        log "全部分流规则已设置为 WARP"
        break
        ;;
      2)
        WARP_SPLIT_RULES=""
        apply_warp_split_change
        log "全部分流规则已设置为直连"
        break
        ;;
      3) warp_split_toggle_rule gemini; apply_warp_split_change; break ;;
      4) warp_split_toggle_rule claude; apply_warp_split_change; break ;;
      5) warp_split_toggle_rule openai; apply_warp_split_change; break ;;
      6) warp_split_toggle_rule tiktok; apply_warp_split_change; break ;;
      7) warp_split_toggle_rule x; apply_warp_split_change; break ;;
      8) warp_split_toggle_rule google; apply_warp_split_change; break ;;
      9) warp_split_toggle_rule telegram; apply_warp_split_change; break ;;
      10) warp_split_toggle_rule youtube; apply_warp_split_change; break ;;
      11) warp_split_toggle_rule netflix; apply_warp_split_change; break ;;
      0) break ;;
      *) log "无效选择" ;;
    esac
  done
}

warp_manage_menu() {
  while :; do
    printf '\n'
    log "WARP 管理"
    log "当前状态: $(warp_status_text)"
    log "分流规则: $(warp_split_status_text)"
    log "1. 安装或启用 WARP"
    log "2. 关闭 WARP"
    log "3. 删除 WARP"
    log "4. WARP 分流规则管理"
    log "0. 返回上层"
    printf '请选择 [0-4]: '
    read -r action || exit 1
    case "$action" in
      1)
        progress_step 1 3 "正在准备 WARP 配置..."
        enable_warp_auto_or_manual
        if is_installed; then
          save_env
          progress_step 2 3 "正在更新 Litebox 配置..."
          apply_changes
        else
          save_env
        fi
        progress_step 3 3 "WARP 启用完成"
        log "WARP 已启用"
        break
        ;;
      2)
        progress_step 1 3 "正在关闭 WARP..."
        disable_warp
        if [ "$OUTBOUND_MODE" = "warp_ipv4" ]; then
          OUTBOUND_MODE="auto"
        fi
        if is_installed; then
          save_env
          progress_step 2 3 "正在更新 Litebox 配置..."
          apply_changes
        else
          save_env
        fi
        progress_step 3 3 "WARP 关闭完成"
        log "WARP 已关闭"
        break
        ;;
      3)
        progress_step 1 3 "正在删除 WARP 配置..."
        delete_warp
        if is_installed; then
          save_env
          progress_step 2 3 "正在更新 Litebox 配置..."
          apply_changes
        else
          save_env
        fi
        progress_step 3 3 "WARP 删除完成"
        log "WARP 已删除"
        break
        ;;
      4)
        warp_split_menu
        continue
        ;;
      0) break ;;
      *) log "无效选择" ;;
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
    log "IPv4 / IPv6 / WARP 出口切换"
    log "当前模式: $(outbound_mode_text)"
    log "1. 自动"
    log "2. IPv4 优先"
    log "3. IPv6 优先"
    log "4. 仅 IPv4"
    log "5. 仅 IPv6"
    log "6. WARP IPv4 出口"
    log "7. WARP 管理"
    log "0. 返回上层"
    printf '请选择 [0-7]: '
    read -r action || exit 1
    case "$action" in
      1) OUTBOUND_MODE="auto" ;;
      2) OUTBOUND_MODE="prefer_ipv4" ;;
      3) OUTBOUND_MODE="prefer_ipv6" ;;
      4) OUTBOUND_MODE="ipv4_only" ;;
      5) OUTBOUND_MODE="ipv6_only" ;;
      6)
        warp_ready || die "WARP IPv4 出口未配置，请先进入“7. WARP 管理”安装或启用 WARP"
        OUTBOUND_MODE="warp_ipv4"
        ;;
      7)
        warp_manage_menu
        continue
        ;;
      0) break ;;
      *) log "无效选择"; continue ;;
    esac
    if [ "$action" != "0" ] && [ "$action" != "7" ]; then
      if is_installed; then
        save_env
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

update_script_only() {
  need_root
  tmp_script="$(mktemp)"
  progress_step 1 4 "正在检查 GitHub 项目是否有更新..."
  if ! curl -fsSL "$SCRIPT_URL" -o "$tmp_script"; then
    rm -f "$tmp_script"
    die "无法下载远端脚本，请检查网络"
  fi
  chmod 0755 "$tmp_script"
  current_hash=""
  remote_hash="$(file_sha256 "$tmp_script")"
  if [ -f "$CLI" ]; then
    current_hash="$(file_sha256 "$CLI")"
  fi
  if [ -n "$current_hash" ] && [ "$current_hash" = "$remote_hash" ]; then
    rm -f "$tmp_script"
    printf '\n'
    log "Litebox 项目无变化，当前脚本已是最新。"
    log "本地版本: $(short_hash "$current_hash")，远程版本: $(short_hash "$remote_hash")"
    if is_installed; then
      log "正在同步当前安装配置和端口跳跃规则..."
      "$CLI" update-apply
      log "当前安装配置已同步。"
    fi
    printf '按回车返回主菜单...'
    read -r _ || exit 1
    exec "$CLI" menu
  fi
  log "检测到 Litebox 项目有更新，正在安装新脚本..."
  log "本地版本: ${current_hash:+$(short_hash "$current_hash")}，远程版本: $(short_hash "$remote_hash")"
  progress_step 2 4 "正在更新 Litebox 快捷脚本..."
  write_cli "$tmp_script"
  rm -f "$tmp_script"
  progress_step 3 4 "正在按新脚本重建当前安装配置..."
  "$CLI" update-apply
  progress_step 4 4 "更新完成"
  printf '\n'
  log "Litebox 脚本已更新到版本 $(short_hash "$remote_hash")。"
  if is_installed; then
    log "当前安装配置也已按新脚本重新生成。"
  fi
  printf '按回车返回主菜单...'
  read -r _ || exit 1
  exec "$CLI" menu
}

update_apply() {
  need_root
  is_installed || exit 0
  load_or_create_env
  gen_cert
  save_env
  write_config
  write_services
  write_links
  if [ "$WARP_ENABLED" = "1" ] && warp_ready; then
    write_warp_config
    warp_service_enable_start
  fi
  enable_services
  apply_port_hops
  if [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    refresh_temp_argo_links || true
  fi
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
    log "3. 设置 TUIC 端口跳跃"
    log "4. 设置 Hysteria2 端口跳跃"
    log "0. 返回上层"
    printf '请选择 [0-4]: '
    read -r action || exit 1
    case "$action" in
      1)
        set_default_ports
        if is_installed; then
          save_env
          apply_changes
        fi
        if is_installed; then
          display_links_screen "端口已更新"
        else
          log "已切换为随机推荐端口"
        fi
        break
        ;;
      2)
        VLESS_PORT="$(prompt_port 'VLESS Reality 端口' "$VLESS_PORT")"
        ANYTLS_PORT="$(prompt_port 'AnyTLS 端口' "$ANYTLS_PORT")"
        TUIC_PORT="$(prompt_port 'TUIC v5 端口' "$TUIC_PORT")"
        HY2_PORT="$(prompt_port 'Hysteria2 端口' "$HY2_PORT")"
        VMESS_LOCAL_PORT="$(prompt_port 'WS 本地端口(仅 127.0.0.1)' "$VMESS_LOCAL_PORT")"
        if is_installed; then
          save_env
          apply_changes
        fi
        if is_installed; then
          display_links_screen "端口已更新"
        else
          log "端口已更新"
        fi
        break
        ;;
      3)
        TUIC_HOP_PORTS="$(prompt_hop_ports 'TUIC v5 跳跃端口(单端口/范围，0 关闭，最多 50 个端口)' "$TUIC_HOP_PORTS")"
        if is_installed; then
          save_env
          apply_changes
          display_links_screen "端口已更新"
        else
          log "TUIC 跳跃端口已更新"
        fi
        break
        ;;
      4)
        HY2_HOP_PORTS="$(prompt_hop_ports 'Hysteria2 跳跃端口(单端口/范围，0 关闭，最多 50 个端口)' "$HY2_HOP_PORTS")"
        if is_installed; then
          save_env
          apply_changes
          display_links_screen "端口已更新"
        else
          log "Hysteria2 跳跃端口已更新"
        fi
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
  save_env
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
  save_env
  apply_changes
  log "已启用固定 Argo。"
}

disable_argo() {
  ARGO_TOKEN=""
  ARGO_DOMAIN=""
  ENABLE_TEMP_ARGO=0
  save_env
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
  save_env
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
  save_env
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
  display_links_screen "节点信息"
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

confirm_uninstall_menu() {
  printf '\n'
  log "确认彻底卸载 Litebox 吗？"
  log "1. 确认卸载"
  log "0. 返回主菜单"
  printf '请选择 [0-1]: '
  read -r action || exit 1
  case "$action" in
    1) return 0 ;;
    *) return 1 ;;
  esac
}

uninstall_all() {
  need_root
  progress_step 1 4 "正在停止 Litebox 服务..."
  service_disable_stop litebox
  service_disable_stop litebox-argo
  warp_service_disable_stop
  progress_step 2 4 "正在清理端口跳跃规则..."
  clear_port_hops
  if [ -f "$SING_BOX_MARKER" ]; then
    rm -f "$BIN"
  fi
  if [ -f "$CF_MARKER" ]; then
    rm -f "$CLOUDFLARED_BIN"
  fi
  progress_step 3 4 "正在删除 Litebox 文件..."
  rm -f "$SERVICE" "$ARGO_SERVICE" "$WARP_OPENRC_SERVICE" "$WARP_SYSTEM_CONF" "$CLI" "$LB_CLI" "$LB_CLI_UPPER" "$OLD_SB_CLI" "$RUN_LITEBOX" "$RUN_ARGO"
  rm -rf "$BASE_DIR"
  service_reload
  progress_step 4 4 "卸载完成"
  log "Litebox 已彻底卸载完成。"
}

install_menu() {
  apply_saved_settings
  CUSTOM_UUID=""
  while :; do
    printf '\n'
    log "安装设置"
    log "1. 安装 Litebox"
    log "2. 更新 Litebox 脚本"
    log "0. 返回主菜单"
    printf '请选择 [0-2] (默认 1): '
    read -r action || exit 1
    case "${action:-1}" in
      1)
        if is_installed; then
          printf '\n'
          log "Litebox 当前已经安装。"
          printf '按回车返回安装菜单...'
          read -r _ || exit 1
          continue
        fi
        while :; do
          printf '\n'
          log "安装方式"
          log "1. 使用随机推荐端口安装"
          log "2. 自定义端口后安装"
          log "0. 返回上层"
          printf '请选择 [0-2] (默认 1): '
          read -r install_action || exit 1
          case "${install_action:-1}" in
            1)
              set_default_ports
              choose_uuid_mode
              choose_firewall_action
              install_all
              break 2
              ;;
            2)
              set_default_ports
              change_ports_menu
              choose_uuid_mode
              choose_firewall_action
              install_all
              break 2
              ;;
            0)
              break
              ;;
            *)
              log "无效选择"
              ;;
          esac
        done
        ;;
      2)
        update_script_only
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

maybe_warn_ipv6_only_no_nat64() {
  if [ "$(ipv4_status_text)" = "无" ] && [ "$(ipv6_status_text)" = "有" ] && [ "$(nat64_status_text)" = "不可用" ] && [ "$WARP_ENABLED" != "1" ]; then
    log "提示: 当前机器只有 IPv6，且未检测到 NAT64 / DNS64。"
    log "如需更稳的 IPv4 出口，可在“4. IPv4 / IPv6 / WARP 出口切换”中按需启用 WARP。"
  fi
}

show_menu() {
  while :; do
    printf '\n'
    log "Litebox 快捷菜单"
    log "版本: $(current_script_hash)"
    current_ipv4="$(local_ipv4 || true)"
    current_ipv6="$(local_ipv6 || true)"
    if is_installed; then
      load_or_create_env
    else
      apply_saved_settings
    fi
    if is_installed; then
      if printf '%s\n' "${LB_SERVER:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        current_ipv4="$LB_SERVER"
      elif printf '%s\n' "${LB_SERVER:-}" | grep -q ':'; then
        current_ipv6="$LB_SERVER"
      fi
      log "安装状态: 已安装"
      log "快捷命令: sudo LB / sudo lb"
      log "Argo 状态: $(argo_mode_text)"
      argo_host="$(current_argo_host)"
      [ -n "$argo_host" ] && log "Argo HOST: $argo_host"
      log "本机 IPv4: ${current_ipv4:-未检测到}"
      log "本机 IPv6: ${current_ipv6:-未检测到}"
      log "出口模式: $(outbound_mode_text)"
      log "WARP 分流: $(warp_split_status_text)"
      log "端口: vless=$VLESS_PORT anytls=$ANYTLS_PORT tuic=$TUIC_PORT hy2=$HY2_PORT ws=$VMESS_LOCAL_PORT"
      log "端口跳跃: tuic=$(hop_status_text "$TUIC_HOP_PORTS")   hy2=$(hop_status_text "$HY2_HOP_PORTS")"
    else
      if [ -z "${VLESS_PORT:-}" ] || [ -z "${ANYTLS_PORT:-}" ] || [ -z "${TUIC_PORT:-}" ] || [ -z "${HY2_PORT:-}" ] || [ -z "${VMESS_LOCAL_PORT:-}" ]; then
        set_default_ports
      fi
      if has_public_ipv4; then
        current_ipv4="$(public_ip || printf '%s' "$current_ipv4")"
      fi
      log "安装状态: 未安装"
      log "安装后快捷命令: sudo LB / sudo lb"
      log "本机 IPv4: ${current_ipv4:-未检测到}"
      log "本机 IPv6: ${current_ipv6:-未检测到}"
      log "出口模式: $(outbound_mode_text)"
      log "默认端口: vless=$VLESS_PORT anytls=$ANYTLS_PORT tuic=$TUIC_PORT hy2=$HY2_PORT ws=$VMESS_LOCAL_PORT"
      log "端口跳跃: tuic=$(hop_status_text "$TUIC_HOP_PORTS")   hy2=$(hop_status_text "$HY2_HOP_PORTS")"
    fi
    printf '\n'
    log "1. 安装/更新 Litebox"
    log "2. Argo 隧道设置"
    log "3. 端口设置"
    log "4. IPv4 / IPv6 / WARP 出口切换"
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
        confirm_uninstall_menu || continue
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
  progress_step 1 8 "正在检查运行环境..."
  install_base_deps
  install_deps_hint
  maybe_warn_ipv6_only_no_nat64
  progress_step 2 8 "正在安装 sing-box..."
  install_sing_box
  load_or_create_env
  choose_nat_entry_addr
  progress_step 3 8 "正在准备 Cloudflare Argo 组件..."
  install_cloudflared
  progress_step 4 8 "正在生成证书和配置..."
  gen_cert
  save_env
  write_config
  write_services
  progress_step 5 8 "正在创建快捷命令..."
  write_cli
  write_links
  if [ "${FIREWALL_ACTION:-1}" = "1" ]; then
    progress_step 6 8 "正在开放服务端口..."
    open_service_ports
  else
    progress_step 6 8 "已跳过端口开放"
  fi
  progress_step 7 8 "正在应用端口跳跃和启动服务..."
  apply_port_hops
  enable_services
  if [ "$ENABLE_TEMP_ARGO" = "1" ]; then
    refresh_temp_argo_links || true
  fi
  progress_step 8 8 "安装完成"
  display_links_screen "安装完成"
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
  update-apply) update_apply ;;
  menu) show_menu ;;
  *) die "用法: $0 [install|status|config|info|logs [lines]|restart|uninstall|ports|argo|menu]" ;;
esac
