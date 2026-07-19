# 自动化 SSL 证书部署工具 (Auto SSL Deployer)

这是一个用于将本地（通常由 acme.sh 签发）的 SSL 证书一键推送到家庭/企业内网多个系统（PVE、OPNsense、TrueNAS）的自动化脚本项目。本工具全自动处理证书上传、旧证书清理和 Web 服务重载。

## 功能特点
- **纯 Bash 实现**：所有部署脚本均为 Bash，不依赖 Python 虚拟环境或 pip 包。
- **插件化平台架构**：`deploy_all.sh` 内建平台注册表，新增平台只需实现 `platform_init_<名>` / `platform_cmd_<名>` 两个接口即可接入流水线。各平台配置段均为可选——未定义的平台自动跳过。
- **基于内容指纹的变更检测**：不再依赖 mtime（容易被 `touch` 误触发），改为对证书文件计算 SHA256 指纹，仅当证书内容真正发生变化时才触发部署。
- **部署后闭环验证**：子脚本返回成功后，自动通过 `openssl s_client` 抓取远端实际生效的证书指纹与本地比对，带重试机制（默认 6 次 × 5 秒间隔），确保证书已实际生效。
- **无需客户端代理**：利用各系统的原生 API 或底层配置执行无损替换和刷新。
- **幂等性与垃圾回收**：不会因多次运行而生成重复证书。OPNsense/TrueNAS 脚本自带旧证书清理逻辑（默认保留最新 2 个），保持配置干净。
- **Cron 同步联动**：提供 setup-cron 快速配置，直接嗅探 acme.sh 的定时任务时间并注册伴随任务。
- **AI 友好注释**：每个脚本头部包含完整的用途说明和参数接口，便于维护时保持逻辑一致性。

## 文件结构
| 文件名 | 功能描述 |
| ------ | -------- |
| deploy_all.sh | **主入口脚本**。加载配置、检查依赖、按平台注册表调度子脚本、部署后闭环验证（指纹比对）、设置/卸载定时任务。 |
| common.sh | **共享库**。提供统一的日志输出、退出码、文件校验与随机后缀工具，供各部署子脚本 source 引入。 |
| deploy_to_pve.sh | 利用 Proxmox VE 官方 REST API 将证书上传到节点并触发后台 pveproxy 重载。 |
| deploy_to_opnsense.sh | 采用 "官方 Trust API + SSH 绑定" 的混合实现：用官方 API 导入/清理证书，再通过 SSH 更新 Web GUI 证书绑定并重载。 |
| deploy_to_truenas.sh | 采用 TrueNAS WebSocket JSON-RPC 2.0 API (通过 websocat) 导入证书、更新 UI 绑定并清理旧证书。 |

### 系统依赖
| 工具 | 用途 | 安装命令 |
|------|------|----------|
| curl | HTTP/HTTPS 请求 | 通常已预装 |
| jq | JSON 解析 | sudo apt install -y jq |
| openssl | 证书指纹计算与部署后验证 | 通常已预装 |
| sshpass | SSH 密码认证（仅 OPNsense 需要） | sudo apt install -y sshpass |
| ssh / scp | 远程执行与文件传输（仅 OPNsense 需要） | 通常已预装 |
| websocat | TrueNAS WebSocket 通信 | 脚本自动下载（也可手动安装） |

> **依赖按需检查**: deploy_all.sh 只检查启用的平台实际需要的依赖。例如不使用 OPNsense 时无需安装 sshpass。

> **注意**: TrueNAS 25.04 弃用了 REST API v2.0，26+ 完全移除。TrueNAS 部署脚本使用 WebSocket JSON-RPC 2.0 协议，通过 `websocat` 实现。如果系统 PATH 中没有 `websocat`，脚本会自动从 GitHub 下载到 `.bin/` 目录。

---

## 极速上手

### 1. 修改集中配置文件 (非常重要)
在使用工具前，请只修改脚本目录下的 deploy_config.json。deploy_all.sh 会统一读取这个文件，并把参数分别传给 PVE、OPNsense、TrueNAS 三个部署脚本。

各平台 (pve / opnsense / truenas) 的配置段均为**可选**——未在配置文件中定义的平台会自动跳过。
`cert` 字段用于推送内容、变更检测和部署后验证：脚本会计算证书文件的 SHA256 指纹，仅当指纹与上次成功部署不同时才触发部署。三个平台彼此独立、互不影响。

每个平台可选配置 `verify_port`（默认根据平台自动推测），部署完成后脚本会连接该端口抓取远端实际证书并与本地比对，确保服务已重载并生效。设为 `0` 可跳过验证。

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

原理：deploy_all.sh 每次定时触发时，都会计算证书的 SHA256 指纹并与上次成功部署的记录比对。只有证书内容真正变化时才会推送部署，并自动验证远端证书是否实际生效。因此非常安全轻量！

### 4. 停止并移除任务
如未来不再需要自动推送：

    bash deploy_all.sh remove-cron

## 常见问题 (FAQ)
- **缺少系统依赖怎么办？** deploy_all.sh 启动时会自动按启用平台检查依赖（curl / jq / openssl 必装，sshpass / ssh / scp 仅 OPNsense 需要），并提示安装命令。
- **如何只部署部分平台？** 直接从 deploy_config.json 中删除不需要的平台配置段即可，脚本会自动跳过未定义的平台。
- **部署后如何确认证书已生效？** 脚本默认在部署完成后自动抓取远端证书指纹与本地比对（带重试），结果会显示在日志总结中。若想跳过验证，将对应平台的 `verify_port` 设为 `0`。
- **如何新增其他平台（如 Synology / Unifi）？** 参考 deploy_all.sh 中的 "平台插件定义" 一节，实现 `platform_init_<名>` 和 `platform_cmd_<名>` 两个函数，并加入 `PLATFORMS` / `PLATFORM_LABELS` 数组即可。
- **TrueNAS 部署后看到多个证书怎么办？** TrueNAS 脚本对于含有 truenas_certs_ 前缀的证书会保证仅保留最新的 2 份。手动创建的其他前缀证书不受影响，需要去面板手动删除。
