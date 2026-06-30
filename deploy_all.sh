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
STATE_FILE_PVE="$WORKSPACE_DIR/.last_deploy_pve"
STATE_FILE_OPNS="$WORKSPACE_DIR/.last_deploy_opnsense"
STATE_FILE_TRUE="$WORKSPACE_DIR/.last_deploy_truenas"
LOG_FILE="$WORKSPACE_DIR/deploy_history.log"
CONFIG_FILE="$WORKSPACE_DIR/deploy_config.json"

# 日志轮换：超过 LOG_MAX_BYTES 时滚动到 .1 ... .N，最旧的丢弃
# 可通过环境变量覆盖，默认 1 MiB × 5 份 = ~6 MiB 总量
LOG_MAX_BYTES=${LOG_MAX_BYTES:-1048576}
LOG_KEEP_FILES=${LOG_KEEP_FILES:-5}

EXIT_SUCCESS=0
EXIT_RUNTIME_ERROR=1

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

# 检查并轮换过大的部署日志。需在首次写日志前调用
rotate_log_if_needed() {
    [ -f "$LOG_FILE" ] || return 0
    local size
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null) || return 0
    [ "$size" -le "$LOG_MAX_BYTES" ] && return 0

    # 丢弃最旧的一份
    [ -f "${LOG_FILE}.${LOG_KEEP_FILES}" ] && rm -f "${LOG_FILE}.${LOG_KEEP_FILES}"
    # 由旧到新依次后移: .N-1 -> .N, ..., .1 -> .2
    local i
    for (( i = LOG_KEEP_FILES - 1; i >= 1; i-- )); do
        [ -f "${LOG_FILE}.${i}" ] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    done
    # 当前日志 -> .1。轮换后首条日志会创建一个新的 LOG_FILE
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
}

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

# 所有分支（子命令 / 主逻辑）写第一条日志前，先检查是否需要轮换
rotate_log_if_needed

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

        # 在 acme.sh 执行时间基础上延后 1 小时，确保证书已续签完毕
        if [[ "$hour" =~ ^[0-9]+$ ]]; then
            hour=$(( (hour + 1) % 24 ))
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
            log_info "设定为 acme.sh 执行后 1 小时运行，各平台独立检测证书更新后按需部署"
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
log_success "已加载配置文件: $CONFIG_FILE"

# 检查单个平台证书是否有更新
# 用法: cert_updated <cert_file> <state_file> <platform_name>
# 返回 0=需要部署，1=跳过
cert_updated() {
    local cert="$1" state_file="$2" platform="$3"
    if [ -z "$cert" ]; then
        log_warning "[$platform] 未配置证书路径，将强制执行部署"
        return 0
    fi
    if [ ! -f "$cert" ]; then
        log_warning "[$platform] 证书文件不存在 ($cert)，将强制执行部署"
        return 0
    fi
    local cert_mtime last_deploy
    cert_mtime=$(stat -c %Y "$cert")
    if [ -f "$state_file" ]; then
        last_deploy=$(cat "$state_file")
    else
        last_deploy=0
    fi
    if [ "$cert_mtime" -le "$last_deploy" ]; then
        log_info "[$platform] 证书自上次部署($(date -d "@$last_deploy" '+%Y-%m-%d %H:%M:%S'))以来没有更新，跳过部署"
        return 1
    else
        log_success "[$platform] 检测到证书有新版本，开始部署"
        return 0
    fi
}

log_info "阶段 2: 按平台独立检查证书并执行部署"

# --- PVE ---
log_info "[1/3] 部署到 Proxmox VE (PVE)"
PVE_STATUS=0
PVE_SKIPPED=false
if cert_updated "$CFG_PVE_CERT" "$STATE_FILE_PVE" "PVE"; then
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
    if [ "$PVE_STATUS" -eq 0 ]; then
        date +%s > "$STATE_FILE_PVE"
    fi
else
    PVE_SKIPPED=true
fi

# --- OPNsense ---
log_info "[2/3] 部署到 OPNsense"
OPNS_STATUS=0
OPNS_SKIPPED=false
if cert_updated "$CFG_OPNS_CERT" "$STATE_FILE_OPNS" "OPNsense"; then
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
    if [ "$OPNS_STATUS" -eq 0 ]; then
        date +%s > "$STATE_FILE_OPNS"
    fi
else
    OPNS_SKIPPED=true
fi

# --- TrueNAS ---
log_info "[3/3] 部署到 TrueNAS"
TRUE_STATUS=0
TRUE_SKIPPED=false
if cert_updated "$CFG_TRUE_CERT" "$STATE_FILE_TRUE" "TrueNAS"; then
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
    if [ "$TRUE_STATUS" -eq 0 ]; then
        date +%s > "$STATE_FILE_TRUE"
    fi
else
    TRUE_SKIPPED=true
fi

log_info "部署结果总结"
if   $PVE_SKIPPED;              then log_info    "PVE:      已跳过 (证书未更新)"
elif [ "$PVE_STATUS" -eq 0 ];   then log_success "PVE:      成功"
else                                  log_error  "PVE:      失败"
fi
if   $OPNS_SKIPPED;             then log_info    "OPNsense: 已跳过 (证书未更新)"
elif [ "$OPNS_STATUS" -eq 0 ];  then log_success "OPNsense: 成功"
else                                  log_error  "OPNsense: 失败"
fi
if   $TRUE_SKIPPED;             then log_info    "TrueNAS:  已跳过 (证书未更新)"
elif [ "$TRUE_STATUS" -eq 0 ];  then log_success "TrueNAS:  成功"
else                                  log_error  "TrueNAS:  失败"
fi

# 任何执行过的平台失败则整体失败
if [ "$PVE_STATUS" -ne 0 ] || [ "$OPNS_STATUS" -ne 0 ] || [ "$TRUE_STATUS" -ne 0 ]; then
    log_error "部分或全部平台部署失败，请检查详细日志: $LOG_FILE"
    exit $EXIT_RUNTIME_ERROR
fi

if $PVE_SKIPPED && $OPNS_SKIPPED && $TRUE_SKIPPED; then
    log_info "所有平台证书均无更新，无需部署"
else
    log_success "所有执行的平台部署任务顺利完成"
fi
exit $EXIT_SUCCESS
