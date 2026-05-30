# Litebox 轻量 Sing-box 节点脚本

Litebox 是一个面向低内存 VPS 的轻量 `sing-box` 部署脚本，尽量减少常驻进程和额外依赖，适合 128 MB 这类小鸡。

支持协议：

- AnyTLS
- TUIC v5
- VLESS Reality Vision
- VMess WebSocket + Cloudflare Argo
- Hysteria2

特点：

- 不带面板
- 不带数据库
- 不带 nginx
- 不拉 geo 资源
- 默认只保留最小必要组件

## 安装

在 Debian / Ubuntu / Alpine 这类带 `systemd` 或 `OpenRC`、`curl`、`tar`、`openssl` 的精简系统上，以 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linlvyy/litebox-singbox-mini/main/install.sh)
```

执行后会先进入菜单，再选择安装方式，不会直接开装。

Alpine 安装行为：

- 优先执行 `apk add --no-cache sing-box`
- 如果当前 `apk` 仓库没有 `sing-box`，再回退到 sing-box 官方发布包
- Alpine 回退下载时只选 `musl` / 通用 Linux 包，不会选 `glibc` 包
- 如果检测到已有 `/usr/local/bin/sing-box` 不能执行，会先删除残留再重装
- 安装前会先补齐 `curl`、`tar`、`openssl`、`gawk`、`openrc` 等基础依赖
- 检测到 `OpenRC` 时，会生成 `litebox` / `litebox-argo` 的 OpenRC 服务并自动开机自启
- IPv6-only 小鸡也可以安装，未开启 WARP 时会直接生成 IPv6 入站节点

本地执行：

```bash
chmod +x install.sh
sudo ./install.sh
```

## 快捷命令

安装完成后，快捷管理命令是：

```bash
sudo LB
sudo lb
```

`LB` 和 `lb` 都是 `litebox` 的快捷入口，默认直接弹出中文菜单。

也可以继续使用命令行方式：

```bash
sudo litebox info
sudo litebox status
sudo litebox config
sudo litebox logs
sudo litebox restart
sudo litebox uninstall
```

## 菜单说明

当前主菜单：

- `1` 安装/更新 Litebox
- `2` Argo 隧道设置
- `3` 端口设置
- `4` IPv4 / IPv6 / WARP 出口切换
- `5` 重启 Litebox
- `6` 刷新并查看节点
- `7` 查看运行日志
- `8` 彻底卸载 Litebox
- `0` 退出脚本

Argo 子菜单支持：

- 添加或者删除 Argo 临时隧道
- 添加或者删除 Argo 固定隧道

临时 Argo 二级菜单：

- 重置 Argo 临时隧道域名
- 停止 Argo 临时隧道

固定 Argo 二级菜单：

- 添加或更新 Argo 固定隧道
- 停止 Argo 固定隧道

安装菜单支持：

- 安装 Litebox
- 更新 Litebox 脚本
- 安装时再进入下一层选择：
- 使用随机推荐端口安装
- 自定义端口后安装
- 端口设置菜单不提供默认选择，必须手动输入
- 大部分菜单支持直接回车，默认选择 `1`
- 最外层主菜单不默认选择，避免误触安装

如果只是更新脚本版本，不修改现有节点配置、端口、Argo、WARP，可以直接进入安装菜单选择“更新 Litebox 脚本”。

如果当前已经安装，再选择“安装 Litebox”，脚本只会提示“Litebox 当前已经安装”，不会再显示卸载说明。

更新成功后，脚本会提示“按回车返回主菜单...”，随后直接切回新版主菜单。

出口菜单支持：

- 自动
- IPv4 优先
- IPv6 优先
- 仅 IPv4
- 仅 IPv6
- WARP IPv4 出口
- WARP 管理

WARP 管理二级菜单支持：

- 安装或启用 WARP
- 关闭 WARP
- 删除 WARP

`安装或启用 WARP` 默认会先自动注册免费 WARP 配置：

- 自动生成 WireGuard 密钥
- 自动向 Cloudflare WARP 注册设备
- 自动获取 `IPv4` / `IPv6` 地址、Peer 公钥和 Endpoint
- 如果本机已经存在有效 WARP 配置，则直接复用，不会重复注册

每次安装或重装时，都会额外让你选择：

- 重新随机生成 UUID
- 手动输入 UUID
- 是否开放端口并关闭防火墙

对于 IPv6-only VPS，脚本会额外检测：

- 是否有公网 IPv4
- 是否有 IPv6
- `ipv4only.arpa` 的 AAAA 解析是否存在
- 是否可用 NAT64 / DNS64

如果是 IPv6-only 且检测不到 NAT64，安装时会提示你可选启用 WARP 作为 IPv4 出口，但不会强制安装。

## 端口策略

- 默认是随机推荐端口。
- `VLESS Reality`、`AnyTLS`、`TUIC v5`、`Hysteria2` 会从高位端口里随机分配，并避开 `80`、`443`、`8443` 这类常用端口。
- `WS 本地端口` 会从 Cloudflare 常用端口里选择，例如 `8080`、`2052`、`2053`、`2082`、`2083`、`2086`、`2087`、`2095`、`2096`、`8880`。

端口设置支持：

- 重新随机推荐端口
- 手动自定义端口
- 单独设置 `TUIC v5` 端口跳跃
- 单独设置 `Hysteria2` 端口跳跃
- 主菜单里会把 `TUIC` / `HY2` 端口跳跃状态合并显示在同一行，方便一起看

如果你想在首次安装时通过环境变量指定：

```bash
SERVER=1.2.3.4 \
REALITY_SNI=www.microsoft.com \
TLS_SNI=bing.com \
ANYTLS_PORT=24567 \
TUIC_PORT=33456 \
VLESS_PORT=15789 \
HY2_PORT=41888 \
VMESS_LOCAL_PORT=8080 \
sudo -E ./install.sh
```

## Argo 说明

固定 Argo 示例：

```bash
ARGO_TOKEN='cloudflare-tunnel-token' ARGO_DOMAIN='vmess.example.com' sudo -E ./install.sh
```

临时 Argo 示例：

```bash
ENABLE_TEMP_ARGO=1 sudo -E ./install.sh
sudo litebox logs
```

临时 Argo 的 VMess 节点现在会自动处理：

- `add` 使用 `saas.sin.fan`
- `port` 使用 `8443`
- `host` 自动抓取当前 `trycloudflare.com` 域名
- `path` 自动使用 `$UUID-vm`
- `sni` 跟随真实临时隧道域名

重置临时 Argo 后，脚本会主动等待真实 HOST，并在菜单和节点信息里显示。

选择 `6` 刷新并查看节点后，脚本会停留在节点结果页，按回车后才返回主菜单，方便直接复制链接。

如果 Argo 当前状态是固定隧道或临时隧道，后续再次选择 `6` 刷新并查看节点时，Argo 节点会继续显示。

临时 Argo 如果当下还没抓到 `trycloudflare.com` HOST，会先保留提示，等日志里拿到真实 HOST 后再替换成可用节点。

导出的节点名称会按“商家英文简写 + 国家 + 协议类型”生成，例如：

- `aws新加坡-hy2`
- `gcp日本-tuic`
- `vps美国-reality`

`TUIC v5` 和 `Hysteria2` 的端口跳跃采用轻量的 UDP 端口重定向方式实现，支持：

- 单端口，例如 `12310`
- 范围端口，例如 `12310:12350`
- 输入 `0`
- 跳跃端口最多允许 `50` 个

导出节点时：

- `TUIC v5` 会在链接里附带 `port_hopping=12310:12350`
- `Hysteria2` 会在链接里附带 `mport=12310-12350`
- 如果只是单端口，则分别导出对应单端口
- 如果关闭跳跃，则不会输出 `port_hopping` 或 `mport`

`TUIC v5` 和 `Hysteria2` 的跳跃端口现在互不影响，可以：

- 只开 `TUIC v5`
- 只开 `Hysteria2`
- 两个都开
- 两个都关

## 安全边界

- `VLESS Reality` 默认伪装域名是 `www.microsoft.com`，不使用 Cloudflare 域名。
- 脚本会拒绝把 `cloudflare.com`、`trycloudflare.com`、`workers.dev`、`pages.dev`、`cloudflare-ech.com`、`saas.sin.fan` 用作 Reality 伪装域名，避免被误配成 Cloudflare/Argo/优选域名。
- `VMess WS` 只监听 `127.0.0.1`，公网不会直接开放 VMess 端口，只通过 Argo 隧道访问。
- `TUIC v5`、`Hysteria2` 和端口跳跃端口都是 UDP 转发到对应协议端口，协议本身仍需要 UUID/密码认证。
- `/etc/litebox/env` 和 `/etc/litebox/links.txt` 默认权限是 `0600`，避免节点密钥被普通用户直接读取。
- Alpine / OpenRC 安装后也会创建 `litebox`、`LB`、`lb` 三个快捷命令。
- WARP 默认不安装、不启用，只有用户在菜单里手动开启时才会安装 `wireguard-tools`。

## 生成文件

- `/etc/litebox/config.json`
- `/etc/litebox/env`
- `/etc/litebox/links.txt`
- `/etc/litebox/warp/wgcf.conf`（仅启用 WARP 后生成）
- `/etc/systemd/system/litebox.service` 或 `/etc/init.d/litebox`
- `/etc/systemd/system/litebox-argo.service` 或 `/etc/init.d/litebox-argo`
- `/usr/local/bin/litebox`
- `/usr/local/bin/LB`
- `/usr/local/bin/lb`

## 卸载说明

选择菜单中的 `8`，会彻底删除：

- `litebox` / `sb`
- `systemd` 服务
- `/etc/litebox` 下全部配置和证书

只有在 Litebox 安装时由脚本亲自安装的 `sing-box` / `cloudflared`，卸载时才会删除。

如果机器里原本就有用户自己安装的 `sing-box` / `cloudflared`，Litebox 卸载不会误删它们。

正式卸载前会先二次确认，避免误触。

## 说明

- `links.txt` 保存节点信息，权限是 `0600`。
- AnyTLS、TUIC、Hysteria2 使用自签证书，客户端通常需要开启 `insecure` 或 `allow_insecure`。
- VLESS Reality 不需要证书，使用 `xtls-rprx-vision`。
- 安装时如果选择自动处理，脚本会尝试开放节点端口并关闭常见防火墙。
- Alpine 使用 `OpenRC`，脚本会优先尝试 `apk add sing-box`；Debian / Ubuntu 通常使用 `systemd`，脚本会自动识别并生成对应服务。
- IPv6-only 机器如果没有公网 IPv4，脚本会继续安装，并优先生成 `[IPv6]:端口` 形式的节点地址。
- 如果 IPv6-only 机器存在 NAT64 / DNS64，默认不需要 WARP 也可以继续使用。
- WARP 采用轻量 WireGuard 方式，可选启用；启用后可把 sing-box 出站切到 `WARP IPv4`。
- 安装、更新脚本、启用或删除 WARP、彻底卸载等操作过程中，脚本会输出当前进度提示，避免误以为卡住。
- 对 128 MB 小鸡来说，脚本主体没有问题，额外压力主要来自启用 Argo 后的 `cloudflared` 进程。

## 参考

本项目参考当前 sing-box 官方入站与 TLS 配置格式：

- AnyTLS inbound: https://sing-box.sagernet.org/configuration/inbound/anytls/
- TUIC inbound: https://sing-box.sagernet.org/configuration/inbound/tuic/
- VLESS inbound: https://sing-box.sagernet.org/configuration/inbound/vless/
- VMess inbound: https://sing-box.sagernet.org/configuration/inbound/vmess/
- Hysteria2 inbound: https://sing-box.sagernet.org/configuration/inbound/hysteria2/
- TLS Reality fields: https://sing-box.sagernet.org/configuration/shared/tls/
- WebSocket transport: https://sing-box.sagernet.org/configuration/shared/v2ray-transport/
