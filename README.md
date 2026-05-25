# Litebox

Litebox is a tiny sing-box deployment script for low-memory VPS instances. It creates one `sing-box` service with these inbound nodes:

- AnyTLS
- TUIC v5
- VLESS Reality Vision
- VMess WebSocket for Cloudflare Argo
- Hysteria2

The script avoids panels, databases, nginx, geo assets, and heavy routing rules. VMess Argo is optional; without Argo settings it only listens on `127.0.0.1`.

## Install

Run as root on Debian/Ubuntu/Alpine-like minimal systems with `systemd`, `curl`, `tar`, and `openssl`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linlvyy/litebox-singbox/main/install.sh)
```

Local install:

```bash
chmod +x install.sh
sudo ./install.sh
```

Optional environment variables:

```bash
SERVER=1.2.3.4 \
REALITY_SNI=www.microsoft.com \
TLS_SNI=bing.com \
ANYTLS_PORT=8443 \
TUIC_PORT=9443 \
VLESS_PORT=443 \
HY2_PORT=8444 \
sudo -E ./install.sh
```

For a fixed Cloudflare Tunnel:

```bash
ARGO_TOKEN='cloudflare-tunnel-token' ARGO_DOMAIN='vmess.example.com' sudo -E ./install.sh
```

For a temporary Argo tunnel:

```bash
ENABLE_TEMP_ARGO=1 sudo -E ./install.sh
sudo litebox logs
```

Copy the `trycloudflare.com` domain from the `cloudflared` log into the VMess client link.

## Commands

```bash
sudo litebox info
sudo litebox status
sudo litebox logs
sudo litebox restart
sudo litebox uninstall
```

Generated files:

- `/etc/litebox/config.json`
- `/etc/litebox/env`
- `/etc/litebox/links.txt`
- `/etc/systemd/system/litebox.service`
- `/etc/systemd/system/litebox-argo.service`
- `/usr/local/bin/litebox`

## Notes

- `links.txt` contains credentials and is `0600`.
- AnyTLS, TUIC, and Hysteria2 use a generated self-signed certificate, so clients need `insecure` or `allow_insecure`.
- VLESS Reality does not need a certificate and uses `xtls-rprx-vision`.
- Open TCP `443`, `8443`; UDP `9443`, `8444` on your firewall/security group.
- On a 128 MB VPS, avoid enabling fixed Argo unless you need VMess over Cloudflare, because `cloudflared` is an extra process.
- Fixed Argo needs both `ARGO_TOKEN` and the matching public `ARGO_DOMAIN`; temporary Argo uses `ENABLE_TEMP_ARGO=1`.

## References

This project follows the current sing-box inbound/TLS schemas:

- AnyTLS inbound: https://sing-box.sagernet.org/configuration/inbound/anytls/
- TUIC inbound: https://sing-box.sagernet.org/configuration/inbound/tuic/
- VLESS inbound: https://sing-box.sagernet.org/configuration/inbound/vless/
- VMess inbound: https://sing-box.sagernet.org/configuration/inbound/vmess/
- Hysteria2 inbound: https://sing-box.sagernet.org/configuration/inbound/hysteria2/
- TLS Reality fields: https://sing-box.sagernet.org/configuration/shared/tls/
- WebSocket transport: https://sing-box.sagernet.org/configuration/shared/v2ray-transport/
