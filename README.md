# Litebox / 轻量 Sing-box 节点脚本

Litebox is a tiny `sing-box` deployment script for low-memory VPS instances.

Litebox 是一个面向低内存 VPS 的轻量 `sing-box` 部署脚本，尽量减少常驻进程和额外依赖，适合 128 MB 这类小鸡。

Supports / 支持:

- AnyTLS
- TUIC v5
- VLESS Reality Vision
- VMess WebSocket + Cloudflare Argo
- Hysteria2

It avoids panels, databases, nginx, geo assets, and heavy routing rules.

它不带面板、不带数据库、不带 nginx、不拉 geo 资源，也不做重路由规则堆叠。

## Install / 安装

Run as root on Debian/Ubuntu/Alpine-like minimal systems with `systemd`, `curl`, `tar`, and `openssl`:

在 Debian / Ubuntu / Alpine 这类带 `systemd`、`curl`、`tar`、`openssl` 的精简系统上，以 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linlvyy/litebox-singbox-mini/main/install.sh)
```

Local install / 本地执行：

```bash
chmod +x install.sh
sudo ./install.sh
```

## Quick Start / 快捷呼出

After installation, the management command is:

安装完成后，快捷管理命令是：

```bash
sudo sb
```

`sb` is a shortcut to `litebox`, and it opens the quick menu by default.

`sb` 是 `litebox` 的快捷入口，默认会直接弹出快捷菜单。

You can still use direct commands:

也可以继续直接用命令：

```bash
sudo litebox info
sudo litebox status
sudo litebox config
sudo litebox logs
sudo litebox restart
sudo litebox uninstall
```

## Menu / 快捷菜单

Current quick menu items:

当前快捷菜单项目：

- `1` Install or reinstall Litebox / 安装或重装 Litebox
- `2` Uninstall Litebox / 卸载 Litebox
- `3` Argo tunnel settings / Argo 隧道设置
- `4` Change ports / 修改端口
- `6` Restart Litebox / 重启 Litebox
- `9` Refresh and show node links / 刷新并查看节点
- `10` View logs / 查看运行日志

Argo submenu:

Argo 子菜单支持：

- Temporary tunnel / 临时隧道
- Fixed tunnel / 固定隧道
- Disable Argo / 关闭 Argo

## Ports / 端口

Default ports / 默认端口：

- `VLESS Reality`: `443`
- `AnyTLS`: `8443`
- `TUIC v5`: `9443`
- `Hysteria2`: `8444`
- `VMess WS local`: `18080` (`127.0.0.1` only)

Now the script supports:

现在脚本支持：

- Recommended defaults / 恢复推荐默认端口
- Random suitable ports / 随机分配合适端口
- Manual custom ports / 手动自定义端口

If you prefer environment variables during first install:

如果你想在首次安装时通过环境变量指定：

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

## Argo / Cloudflare Tunnel

For a fixed Cloudflare Tunnel:

固定 Argo 示例：

```bash
ARGO_TOKEN='cloudflare-tunnel-token' ARGO_DOMAIN='vmess.example.com' sudo -E ./install.sh
```

For a temporary Argo tunnel:

临时 Argo 示例：

```bash
ENABLE_TEMP_ARGO=1 sudo -E ./install.sh
sudo litebox logs
```

Copy the `trycloudflare.com` domain from the `cloudflared` log into the VMess client link.

临时 Argo 需要把 `cloudflared` 日志里出现的 `trycloudflare.com` 域名填回 VMess 节点里。

## Generated Files / 生成文件

- `/etc/litebox/config.json`
- `/etc/litebox/env`
- `/etc/litebox/links.txt`
- `/etc/systemd/system/litebox.service`
- `/etc/systemd/system/litebox-argo.service`
- `/usr/local/bin/litebox`
- `/usr/local/bin/sb`

## Notes / 说明

- `links.txt` contains credentials and is `0600`.
- `links.txt` 保存节点信息，权限是 `0600`。
- AnyTLS, TUIC, and Hysteria2 use a generated self-signed certificate, so clients need `insecure` or `allow_insecure`.
- AnyTLS、TUIC、Hysteria2 使用自签证书，客户端通常需要开启 `insecure` 或 `allow_insecure`。
- VLESS Reality does not need a certificate and uses `xtls-rprx-vision`.
- VLESS Reality 不需要证书，使用 `xtls-rprx-vision`。
- Open TCP `443`, `8443`; UDP `9443`, `8444` on your firewall/security group if you keep the defaults.
- 如果使用默认端口，记得在防火墙或安全组放行 TCP `443`、`8443`，UDP `9443`、`8444`。
- On a 128 MB VPS, the core script is fine; the main extra overhead comes from `cloudflared` when Argo is enabled.
- 对 128 MB 小鸡来说，脚本主体没有问题，额外压力主要来自启用 Argo 后的 `cloudflared` 进程。

## References / 参考

This project follows the current sing-box inbound/TLS schemas:

本项目参考当前 sing-box 官方入站与 TLS 配置格式：

- AnyTLS inbound: https://sing-box.sagernet.org/configuration/inbound/anytls/
- TUIC inbound: https://sing-box.sagernet.org/configuration/inbound/tuic/
- VLESS inbound: https://sing-box.sagernet.org/configuration/inbound/vless/
- VMess inbound: https://sing-box.sagernet.org/configuration/inbound/vmess/
- Hysteria2 inbound: https://sing-box.sagernet.org/configuration/inbound/hysteria2/
- TLS Reality fields: https://sing-box.sagernet.org/configuration/shared/tls/
- WebSocket transport: https://sing-box.sagernet.org/configuration/shared/v2ray-transport/
