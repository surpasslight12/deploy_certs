#!/bin/bash
# ==========================================================
# deploy_all.sh: 自动化证书部署一键脚本
#
# 纯 Bash 实现，依赖: curl, jq, sshpass, ssh, scp
# 统一加载 deploy_config.json 配置，按序调度 PVE、OPNsense、
# TrueNAS 三个子脚本完成证书部署。
#
# 用法:
#   deploy_all.sh             一键执行所有平台的证书部署
#   deploy_all.sh setup-cron  检查 acme.sh 并配置定时任务
#   deploy_all.sh remove-cron 移除定时任务
# ==========================================================

# 注意: 不使用 set -euo pipefail，需要运行所有子脚本并汇总结果

# ==========================================================
# 常量定义
# ==========================================================
WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$WORKSPACE_DIR/.last_deploy_time"
LOG_FILE="$WORKSPACE_DIR/deploy_history.log"
CONFIG_FILE="$WORKSPACE_DIR/deploy_config.json"

EXIT_SUCCESS=0
EXIT_RUNTIME_ERROR=1

MONITOR_CERT=""

# ==========================================================
# 工具函数
# ==========================================================
log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log_info()    { log "INFO: $1"; }
log_warning() { log "WARNING: $1"; }
log_error()   { log "ERROR: $1"; }
log_success() { log "SUCCESS: $1"; }

print_usage() {
    log_info "用法:"
    log_info "  $0             一键执行所有平台的证书部署"
    log_info "  $0 setup-cron  检查 acme.sh 并自动将自己配置为定时任务"
    log_info "  $0 remove-cron 卸载本脚本的定时任务"
}

# ==========================================================
# 配置加载
# ==========================================================

# 使用 jq 解析 JSON 配置文件并设置环境变量
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "集中配置文件不存在: $CONFIG_FILE"
        exit $EXIT_RUNTIME_ERROR
    fi

    if ! command -v jq &>/dev/null; then
        log_error "缺少依赖 jq，请安装: sudo apt install -y jq"
        exit $EXIT_RUNTIME_ERROR
    fi

    # 验证 JSON 格式
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        log_error "配置文件 JSON 格式错误: $CONFIG_FILE"
        exit $EXIT_RUNTIME_ERROR
    fi

    # 验证必需的配置段
    for section in pve opnsense truenas; do
        if [ "$(jq -r ".$section | type" "$CONFIG_FILE")" != "object" ]; then
            log_error "配置文件缺少 $section 配置对象"
            exit $EXIT_RUNTIME_ERROR
        fi
    done

    # jq 辅助函数: 读取值，空值返回默认值
    jq_val() { jq -r "$1 // \"$2\"" "$CONFIG_FILE"; }
    jq_req() {
        local val
        val=$(jq -r "$1 // empty" "$CONFIG_FILE")
        if [ -z "$val" ]; then
            log_error "配置文件缺少必要字段: $1"
            exit $EXIT_RUNTIME_ERROR
        fi
        echo "$val"
    }

    CFG_MONITOR_CERT=$(jq_val '.monitor_cert' '')

    CFG_PVE_HOST=$(jq_req '.pve.host')
    CFG_PVE_NODE=$(jq_val '.pve.node' 'pve')
    CFG_PVE_TOKEN_ID=$(jq_req '.pve.token_id')
    CFG_PVE_TOKEN_SECRET=$(jq_req '.pve.token_secret')
    CFG_PVE_CERT=$(jq_req '.pve.cert')
    CFG_PVE_KEY=$(jq_req '.pve.key')

    CFG_OPNS_HOST=$(jq_req '.opnsense.host')
    CFG_OPNS_PORT=$(jq_val '.opnsense.port' '22')
    CFG_OPNS_USER=$(jq_req '.opnsense.user')
    CFG_OPNS_PASSWORD=$(jq_req '.opnsense.password')
    CFG_OPNS_API_KEY=$(jq_req '.opnsense.api_key')
    CFG_OPNS_API_SECRET=$(jq_req '.opnsense.api_secret')
    CFG_OPNS_API_PORT=$(jq_val '.opnsense.api_port' '443')
    CFG_OPNS_CERT=$(jq_req '.opnsense.cert')
    CFG_OPNS_KEY=$(jq_req '.opnsense.key')
    CFG_OPNS_REMOTE_DIR=$(jq_val '.opnsense.remote_dir' '/tmp')
    CFG_OPNS_PREFIX=$(jq_val '.opnsense.prefix' 'opnsense_certs_')
    CFG_OPNS_KEEP=$(jq_val '.opnsense.keep' '2')

    CFG_TRUE_HOST=$(jq_req '.truenas.host')
    CFG_TRUE_API_KEY=$(jq_req '.truenas.api_key')
    CFG_TRUE_CERT=$(jq_req '.truenas.cert')
    CFG_TRUE_KEY=$(jq_req '.truenas.key')
    CFG_TRUE_NAME=$(jq_val '.truenas.name' '')
    CFG_TRUE_PREFIX=$(jq_val '.truenas.prefix' 'truenas_certs_')
    CFG_TRUE_KEEP=$(jq_val '.truenas.keep' '2')
    CFG_TRUE_WS_PATH=$(jq_val '.truenas.ws_path' '/api/current')
}

# ==========================================================
# 系统依赖检查
# ==========================================================
check_dependencies() {
    local missing=()
    for cmd in curl jq sshpass ssh scp; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少系统依赖: ${missing[*]}"
        log_info "请安装: sudo apt install -y ${missing[*]}"
        exit $EXIT_RUNTIME_ERROR
    fi
}

# ==========================================================
# 参数处理
# ==========================================================

# 卸载定时任务
if [ "${1:-}" == "remove-cron" ]; then
    DEPLOY_SCRIPT="$WORKSPACE_DIR/deploy_all.sh"
    log_info "===== 移除部署定时任务 ====="
    if crontab -l 2>/dev/null | grep -q "$DEPLOY_SCRIPT"; then
        crontab -l | grep -v "$DEPLOY_SCRIPT" | crontab -
        log_success "成功从 crontab 中移除了部署任务"
    else
        log_info "crontab 中未发现本脚本的定时任务"
    fi
    exit $EXIT_SUCCESS
fi

# 设置定时任务
if [ "${1:-}" == "setup-cron" ]; then
    log_info "===== 检查 acme.sh 定时任务 ====="
    ACME_CRON=$(crontab -l 2>/dev/null | grep "acme.sh" | grep -v "^#")
    
    if [ -z "$ACME_CRON" ]; then
        log_error "系统未安装 acme.sh 任务 (未在 crontab 中找到)"
        exit $EXIT_RUNTIME_ERROR
    else
        log_info "找到 acme.sh 定时任务: $ACME_CRON"

        read -r min hour dom mon dow rest <<< "$ACME_CRON"

        if [[ ! "$min" =~ ^[0-9\*]+$ ]]; then
            min="0"
            hour="3"
            dom="*"
            mon="*"
            dow="*"
        fi

        DEPLOY_SCRIPT="$WORKSPACE_DIR/deploy_all.sh"
        NEW_CRON="$min $hour $dom $mon $dow $DEPLOY_SCRIPT"

        if crontab -l 2>/dev/null | grep -q "$DEPLOY_SCRIPT"; then
            log_info "部署脚本已存在于 crontab 中，无需重复添加"
            log_info "当前任务为: $(crontab -l 2>/dev/null | grep "$DEPLOY_SCRIPT")"
        else
            (crontab -l 2>/dev/null; echo "$NEW_CRON") | crontab -
            log_success "自动部署定时任务设定成功"
            log_info "已加入定时任务: $NEW_CRON"
            log_info "设定为与 acme.sh 完全相同的时间执行，仅在检测到新证书后才会实际部署"
        fi
    fi
    exit $EXIT_SUCCESS
fi

# 显示帮助
if [ "${1:-}" == "-h" ] || [ "${1:-}" == "--help" ]; then
    print_usage
    exit $EXIT_SUCCESS
fi

# ==========================================================
# 主逻辑
# ==========================================================
log_info "自动化部署流水线启动"

log_info "阶段 0: 检查系统依赖"
check_dependencies
log_success "系统依赖检查通过 (curl, jq, sshpass, ssh, scp)"

log_info "阶段 1: 加载集中配置"
load_config
MONITOR_CERT="$CFG_MONITOR_CERT"
log_success "已加载配置文件: $CONFIG_FILE"

log_info "阶段 2: 检查证书文件更新状态"
if [ -z "$MONITOR_CERT" ]; then
    log_warning "未配置 monitor_cert，跳过时间检查并继续执行部署"
elif [ ! -f "$MONITOR_CERT" ]; then
    log_warning "监控的证书文件不存在 ($MONITOR_CERT)，跳过时间检查并继续执行部署"
else
    CERT_MTIME=$(stat -c %Y "$MONITOR_CERT")
    if [ -f "$STATE_FILE" ]; then
        LAST_DEPLOY_TIME=$(cat "$STATE_FILE")
    else
        LAST_DEPLOY_TIME=0
    fi
    
    if [ "$CERT_MTIME" -le "$LAST_DEPLOY_TIME" ]; then
        log_info "证书自上次部署($LAST_DEPLOY_TIME)以来没有更新($CERT_MTIME)，取消执行"
        exit $EXIT_SUCCESS
    else
        log_success "检测到证书有新版本，开始执行部署逻辑"
    fi
fi

log_info "阶段 3: 开始执行证书部署"

log_info "[1/3] 部署到 Proxmox VE (PVE)"
PVE_CMD=(
    "$WORKSPACE_DIR/deploy_to_pve.sh"
    -H "$CFG_PVE_HOST"
    -n "$CFG_PVE_NODE"
    --token-id "$CFG_PVE_TOKEN_ID"
    --token-secret "$CFG_PVE_TOKEN_SECRET"
    -c "$CFG_PVE_CERT"
    -k "$CFG_PVE_KEY"
)
"${PVE_CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
PVE_STATUS=${PIPESTATUS[0]}

log_info "[2/3] 部署到 OPNsense"
OPNS_CMD=(
    "$WORKSPACE_DIR/deploy_to_opnsense.sh"
    -H "$CFG_OPNS_HOST"
    -p "$CFG_OPNS_PORT"
    -u "$CFG_OPNS_USER"
    -P "$CFG_OPNS_PASSWORD"
    -c "$CFG_OPNS_CERT"
    -k "$CFG_OPNS_KEY"
    -d "$CFG_OPNS_REMOTE_DIR"
    --api-key "$CFG_OPNS_API_KEY"
    --api-secret "$CFG_OPNS_API_SECRET"
    --api-port "$CFG_OPNS_API_PORT"
    --prefix "$CFG_OPNS_PREFIX"
    --keep "$CFG_OPNS_KEEP"
)
"${OPNS_CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
OPNS_STATUS=${PIPESTATUS[0]}

log_info "[3/3] 部署到 TrueNAS"
TRUE_CMD=(
    "$WORKSPACE_DIR/deploy_to_truenas.sh"
    -H "$CFG_TRUE_HOST"
    -A "$CFG_TRUE_API_KEY"
    -c "$CFG_TRUE_CERT"
    -k "$CFG_TRUE_KEY"
    --ws-path "$CFG_TRUE_WS_PATH"
    --prefix "$CFG_TRUE_PREFIX"
    --keep "$CFG_TRUE_KEEP"
)
if [ -n "$CFG_TRUE_NAME" ]; then
    TRUE_CMD+=( -n "$CFG_TRUE_NAME" )
fi
"${TRUE_CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
TRUE_STATUS=${PIPESTATUS[0]}

log_info "部署结果总结"
if [ "$PVE_STATUS" -eq 0 ];  then log_success "PVE: 成功";      else log_error "PVE: 失败"; fi
if [ "$OPNS_STATUS" -eq 0 ]; then log_success "OPNsense: 成功";  else log_error "OPNsense: 失败"; fi
if [ "$TRUE_STATUS" -eq 0 ]; then log_success "TrueNAS: 成功";   else log_error "TrueNAS: 失败"; fi

if [ "$PVE_STATUS" -eq 0 ] && [ "$OPNS_STATUS" -eq 0 ] && [ "$TRUE_STATUS" -eq 0 ]; then
    log_success "所有平台部署任务顺利完成"
    if [ -f "$MONITOR_CERT" ]; then
        date +%s > "$STATE_FILE"
        log_info "已记录部署时间状态到 $STATE_FILE"
    fi
    exit $EXIT_SUCCESS
else
    log_error "部分或全部平台部署失败，请检查详细日志: $LOG_FILE"
    exit $EXIT_RUNTIME_ERROR
fi
