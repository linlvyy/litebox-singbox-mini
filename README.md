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

在 Debian / Ubuntu / Alpine 这类带 `systemd`、`curl`、`tar`、`openssl` 的精简系统上，以 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linlvyy/litebox-singbox-mini/main/install.sh)
```

执行后会先进入菜单，再选择安装方式，不会直接开装。

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

- `1` 安装 Litebox
- `2` Argo 隧道设置
- `3` 端口设置
- `4` IPv4 / IPv6 出口切换
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

- 使用随机推荐端口安装
- 自定义端口后安装
- 大部分菜单支持直接回车，默认选择 `1`
- 最外层主菜单不默认选择，避免误触安装

每次安装或重装时，都会额外让你选择：

- 重新随机生成 UUID
- 手动输入 UUID
- 是否开放端口并关闭防火墙

主界面会额外显示：

- 本机 IPv4
- 本机 IPv6
- 当前出口模式
- 当前 Argo HOST（启用 Argo 后）

## 端口策略

- 默认是随机推荐端口。
- `VLESS Reality`、`AnyTLS`、`TUIC v5`、`Hysteria2` 会从高位端口里随机分配，并避开 `80`、`443`、`8443` 这类常用端口。
- `WS 本地端口` 会从 Cloudflare 常用端口里选择，例如 `8080`、`2052`、`2053`、`2082`、`2083`、`2086`、`2087`、`2095`、`2096`、`8880`。

端口设置支持：

- 重新随机推荐端口
- 手动自定义端口
- 设置 `TUIC v5` / `Hysteria2` 端口跳跃

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

如果 Litebox 已经安装，再进入主菜单选择 `1` 不会直接重装，脚本会在安装菜单下方提示你先卸载再重新安装，避免旧配置和新配置混在一起。

重置临时 Argo 后，脚本会主动等待真实 HOST，并在菜单和节点信息里显示。

选择 `6` 刷新并查看节点后，脚本会停留在节点结果页，按回车后才返回主菜单，方便直接复制链接。

`TUIC v5` 和 `Hysteria2` 的端口跳跃采用轻量的 UDP 端口重定向方式实现，可以填写多个端口，使用逗号分隔。

## 生成文件

- `/etc/litebox/config.json`
- `/etc/litebox/env`
- `/etc/litebox/links.txt`
- `/etc/systemd/system/litebox.service`
- `/etc/systemd/system/litebox-argo.service`
- `/usr/local/bin/litebox`
- `/usr/local/bin/LB`
- `/usr/local/bin/lb`

## 卸载说明

选择菜单中的 `8`，会彻底删除：

- `sing-box`
- `cloudflared`
- `litebox` / `sb`
- `systemd` 服务
- `/etc/litebox` 下全部配置和证书

卸载完成后会直接退出，不再保留旧配置。

## 说明

- `links.txt` 保存节点信息，权限是 `0600`。
- AnyTLS、TUIC、Hysteria2 使用自签证书，客户端通常需要开启 `insecure` 或 `allow_insecure`。
- VLESS Reality 不需要证书，使用 `xtls-rprx-vision`。
- 安装时如果选择自动处理，脚本会尝试开放节点端口并关闭常见防火墙。
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
