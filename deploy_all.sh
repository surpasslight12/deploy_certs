#!/bin/bash
# ==========================================================
# deploy_all.sh: 自动化证书部署一键脚本
#
# 纯 Bash 实现，依赖: curl, jq, openssl (sshpass/ssh/scp 仅 OPNsense 需要)
# 统一加载 deploy_config.json 配置，按平台注册表调度各子脚本
# 完成证书部署，并在部署后抓取远端证书指纹做闭环验证。
#
# 平台配置段均为可选: 配置文件中未定义的平台自动跳过。
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
LOG_FILE="$WORKSPACE_DIR/deploy_history.log"
CONFIG_FILE="$WORKSPACE_DIR/deploy_config.json"

# 日志轮换：超过 LOG_MAX_BYTES 时滚动到 .1 ... .N，最旧的丢弃
# 可通过环境变量覆盖，默认 1 MiB × 5 份 = ~6 MiB 总量
LOG_MAX_BYTES=${LOG_MAX_BYTES:-1048576}
LOG_KEEP_FILES=${LOG_KEEP_FILES:-5}

# 部署后验证: 远端服务可能仍在后台重载，指纹不一致时重试
VERIFY_RETRIES=${VERIFY_RETRIES:-6}
VERIFY_DELAY=${VERIFY_DELAY:-5}

EXIT_SUCCESS=0
EXIT_RUNTIME_ERROR=1

# ==========================================================
# 平台注册表
#
# 各平台按此顺序部署；状态文件为 .last_deploy_<平台名>。
# 新增平台的方法见下方 "平台插件定义" 一节。
# ==========================================================
PLATFORMS=(pve opnsense truenas)
declare -A PLATFORM_LABELS=(
    [pve]="PVE"
    [opnsense]="OPNsense"
    [truenas]="TrueNAS"
)
# 每个平台的执行结果: disabled|skipped|success|failed|verify_failed
declare -A RESULT=()

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

# jq 辅助函数: 读取值，空值返回默认值
jq_val() { jq -r "$1 // \"$2\"" "$CONFIG_FILE"; }

# jq 辅助函数: 读取必要字段，缺失时报错退出
jq_req() {
    local val
    val=$(jq -r "$1 // empty" "$CONFIG_FILE")
    if [ -z "$val" ]; then
        log_error "配置文件缺少必要字段: $1"
        exit "$EXIT_RUNTIME_ERROR"
    fi
    echo "$val"
}

# 判断平台配置段是否存在 (平台可选: 未定义的平台自动跳过)
platform_enabled() {
    [ "$(jq -r ".$1 | type" "$CONFIG_FILE" 2>/dev/null)" = "object" ]
}

# 校验配置文件并统计启用的平台
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "集中配置文件不存在: $CONFIG_FILE"
        exit "$EXIT_RUNTIME_ERROR"
    fi

    if ! command -v jq &>/dev/null; then
        log_error "缺少依赖 jq，请安装: sudo apt install -y jq"
        exit "$EXIT_RUNTIME_ERROR"
    fi

    # 验证 JSON 格式
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        log_error "配置文件 JSON 格式错误: $CONFIG_FILE"
        exit "$EXIT_RUNTIME_ERROR"
    fi

    # 统计启用的平台 (配置段均为可选，但至少需启用一个)
    ENABLED_PLATFORMS=()
    local name
    for name in "${PLATFORMS[@]}"; do
        if platform_enabled "$name"; then
            ENABLED_PLATFORMS+=("$name")
        fi
    done
    if [ ${#ENABLED_PLATFORMS[@]} -eq 0 ]; then
        log_error "配置文件未定义任何平台配置段 (可选: ${PLATFORMS[*]})"
        exit "$EXIT_RUNTIME_ERROR"
    fi
}

# ==========================================================
# 平台插件定义
#
# 新增平台只需三步:
#   1. 将平台名加入 PLATFORMS 与 PLATFORM_LABELS
#   2. 实现 platform_init_<名>: 读取配置并设置接口变量
#        P_CERT        本地证书路径 (用于变更检测与部署后验证)
#        P_VERIFY_HOST 部署后验证的主机
#        P_VERIFY_PORT 部署后验证的 TLS 端口 (0=跳过验证)
#   3. 实现 platform_cmd_<名>: 通过 nameref 填充部署命令数组
# ==========================================================

platform_init_pve() {
    CFG_PVE_HOST=$(jq_req '.pve.host')
    CFG_PVE_NODE=$(jq_val '.pve.node' 'pve')
    CFG_PVE_TOKEN_ID=$(jq_req '.pve.token_id')
    CFG_PVE_TOKEN_SECRET=$(jq_req '.pve.token_secret')
    CFG_PVE_CERT=$(jq_req '.pve.cert')
    CFG_PVE_KEY=$(jq_req '.pve.key')

    P_CERT="$CFG_PVE_CERT"
    P_VERIFY_HOST="$CFG_PVE_HOST"
    P_VERIFY_PORT=$(jq_val '.pve.verify_port' '8006')
}

platform_cmd_pve() {
    # shellcheck disable=SC2178  # nameref，各函数独立作用域
    local -n _c="$1"
    _c=(
        "$WORKSPACE_DIR/deploy_to_pve.sh"
        -H "$CFG_PVE_HOST"
        -n "$CFG_PVE_NODE"
        --token-id "$CFG_PVE_TOKEN_ID"
        --token-secret "$CFG_PVE_TOKEN_SECRET"
        -c "$CFG_PVE_CERT"
        -k "$CFG_PVE_KEY"
    )
}

platform_init_opnsense() {
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

    P_CERT="$CFG_OPNS_CERT"
    P_VERIFY_HOST="$CFG_OPNS_HOST"
    P_VERIFY_PORT=$(jq_val '.opnsense.verify_port' "$CFG_OPNS_API_PORT")
}

platform_cmd_opnsense() {
    # shellcheck disable=SC2178  # nameref，各函数独立作用域
    local -n _c="$1"
    _c=(
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
}

platform_init_truenas() {
    CFG_TRUE_HOST=$(jq_req '.truenas.host')
    CFG_TRUE_API_KEY=$(jq_req '.truenas.api_key')
    CFG_TRUE_CERT=$(jq_req '.truenas.cert')
    CFG_TRUE_KEY=$(jq_req '.truenas.key')
    CFG_TRUE_NAME=$(jq_val '.truenas.name' '')
    CFG_TRUE_PREFIX=$(jq_val '.truenas.prefix' 'truenas_certs_')
    CFG_TRUE_KEEP=$(jq_val '.truenas.keep' '2')
    CFG_TRUE_WS_PATH=$(jq_val '.truenas.ws_path' '/api/current')

    P_CERT="$CFG_TRUE_CERT"
    P_VERIFY_HOST="$CFG_TRUE_HOST"
    P_VERIFY_PORT=$(jq_val '.truenas.verify_port' '443')
}

platform_cmd_truenas() {
    # shellcheck disable=SC2178  # nameref，各函数独立作用域
    local -n _c="$1"
    _c=(
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
        _c+=( -n "$CFG_TRUE_NAME" )
    fi
}

# ==========================================================
# 系统依赖检查 (按启用平台按需检查)
# ==========================================================
check_dependencies() {
    local deps=(curl jq openssl) missing=()
    # sshpass/ssh/scp 仅 OPNsense 平台需要
    if platform_enabled opnsense; then
        deps+=(sshpass ssh scp)
    fi
    local cmd
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少系统依赖: ${missing[*]}"
        log_info "请安装: sudo apt install -y ${missing[*]}"
        exit "$EXIT_RUNTIME_ERROR"
    fi
    log_success "系统依赖检查通过 (${deps[*]})"
}

# ==========================================================
# 部署辅助函数
# ==========================================================

# 计算证书文件中首张证书 (fullchain 的叶子证书) 的 SHA256 指纹
cert_fingerprint() {
    openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null | cut -d= -f2
}

# 检查单个平台证书是否有更新 (基于证书指纹，而非 mtime)
# 用法: cert_updated <cert_file> <state_file> <platform_label>
# 返回 0=需要部署，1=跳过
cert_updated() {
    local cert="$1" state_file="$2" label="$3"
    if [ -z "$cert" ]; then
        log_warning "[$label] 未配置证书路径，将强制执行部署"
        return 0
    fi
    if [ ! -f "$cert" ]; then
        log_warning "[$label] 证书文件不存在 ($cert)，将强制执行部署"
        return 0
    fi
    local fp last
    fp=$(cert_fingerprint "$cert")
    if [ -z "$fp" ]; then
        log_warning "[$label] 无法解析证书指纹 ($cert)，将强制执行部署"
        return 0
    fi
    last=$(cat "$state_file" 2>/dev/null) || last=""
    if [ "$fp" = "$last" ]; then
        log_info "[$label] 证书指纹与上次成功部署一致，跳过部署"
        return 1
    fi
    log_success "[$label] 检测到证书内容有变化，开始部署"
    return 0
}

# 部署后闭环验证: 抓取远端实际提供的证书指纹与本地比对
# 用法: verify_deployed_cert <cert_file> <host> <port> <platform_label>
# port 为 0 或空时跳过验证
verify_deployed_cert() {
    local cert="$1" host="$2" port="$3" label="$4"
    if [ -z "$port" ] || [ "$port" = "0" ]; then
        log_info "[$label] 已配置跳过部署后验证 (verify_port=0)"
        return 0
    fi
    local expected actual attempt
    expected=$(cert_fingerprint "$cert")
    if [ -z "$expected" ]; then
        log_warning "[$label] 无法计算本地证书指纹，跳过部署后验证"
        return 0
    fi
    log_info "[$label] 验证 ${host}:${port} 实际生效的证书..."
    for (( attempt = 1; attempt <= VERIFY_RETRIES; attempt++ )); do
        actual=$(echo | openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
        if [ -n "$actual" ] && [ "$actual" = "$expected" ]; then
            log_success "[$label] 验证通过: 远端证书指纹与本地一致"
            return 0
        fi
        # 远端服务可能仍在后台重载，稍候重试
        if [ "$attempt" -lt "$VERIFY_RETRIES" ]; then
            log_info "[$label] 指纹尚未一致，${VERIFY_DELAY} 秒后重试 (${attempt}/${VERIFY_RETRIES})"
            sleep "$VERIFY_DELAY"
        fi
    done
    log_error "[$label] 验证失败: 远端证书指纹与本地不一致 (远端: ${actual:-无法获取})"
    return 1
}

# 通用平台部署流水线: 配置检查 -> 变更检测 -> 执行子脚本 -> 部署后验证 -> 记录指纹
# 用法: run_platform <平台名> <序号> <总数>，结果写入 RESULT[<平台名>]
run_platform() {
    local name="$1" idx="$2" total="$3"
    local label="${PLATFORM_LABELS[$name]}"
    local state_file="$WORKSPACE_DIR/.last_deploy_${name}"

    log_info "[$idx/$total] 部署到 $label"

    if ! platform_enabled "$name"; then
        log_info "[$label] 配置文件中未定义该平台，跳过"
        RESULT[$name]="disabled"
        return 0
    fi

    "platform_init_$name"

    if ! cert_updated "$P_CERT" "$state_file" "$label"; then
        RESULT[$name]="skipped"
        return 0
    fi

    local cmd=()
    "platform_cmd_$name" cmd

    "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        RESULT[$name]="failed"
        return 0
    fi

    if ! verify_deployed_cert "$P_CERT" "$P_VERIFY_HOST" "$P_VERIFY_PORT" "$label"; then
        # 不记录指纹，下次运行会重试部署
        RESULT[$name]="verify_failed"
        return 0
    fi

    local fp
    fp=$(cert_fingerprint "$P_CERT")
    if [ -n "$fp" ]; then
        echo "$fp" > "$state_file"
    fi
    RESULT[$name]="success"
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
        exit "$EXIT_RUNTIME_ERROR"
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

log_info "阶段 0: 加载集中配置"
load_config
log_success "已加载配置文件: $CONFIG_FILE (启用平台: ${ENABLED_PLATFORMS[*]})"

log_info "阶段 1: 检查系统依赖"
check_dependencies

log_info "阶段 2: 按平台独立检查证书并执行部署"

TOTAL=${#PLATFORMS[@]}
IDX=0
for name in "${PLATFORMS[@]}"; do
    IDX=$((IDX + 1))
    run_platform "$name" "$IDX" "$TOTAL"
done

log_info "部署结果总结"
OVERALL_FAILED=false
ANY_DEPLOYED=false
for name in "${PLATFORMS[@]}"; do
    label=$(printf '%-9s' "${PLATFORM_LABELS[$name]}:")
    case "${RESULT[$name]:-failed}" in
        disabled)      log_info    "$label 未配置 (跳过)" ;;
        skipped)       log_info    "$label 已跳过 (证书未更新)" ;;
        success)       log_success "$label 成功 (远端指纹验证通过)"; ANY_DEPLOYED=true ;;
        verify_failed) log_error   "$label 失败 (子脚本成功但远端证书验证未通过)"; OVERALL_FAILED=true ;;
        *)             log_error   "$label 失败"; OVERALL_FAILED=true ;;
    esac
done

# 任何执行过的平台失败则整体失败
if $OVERALL_FAILED; then
    log_error "部分或全部平台部署失败，请检查详细日志: $LOG_FILE"
    exit "$EXIT_RUNTIME_ERROR"
fi

if $ANY_DEPLOYED; then
    log_success "所有执行的平台部署任务顺利完成，且远端证书验证通过"
else
    log_info "所有启用平台的证书均无更新，无需部署"
fi
exit $EXIT_SUCCESS
