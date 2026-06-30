#!/bin/bash
# ==========================================================
# deploy_to_truenas.sh: 部署 SSL 证书到 TrueNAS
#
# 通过 WebSocket JSON-RPC 2.0 API（websocat）导入证书、
# 更新 UI 绑定并清理旧证书。
# TrueNAS 25.04 弃用 REST API v2.0，26+ 完全移除。
#
# 用法:
#   deploy_to_truenas.sh -H <host> -A <api_key> -c <cert> -k <key> [options]
# ==========================================================

set -euo pipefail

# ==========================================================
# 常量定义
# ==========================================================
DEFAULT_HOST=""
DEFAULT_CERT=""
DEFAULT_KEY=""
DEFAULT_PREFIX="truenas_certs_"
DEFAULT_KEEP=2
DEFAULT_WS_PATH="/api/current"
JOB_TIMEOUT=120
POLL_INTERVAL=1
AUTH_RETRIES=3
RETRY_DELAY=2

# 固定 websocat 版本：本地 .bin/websocat 与此版本不一致时会自动重新下载
# 升级时只需修改此常量
WEBSOCAT_VERSION="1.14.1"
WEBSOCAT_RELEASE_BASE="https://github.com/vi/websocat/releases/download"

EXIT_SUCCESS=0
EXIT_RUNTIME_ERROR=1
EXIT_CERT_NOT_FOUND=2
EXIT_KEY_NOT_FOUND=3
EXIT_INVALID_INPUT=4

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBSOCAT_BIN=""
REQUEST_ID=0

# ==========================================================
# 工具函数
# ==========================================================
print_info()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"; }
print_warning() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1"; }
print_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2; }
print_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1"; }

print_usage() {
    print_info "用法: $0 -H <host> -A <api_key> -c <cert> -k <key> [options]"
}

validate_readable_file() {
    local path="$1" label="$2" exit_code="$3"
    if [ ! -f "$path" ]; then
        print_error "${label}未找到: $path"
        return "$exit_code"
    fi
    if [ ! -r "$path" ]; then
        print_error "${label}不可读: $path"
        return $EXIT_INVALID_INPUT
    fi
    return $EXIT_SUCCESS
}

# ==========================================================
# 特定功能函数: websocat 管理
# ==========================================================

# 获取二进制的 websocat 版本号 (例如 "1.14.1")，无法识别时返回空
get_websocat_version() {
    local bin="$1"
    local out
    out=$("$bin" --version 2>/dev/null) || return 0
    # 期望格式: "websocat 1.14.1"，取第二个字段并去掉可能的前导 v
    echo "$out" | head -n1 | awk '{print $2}' | sed 's/^v//'
}

# 按当前架构解析对应的 websocat 下载 URL
resolve_websocat_url() {
    local version="$1"
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "${WEBSOCAT_RELEASE_BASE}/v${version}/websocat.x86_64-unknown-linux-musl" ;;
        aarch64) echo "${WEBSOCAT_RELEASE_BASE}/v${version}/websocat.aarch64-unknown-linux-musl" ;;
        *)
            print_error "不支持的架构: $arch，请手动安装 websocat"
            return 1
            ;;
    esac
}

# 下载指定版本到 $1 (目标路径)，下载后校验可执行性与版本号
download_websocat() {
    local bin_path="$1" version="$2"
    local url
    url=$(resolve_websocat_url "$version") || return 1

    mkdir -p "$(dirname "$bin_path")"
    # -f 让 HTTP 错误不被当成成功；避免把 404 页面写入二进制
    if ! curl -fsSL -o "$bin_path" "$url"; then
        print_error "从 $url 下载 websocat 失败"
        rm -f "$bin_path"
        return 1
    fi
    chmod +x "$bin_path"

    local new_ver
    new_ver=$(get_websocat_version "$bin_path")
    if [ -z "$new_ver" ]; then
        print_error "下载的 websocat 二进制文件无法运行"
        rm -f "$bin_path"
        return 1
    fi
    if [ "$new_ver" != "$version" ]; then
        print_warning "下载的 websocat 报告版本 $new_ver，与预期 $version 不一致"
    fi
    print_info "websocat $new_ver 已安装到 $bin_path"
}

# 查找或自动下载 websocat，并对本地缓存做版本检查/更新
setup_websocat() {
    local target_ver="$WEBSOCAT_VERSION"
    local bin_dir="$WORKSPACE_DIR/.bin"
    local bin_path="$bin_dir/websocat"

    # 1) 优先使用系统已安装的 websocat (不强制替换系统二进制)
    if command -v websocat &>/dev/null; then
        local sys_bin sys_ver
        sys_bin=$(command -v websocat)
        sys_ver=$(get_websocat_version "$sys_bin")
        if [ -n "$sys_ver" ] && [ "$sys_ver" != "$target_ver" ]; then
            print_warning "系统 websocat 版本 ${sys_ver} 与脚本固定版本 ${target_ver} 不一致 (仍将使用系统版本)"
        else
            print_info "使用系统 websocat ${sys_ver:-未知版本} ($sys_bin)"
        fi
        WEBSOCAT_BIN="$sys_bin"
        return 0
    fi

    # 2) 检查本地缓存的 .bin/websocat，版本不匹配则重新下载
    if [ -x "$bin_path" ]; then
        local local_ver
        local_ver=$(get_websocat_version "$bin_path")
        if [ "$local_ver" = "$target_ver" ]; then
            print_info "使用本地 websocat $local_ver ($bin_path)"
            WEBSOCAT_BIN="$bin_path"
            return 0
        fi
        print_info "本地 websocat 版本为 ${local_ver:-未知}，与目标版本 $target_ver 不一致，重新下载..."
        rm -f "$bin_path"
    else
        print_info "未找到 websocat，下载固定版本 v$target_ver ..."
    fi

    # 3) 下载固定版本到本地缓存
    download_websocat "$bin_path" "$target_ver" || return 1
    WEBSOCAT_BIN="$bin_path"
}

# ==========================================================
# 特定功能函数: WebSocket JSON-RPC 客户端
# ==========================================================

# 建立 WebSocket 连接（使用 coproc）
ws_connect() {
    local url="$1"
    coproc WS_PROC { "$WEBSOCAT_BIN" -t -k --no-close "$url" 2>/dev/null; }
    sleep 0.5

    if ! kill -0 "${WS_PROC_PID}" 2>/dev/null; then
        print_error "websocat 连接 $url 失败"
        return 1
    fi
}

# shellcheck disable=SC2317
# 关闭 WebSocket 连接
ws_close() {
    if [ -n "${WS_PROC_PID:-}" ] && kill -0 "${WS_PROC_PID}" 2>/dev/null; then
        kill "${WS_PROC_PID}" 2>/dev/null || true
        wait "${WS_PROC_PID}" 2>/dev/null || true
    fi
}

# 发送 JSON-RPC 请求并读取匹配的响应
ws_call() {
    local method="$1"
    local params="${2:-[]}"

    REQUEST_ID=$((REQUEST_ID + 1))
    local payload
    payload=$(jq -cn --arg m "$method" --argjson p "$params" --argjson id "$REQUEST_ID" \
        '{"jsonrpc":"2.0","id":$id,"method":$m,"params":$p}')

    echo "$payload" >&"${WS_PROC[1]}"

    local line resp_id
    while IFS= read -r -t 30 line <&"${WS_PROC[0]}"; do
        [ -z "$line" ] && continue

        resp_id=$(echo "$line" | jq -r '.id // empty' 2>/dev/null) || continue

        if [ "$resp_id" = "$REQUEST_ID" ]; then
            local has_error
            has_error=$(echo "$line" | jq 'has("error")' 2>/dev/null) || has_error="false"

            if [ "$has_error" = "true" ]; then
                local reason
                reason=$(echo "$line" | jq -r '
                    .error |
                    if type == "object" then
                        (.data.reason // .message // tostring)
                    else
                        tostring
                    end' 2>/dev/null)
                print_error "$method 调用失败: $reason"
                return 1
            fi

            echo "$line" | jq -c '.result'
            return 0
        fi
    done

    print_error "等待 $method 响应超时"
    return 1
}

connect_and_authenticate() {
    local url="$1"
    local api_key="$2"
    local attempt auth_result

    for ((attempt = 1; attempt <= AUTH_RETRIES; attempt++)); do
        ws_connect "$url" || {
            if [ "$attempt" -lt "$AUTH_RETRIES" ]; then
                print_warning "连接 TrueNAS WebSocket API 失败，${RETRY_DELAY} 秒后重试 (${attempt}/${AUTH_RETRIES})"
                sleep "$RETRY_DELAY"
            fi
            continue
        }

        auth_result=$(ws_call "auth.login_with_api_key" "[\"$api_key\"]" 2>/dev/null) || auth_result=""
        if [ "$auth_result" = "true" ]; then
            return 0
        fi

        ws_close
        if [ "$attempt" -lt "$AUTH_RETRIES" ]; then
            print_warning "TrueNAS API 密钥认证失败或超时，${RETRY_DELAY} 秒后重试 (${attempt}/${AUTH_RETRIES})"
            sleep "$RETRY_DELAY"
        fi
    done

    print_error "TrueNAS API 密钥认证失败"
    return 1
}

# 等待 TrueNAS 异步任务完成
wait_for_job() {
    local job_id="$1"
    local deadline=$(($(date +%s) + JOB_TIMEOUT))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        local jobs_result
        jobs_result=$(ws_call "core.get_jobs" "[[[\"id\", \"=\", $job_id]]]" 2>/dev/null) || {
            sleep "$POLL_INTERVAL"
            continue
        }

        local state
        state=$(echo "$jobs_result" | jq -r '.[0].state // empty' 2>/dev/null)

        case "$state" in
            SUCCESS)
                echo "$jobs_result" | jq -c '.[0].result'
                return 0
                ;;
            FAILED|ABORTED)
                local error
                error=$(echo "$jobs_result" | jq -r '.[0].error // .[0].exception // "任务失败"' 2>/dev/null)
                print_error "任务 $job_id 以 $state 状态结束: $error"
                return 1
                ;;
        esac

        sleep "$POLL_INTERVAL"
    done

    print_error "等待任务 $job_id 超时"
    return 1
}

# ==========================================================
# 参数解析
# ==========================================================
HOST="$DEFAULT_HOST"
CERT="$DEFAULT_CERT"
KEY="$DEFAULT_KEY"
CERT_NAME=""
API_KEY=""
WS_PATH="$DEFAULT_WS_PATH"
PREFIX="$DEFAULT_PREFIX"
KEEP="$DEFAULT_KEEP"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)      HOST="$2"; shift 2 ;;
        -c|--cert)      CERT="$2"; shift 2 ;;
        -k|--key)       KEY="$2"; shift 2 ;;
        -n|--name)      CERT_NAME="$2"; shift 2 ;;
        -A|--api-key)   API_KEY="$2"; shift 2 ;;
        --ws-path)      WS_PATH="$2"; shift 2 ;;
        --prefix)       PREFIX="$2"; shift 2 ;;
        --keep)         KEEP="$2"; shift 2 ;;
        -h|--help)
            print_usage
            exit $EXIT_SUCCESS
            ;;
        *) print_error "未知选项: $1"; exit $EXIT_INVALID_INPUT ;;
    esac
done

# 如果未指定证书名称则自动生成
if [ -z "$CERT_NAME" ]; then
    SHORT=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 4)
    CERT_NAME="${PREFIX}$(date +%Y%m%d)_${SHORT}"
fi

# ==========================================================
# 输入验证
# ==========================================================
print_info "使用配置: HOST=$HOST, CERT=$CERT, KEY=$KEY, NAME=$CERT_NAME, KEEP=$KEEP"

if [ -z "$HOST" ]; then
    print_error "必须提供主机地址 (--host)"
    exit $EXIT_INVALID_INPUT
fi

if [ "$KEEP" -lt 1 ]; then
    print_error "keep 至少为 1"
    exit $EXIT_INVALID_INPUT
fi

print_info "验证本地证书文件..."
validate_readable_file "$CERT" "证书文件" $EXIT_CERT_NOT_FOUND
validate_readable_file "$KEY" "密钥文件" $EXIT_KEY_NOT_FOUND

CERT_DATA=$(cat "$CERT") || { print_error "无法读取证书文件"; exit $EXIT_RUNTIME_ERROR; }
KEY_DATA=$(cat "$KEY") || { print_error "无法读取密钥文件"; exit $EXIT_RUNTIME_ERROR; }

if [ -z "$API_KEY" ]; then
    API_KEY="${TRUENAS_API_KEY:-}"
fi
if [ -z "$API_KEY" ]; then
    print_error "必须通过 --api-key 或 TRUENAS_API_KEY 环境变量提供 API 密钥"
    exit $EXIT_INVALID_INPUT
fi

# ==========================================================
# 初始化 websocat
# ==========================================================
setup_websocat || exit $EXIT_RUNTIME_ERROR

trap ws_close EXIT

# ==========================================================
# 步骤 1: 连接 TrueNAS WebSocket API 并认证
# ==========================================================
print_info "连接 TrueNAS WebSocket API..."
if ! connect_and_authenticate "wss://${HOST}${WS_PATH}" "$API_KEY"; then
    exit $EXIT_RUNTIME_ERROR
fi

# ==========================================================
# 步骤 2: 获取当前系统配置
# ==========================================================
CONFIG_RESP=$(ws_call "system.general.config") || {
    print_error "无法获取系统通用配置"
    exit $EXIT_RUNTIME_ERROR
}

ACTIVE_CERT_ID=$(echo "$CONFIG_RESP" | jq -r '
    if .ui_certificate | type == "object" then .ui_certificate.id
    elif .ui_certificate | type == "number" then .ui_certificate
    elif .ui_certificate | type == "string" and test("^[0-9]+$") then .ui_certificate | tonumber
    else empty
    end // empty' 2>/dev/null)

# ==========================================================
# 步骤 3: 检查同名证书是否已存在
# ==========================================================
print_info "查询已有证书..."

EXISTING_CERTS=$(ws_call "certificate.query" "[[[\"name\", \"=\", \"$CERT_NAME\"]]]") || EXISTING_CERTS="[]"

EXISTING_COUNT=$(echo "$EXISTING_CERTS" | jq 'length')
if [ "$EXISTING_COUNT" -gt 0 ]; then
    EXISTING_ID=$(echo "$EXISTING_CERTS" | jq -r '.[0].id')

    if [ "$EXISTING_ID" = "$ACTIVE_CERT_ID" ]; then
        print_warning "证书 '$CERT_NAME' 已存在且当前为活跃状态"
        print_error "无法覆盖活跃证书，请使用不同名称或依赖默认唯一命名"
        exit $EXIT_RUNTIME_ERROR
    fi

    print_info "同名证书 '$CERT_NAME' 已存在，删除后替换..."
    DEL_JOB_ID=$(ws_call "certificate.delete" "[$EXISTING_ID, false]") || {
        print_error "删除已有证书失败"
        exit $EXIT_RUNTIME_ERROR
    }
    DEL_JOB_ID=$(echo "$DEL_JOB_ID" | jq -r '. // empty')
    if [ -n "$DEL_JOB_ID" ] && [ "$DEL_JOB_ID" != "null" ]; then
        wait_for_job "$DEL_JOB_ID" > /dev/null || {
            print_error "删除已有证书任务失败"
            exit $EXIT_RUNTIME_ERROR
        }
    fi
fi

# ==========================================================
# 步骤 4: 导入新证书
# ==========================================================
print_info "导入证书 '$CERT_NAME'..."

IMPORT_PAYLOAD=$(jq -n \
    --arg name "$CERT_NAME" \
    --arg cert "$CERT_DATA" \
    --arg key "$KEY_DATA" \
    '[{"name": $name, "create_type": "CERTIFICATE_CREATE_IMPORTED", "certificate": $cert, "privatekey": $key}]')

CREATE_JOB_ID=$(ws_call "certificate.create" "$IMPORT_PAYLOAD") || {
    print_error "创建证书失败"
    exit $EXIT_RUNTIME_ERROR
}

CREATE_JOB_ID=$(echo "$CREATE_JOB_ID" | jq -r '. // empty')
if [ -z "$CREATE_JOB_ID" ] || [ "$CREATE_JOB_ID" = "null" ]; then
    print_error "证书创建响应异常"
    exit $EXIT_RUNTIME_ERROR
fi

CREATE_RESULT=$(wait_for_job "$CREATE_JOB_ID") || {
    print_error "证书创建任务失败"
    exit $EXIT_RUNTIME_ERROR
}

NEW_CERT_ID=$(echo "$CREATE_RESULT" | jq -r '
    if type == "object" then .id
    elif type == "number" then .
    elif type == "string" and test("^[0-9]+$") then . | tonumber
    else empty
    end // empty')

if [ -z "$NEW_CERT_ID" ]; then
    print_error "证书创建任务返回结果异常: $CREATE_RESULT"
    exit $EXIT_RUNTIME_ERROR
fi

print_info "已导入证书，ID: $NEW_CERT_ID"

# ==========================================================
# 步骤 5: 设置系统 UI 证书
# ==========================================================
print_info "设置系统 UI 证书为 $NEW_CERT_ID..."

ws_call "system.general.update" "[{\"ui_certificate\": $NEW_CERT_ID}]" > /dev/null || {
    print_error "更新系统 UI 证书失败"
    exit $EXIT_RUNTIME_ERROR
}

# ==========================================================
# 步骤 6: 清理旧的托管证书
# ==========================================================
print_info "清理旧证书 (保留最新 $KEEP 个)..."

CONFIG_RESP2=$(ws_call "system.general.config" 2>/dev/null) || CONFIG_RESP2=""
if [ -n "$CONFIG_RESP2" ]; then
    ACTIVE_CERT_ID=$(echo "$CONFIG_RESP2" | jq -r '
        if .ui_certificate | type == "object" then .ui_certificate.id
        elif .ui_certificate | type == "number" then .ui_certificate
        else empty
        end // empty' 2>/dev/null)
fi

ALL_CERTS=$(ws_call "certificate.query" "[[], {\"order_by\": [\"-id\"]}]" 2>/dev/null) || ALL_CERTS="[]"

MANAGED_CERTS=$(echo "$ALL_CERTS" | jq --arg pfx "$PREFIX" \
    '[.[] | select((.name // "") | startswith($pfx))]' 2>/dev/null) || MANAGED_CERTS="[]"

MANAGED_COUNT=$(echo "$MANAGED_CERTS" | jq 'length')
IDX=0
while [ "$IDX" -lt "$MANAGED_COUNT" ]; do
    if [ "$IDX" -lt "$KEEP" ]; then
        IDX=$((IDX + 1))
        continue
    fi

    CERT_ID=$(echo "$MANAGED_CERTS" | jq -r ".[$IDX].id")
    CERT_NM=$(echo "$MANAGED_CERTS" | jq -r ".[$IDX].name")

    if [ "$CERT_ID" = "$ACTIVE_CERT_ID" ]; then
        print_warning "跳过删除 $CERT_NM (ID: $CERT_ID)，该证书当前绑定到 UI"
        IDX=$((IDX + 1))
        continue
    fi

    print_info "清理旧证书: $CERT_NM (ID: $CERT_ID)..."
    DEL_JOB=$(ws_call "certificate.delete" "[$CERT_ID, false]" 2>/dev/null) || {
        IDX=$((IDX + 1))
        continue
    }
    DEL_JOB_ID=$(echo "$DEL_JOB" | jq -r '. // empty')
    if [ -n "$DEL_JOB_ID" ] && [ "$DEL_JOB_ID" != "null" ]; then
        wait_for_job "$DEL_JOB_ID" > /dev/null 2>&1 || true
    fi

    IDX=$((IDX + 1))
done

# ==========================================================
# 步骤 7: 重启 UI
# ==========================================================
print_info "重启 UI..."
ws_call "system.general.ui_restart" "[0]" > /dev/null 2>&1 || true

print_success "证书已部署到 $HOST"
exit $EXIT_SUCCESS
