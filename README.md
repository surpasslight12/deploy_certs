# 自动化 SSL 证书部署工具 (Auto SSL Deployer)

这是一个用于将本地（通常由 acme.sh 签发）的 SSL 证书一键推送到家庭/企业内网多个系统（PVE、OPNsense、TrueNAS）的自动化脚本项目。本工具全自动处理证书上传、旧证书清理和 Web 服务重载。

## 功能特点
- **纯 Bash 实现**：所有部署脚本均为 Bash，不依赖 Python 虚拟环境或 pip 包。
- **模块化部署设计**：各个平台（PVE/OPNsense/TrueNAS）分别对应一个独立的 .sh 部署模块。
- **无需客户端代理**：利用各系统的原生 API 或底层配置执行无损替换和刷新。
- **幂等性与垃圾回收**：不会因多次运行而生成重复证书。OPNsense/TrueNAS 脚本自带旧证书清理逻辑（默认保留最新2个），保持配置干净。
- **一键自动化 (deploy_all.sh)**：包含系统依赖检查、配置加载（jq 解析 JSON）、流程串联调度与执行日志记录功能。
- **Cron 同步联动**：提供 setup-cron 快速配置，直接嗅探 acme.sh 的定时任务时间并注册伴随任务。
- **AI 友好注释**：每个脚本头部包含完整的用途说明和参数接口，便于维护时保持逻辑一致性。

## 文件结构
| 文件名 | 功能描述 |
| ------ | -------- |
| deploy_all.sh | **主入口脚本**。加载配置、检查依赖、调度子脚本、设置/卸载定时任务。 |
| deploy_to_pve.sh | 利用 Proxmox VE 官方 REST API 将证书上传到节点并触发后台 pveproxy 重载。 |
| deploy_to_opnsense.sh | 采用 "官方 Trust API + SSH 绑定" 的混合实现：用官方 API 导入/清理证书，再通过 SSH 更新 Web GUI 证书绑定并重载。 |
| deploy_to_truenas.sh | 采用 TrueNAS WebSocket JSON-RPC 2.0 API (通过 websocat) 导入证书、更新 UI 绑定并清理旧证书。 |

### 系统依赖
| 工具 | 用途 | 安装命令 |
|------|------|----------|
| curl | HTTP/HTTPS 请求 | 通常已预装 |
| jq | JSON 解析 | sudo apt install -y jq |
| sshpass | SSH 密码认证 | sudo apt install -y sshpass |
| ssh / scp | 远程执行与文件传输 | 通常已预装 |
| websocat | TrueNAS WebSocket 通信 | 脚本自动下载（也可手动安装） |

> **注意**: TrueNAS 25.04 弃用了 REST API v2.0，26+ 完全移除。TrueNAS 部署脚本使用 WebSocket JSON-RPC 2.0 协议，通过 `websocat` 实现。如果系统 PATH 中没有 `websocat`，脚本会自动从 GitHub 下载到 `.bin/` 目录。

---

## 极速上手

### 1. 修改集中配置文件 (非常重要)
在使用工具前，请只修改脚本目录下的 deploy_config.json。deploy_all.sh 会统一读取这个文件，并把参数分别传给 PVE、OPNsense、TrueNAS 三个部署脚本。

各平台 (pve / opnsense / truenas) 的 `cert` 字段同时用于"推送内容"和"变更检测"：脚本会比较该证书文件的 mtime 与该平台上一次成功部署的时间戳，仅在证书真正续签后才触发对应平台的部署，三个平台彼此独立、互不影响。

PVE 仅支持官方 API Token 认证。
- token_id 的格式为 USER@REALM!TOKENID，例如 root@pam!deploycerts。
- token_secret 只会在创建 token 时显示一次，需要自行保存后填入配置文件。

OPNsense 采用混合实现。
- api_key 和 api_secret 是必填项，脚本会通过官方 Trust API 导入证书、清理旧证书并触发 trust reconfigure。
- 由于 Web GUI 的 ssl-certref 绑定仍然依赖旧配置路径，脚本仍会通过 SSH 更新该绑定并重载 Web GUI。

### 2. 触发一次手动部署
配置完成后，直接运行命令：

    bash deploy_all.sh

此命令将按照 PVE -> OPNsense -> TrueNAS 的先后次序开始部署，并在控制台直观地吐出表格结果和异常细节。同时所有的日志细节都会沉淀到目录里的 deploy_history.log 内。

补充说明：三个 Bash 子脚本仍然可以单独执行，但推荐统一通过 deploy_config.json + deploy_all.sh 使用。

安全提示：deploy_config.json 通常包含 API Token、API Key、密码等敏感信息，建议仅保存在本地，避免提交到版本库或分享给他人。

### 3. 配置自动跟随计划任务
如果你的虚拟机装有 acme.sh（且已配置到 Linux Cron 定时任务机制中），可以一键设置与之对齐的计划任务：

    bash deploy_all.sh setup-cron

原理：deploy_all.sh 每次定时触发时，都会先通过 stat 检索证书文件是否有更新过。只有真正发生了证书续期的情况（即文件时间戳 > 本脚本上一次的部署时间戳），脚本才会连环下发去请求你的 PVE / TrueNas 等主机。因此非常安全轻量！

### 4. 停止并移除任务
如未来不再需要自动推送：

    bash deploy_all.sh remove-cron

## 常见问题 (FAQ)
- **缺少系统依赖怎么办？** deploy_all.sh 启动时会自动检查 curl、jq、sshpass、ssh、scp 是否可用，并提示安装命令。
- **TrueNAS 部署后看到多个证书怎么办？** TrueNAS 脚本对于含有 truenas_certs_ 前缀的证书会保证仅保留最新的 2 份。手动创建的其他前缀证书不受影响，需要去面板手动删除。
