#!/bin/bash
# ==========================================================
# deploy_to_truenas.sh: 部署 SSL 证书到 TrueNAS
#
# 通过 WebSocket JSON-RPC 2.0 API（websocat）导入证书、
# 更新 UI 绑定并清理旧证书。
#
# 认证方式:
#   默认     : auth.login_ex + API_KEY_PLAIN（需 -u/--username 指定密钥所属用户，默认 root）
#   --scram  : SCRAM-SHA-512（官方推荐；适配 LEVEL_2/3 安全级别，需 OpenSSL 3.0+）
#
# 需要 TrueNAS 25.10+（更早版本的 auth.login_with_api_key 已废弃）
#
# 用法:
#   deploy_to_truenas.sh -H <host> -A <api_key> [-u <username>] -c <cert> -k <key> [options]
# ==========================================================

set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 引入共享库 (日志、退出码、文件校验等)
# shellcheck source=common.sh
source "$WORKSPACE_DIR/common.sh"

# ==========================================================
# 常量定义
# ==========================================================
JOB_TIMEOUT=120
POLL_INTERVAL=1
AUTH_RETRIES=3
RETRY_DELAY=2
WS_RESPONSE_TIMEOUT=30

# 固定 websocat 版本：本地 .bin/websocat 与此版本不一致时会自动重新下载
# 升级时只需修改此常量
WEBSOCAT_VERSION="1.14.1"
WEBSOCAT_RELEASE_BASE="https://github.com/vi/websocat/releases/download"

WEBSOCAT_BIN=""
REQUEST_ID=0

# ws_call_result 的输出与错误状态 (供认证逻辑判断错误类型)
WS_LAST_RESULT=""
WS_LAST_ERR_MSG=""
WS_LAST_ERR_CODE=""
AUTH_MECHANISM=""

# SCRAM 选项: --scram 启用 SCRAM-SHA-512; SCRAM_UNSUPPORTED 记录服务器不支持以避免重复尝试
USE_SCRAM=0
SCRAM_UNSUPPORTED=0

# ==========================================================
# 工具函数
# ==========================================================
print_usage() {
    print_info "用法: $0 -H <host> -A <api_key> [-u <username>] -c <cert> -k <key> [options]"
    print_info "  -u, --username <user>  API 密钥所属用户名 (默认 root; TrueNAS 25.10+ 必须正确)"
    print_info "  其他选项: --scram, -n <名称>, --ws-path <路径>, --prefix <前缀>, --keep <数量>"
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

    # websocat 若已退出, bash 会清除 WS_PROC_PID, 故用 :- 兜底
    if [ -z "${WS_PROC_PID:-}" ] || ! kill -0 "${WS_PROC_PID}" 2>/dev/null; then
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

# 发送 JSON-RPC 请求并将结果写入全局变量 WS_LAST_RESULT。
# 失败时错误信息写入 WS_LAST_ERR_MSG / WS_LAST_ERR_CODE，供调用方
# 判断错误类型（如服务器不存在该方法）。
# 参数: <method> [params_json] [quiet]  quiet=1 时失败不打印错误
# 返回: 0=成功, 1=失败
ws_call_result() {
    local method="$1"
    local params="${2:-[]}"
    local quiet="${3:-0}"

    WS_LAST_RESULT=""
    WS_LAST_ERR_MSG=""
    WS_LAST_ERR_CODE=""

    # 连接断开 (coproc 变量被清除) 时提前返回, 由调用方重试
    if [ -z "${WS_PROC_PID:-}" ]; then
        WS_LAST_ERR_MSG="WebSocket 连接已断开"
        if [ "$quiet" != "1" ]; then
            print_error "$WS_LAST_ERR_MSG"
        fi
        return 1
    fi

    REQUEST_ID=$((REQUEST_ID + 1))
    local payload
    payload=$(jq -cn --arg m "$method" --argjson p "$params" --argjson id "$REQUEST_ID" \
        '{"jsonrpc":"2.0","id":$id,"method":$m,"params":$p}')

    echo "$payload" >&"${WS_PROC[1]}"

    local line resp_id
    while IFS= read -r -t "$WS_RESPONSE_TIMEOUT" line <&"${WS_PROC[0]}"; do
        [ -z "$line" ] && continue

        resp_id=$(echo "$line" | jq -r '.id // empty' 2>/dev/null) || continue

        if [ "$resp_id" = "$REQUEST_ID" ]; then
            local has_error
            has_error=$(echo "$line" | jq 'has("error")' 2>/dev/null) || has_error="false"

            if [ "$has_error" = "true" ]; then
                WS_LAST_ERR_MSG=$(echo "$line" | jq -r '
                    .error |
                    if type == "object" then
                        (.data.reason // .message // tostring)
                    else
                        tostring
                    end' 2>/dev/null)
                WS_LAST_ERR_CODE=$(echo "$line" | jq -r '.error.code // empty' 2>/dev/null)
                if [ "$quiet" != "1" ]; then
                    print_error "$method 调用失败: $WS_LAST_ERR_MSG"
                fi
                return 1
            fi

            WS_LAST_RESULT=$(echo "$line" | jq -c '.result')
            return 0
        fi
    done

    WS_LAST_ERR_MSG="等待 $method 响应超时"
    if [ "$quiet" != "1" ]; then
        print_error "$WS_LAST_ERR_MSG"
    fi
    return 1
}

# ws_call: 成功时将结果输出到 stdout（供 $(ws_call ...) 使用）
ws_call() {
    ws_call_result "$@" || return $?
    echo "$WS_LAST_RESULT"
}

# 判断最近一次 ws_call_result 失败是否因为服务器不存在该方法 (JSON-RPC -32601)
is_method_missing_error() {
    case "${WS_LAST_ERR_CODE:-}" in
        -32601) return 0 ;;
    esac

    local msg
    msg=$(printf '%s' "${WS_LAST_ERR_MSG:-}" | tr '[:upper:]' '[:lower:]')
    case "$msg" in
        *"does not exist"*|*"not found"*|*"no such method"*|*"unknown method"*) return 0 ;;
    esac
    return 1
}

# 尝试新版认证接口 auth.login_ex + API_KEY_PLAIN (TrueNAS 25.10+)
#
# 请求:  params: [{"mechanism":"API_KEY_PLAIN","username":<user>,"api_key":<key>}]
# 响应:  result: {"response_type":"SUCCESS"|"AUTH_ERR"|"DENIED"|"EXPIRED"|"REDIRECT"|...}
#
# 返回: 0=成功; 2=服务器不支持该接口(版本过低); 3=认证被明确拒绝; 1=其他失败
try_login_ex() {
    local username="$1"
    local api_key="$2"
    local params rtype

    # 用 jq 构建参数，避免特殊字符破坏 JSON
    params=$(jq -cn --arg u "$username" --arg k "$api_key" \
        '[{"mechanism": "API_KEY_PLAIN", "username": $u, "api_key": $k}]')

    if ! ws_call_result "auth.login_ex" "$params" 1; then
        if is_method_missing_error; then
            return 2
        fi
        print_error "auth.login_ex 调用失败: ${WS_LAST_ERR_MSG:-响应超时}"
        return 1
    fi

    rtype=$(printf '%s' "$WS_LAST_RESULT" | jq -r '.response_type // empty' 2>/dev/null)
    if [ "$rtype" = "SUCCESS" ]; then
        return 0
    fi

    case "$rtype" in
        AUTH_ERR)     print_error "auth.login_ex 认证被拒: API 密钥无效，或用户名与密钥所属用户不一致" ;;
        DENIED)       print_error "auth.login_ex 认证被拒: 用户 '$username' 没有 API 访问权限" ;;
        EXPIRED)      print_error "auth.login_ex 认证被拒: API 密钥已过期或已被吊销" ;;
        REDIRECT)     print_error "auth.login_ex 认证被拒: 当前节点为 HA 备机，请在主控节点执行部署" ;;
        OTP_REQUIRED) print_error "auth.login_ex 意外要求二次验证 (OTP_REQUIRED)" ;;
        *)            print_error "auth.login_ex 认证失败: response_type=${rtype:-<empty>}" ;;
    esac
    return 3
}

# ==========================================================
# 特定功能函数: SCRAM-SHA-512 认证 (--scram)
# 协议参考: TrueNAS 官方文档 docs/source/accounts/scram_authentication.rst
# 使用原始 API 密钥现场计算 (PBKDF2 一次原生调用), 无需预计算 SCRAM 数据
# ==========================================================

# OpenSSL 是否支持 kdf 子命令 (PBKDF2; 需要 OpenSSL 3.0+)
openssl_supports_kdf() {
    openssl kdf -keylen 16 -kdfopt digest:SHA256 -kdfopt hexpass:78 -kdfopt hexsalt:79 \
        -kdfopt iter:1 PBKDF2 >/dev/null 2>&1
}

# 将 hex 字符串转换为 printf %b 转义序列 (二进制经管道处理，不进入变量)
hex_escape() {
    local hex="$1" esc="" i
    for (( i = 0; i < ${#hex}; i += 2 )); do
        esc+="\\x${hex:i:2}"
    done
    printf '%s' "$esc"
}

# SHA512(hex 表示的二进制数据) -> 小写 hex
sha512_hex_of_hex() {
    local esc
    esc=$(hex_escape "$1")
    printf '%b' "$esc" | openssl dgst -sha512 -binary | od -An -tx1 | tr -d ' \n' | tr 'A-F' 'a-f'
}

# HMAC-SHA512(key_hex, 字符串) -> 小写 hex
hmac_sha512_hex() {
    local key_hex="$1" data="$2"
    printf '%s' "$data" | openssl dgst -sha512 -mac HMAC -macopt "hexkey:${key_hex}" -binary \
        | od -An -tx1 | tr -d ' \n' | tr 'A-F' 'a-f'
}

# PBKDF2-HMAC-SHA512(key_hex, salt_hex, iterations) -> 小写 hex
pbkdf2_sha512_hex() {
    local key_hex="$1" salt_hex="$2" iter="$3"
    openssl kdf -keylen 64 -kdfopt digest:SHA512 -kdfopt "hexpass:${key_hex}" \
        -kdfopt "hexsalt:${salt_hex}" -kdfopt "iter:${iter}" PBKDF2 2>/dev/null \
        | tr -d ':\n ' | tr 'A-F' 'a-f'
}

# 两个等长 hex 字符串逐字节异或 -> hex
hex_xor() {
    local a="$1" b="$2" out="" i ba bb
    [ "${#a}" -eq "${#b}" ] || return 1
    for (( i = 0; i < ${#a}; i += 2 )); do
        ba=$((16#${a:i:2}))
        bb=$((16#${b:i:2}))
        printf -v out '%s%02x' "$out" "$(( ba ^ bb ))"
    done
    printf '%s' "$out"
}

# hex -> base64 (二进制经 printf %b 管道输出)
hex_to_base64() {
    local esc
    esc=$(hex_escape "$1")
    printf '%b' "$esc" | openssl base64 -A
}

# base64 -> 小写 hex
base64_to_hex() {
    printf '%s' "$1" | openssl base64 -d -A 2>/dev/null | od -An -tx1 | tr -d ' \n' | tr 'A-F' 'a-f'
}

# 尝试 SCRAM-SHA-512 认证
#
# 返回: 0=成功; 2=服务器不支持 SCRAM; 3=认证被拒; 4=服务器签名校验失败(安全错误); 1=其他失败
try_login_scram() {
    local username="$1" api_key="$2"
    local key_id raw_key client_nonce client_first_bare client_first
    local params rtype stype rfc
    local server_nonce salt_b64 iterations parts part
    local raw_key_hex salt_hex salted_hex client_key_hex stored_key_hex
    local auth_message client_sig_hex proof_hex proof_b64
    local server_sig_b64 server_sig_hex server_key_hex expected_sig_hex

    # API 密钥格式: <数字id>-<密钥>
    key_id="${api_key%%-*}"
    raw_key="${api_key#*-}"
    if ! [[ "$key_id" =~ ^[0-9]+$ ]] || [ -z "$raw_key" ] || [ "$raw_key" = "$api_key" ]; then
        print_error "SCRAM: API 密钥格式异常 (应为 <数字id>-<密钥>)"
        return 1
    fi

    # 客户端 nonce (32 字节随机, hex 编码; 必须用 head 限制字节数, od 直接读 /dev/urandom 不会 EOF)
    client_nonce=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    client_first_bare="n=${username}:${key_id},r=${client_nonce}"
    client_first="n,,${client_first_bare}"

    # 第 1 步: CLIENT_FIRST_MESSAGE
    params=$(jq -cn --arg s "$client_first" \
        '[{"mechanism": "SCRAM", "scram_type": "CLIENT_FIRST_MESSAGE", "rfc_str": $s}]')
    if ! ws_call_result "auth.login_ex" "$params" 1; then
        if is_method_missing_error; then
            return 2
        fi
        print_error "SCRAM CLIENT_FIRST 调用失败: ${WS_LAST_ERR_MSG:-响应超时}"
        return 1
    fi

    rtype=$(printf '%s' "$WS_LAST_RESULT" | jq -r '.response_type // empty' 2>/dev/null)
    stype=$(printf '%s' "$WS_LAST_RESULT" | jq -r '.scram_type // empty' 2>/dev/null)
    rfc=$(printf '%s' "$WS_LAST_RESULT" | jq -r '.rfc_str // empty' 2>/dev/null)

    if [ "$rtype" = "AUTH_ERR" ] || [ "$rtype" = "DENIED" ] || [ "$rtype" = "EXPIRED" ]; then
        print_error "SCRAM 认证被拒: API 密钥无效、已被吊销或用户无权限"
        return 3
    fi
    if [ "$rtype" != "SCRAM_RESPONSE" ] || [ "$stype" != "SERVER_FIRST_RESPONSE" ] || [ -z "$rfc" ]; then
        print_error "SCRAM 协议响应异常: response_type=${rtype:-<empty>}, scram_type=${stype:-<empty>}"
        return 1
    fi

    # 解析 SERVER_FIRST: r=...,s=...,i=...
    server_nonce=""; salt_b64=""; iterations=""
    IFS=',' read -r -a parts <<< "$rfc"
    for part in "${parts[@]}"; do
        case "$part" in
            r=*) server_nonce="${part#r=}" ;;
            s=*) salt_b64="${part#s=}" ;;
            i=*) iterations="${part#i=}" ;;
        esac
    done

    if [ -z "$server_nonce" ] || [ -z "$salt_b64" ] || [ -z "$iterations" ]; then
        print_error "SCRAM: SERVER_FIRST 解析失败: $rfc"
        return 1
    fi
    if [[ "$server_nonce" != "$client_nonce"* ]]; then
        print_error "SCRAM: 服务器 nonce 未以客户端 nonce 开头，协议校验失败"
        return 1
    fi
    if ! [[ "$iterations" =~ ^[0-9]+$ ]] || [ "$iterations" -lt 50000 ] || [ "$iterations" -gt 5000000 ]; then
        print_error "SCRAM: 迭代次数超出合理范围 ($iterations)"
        return 1
    fi

    # 计算密钥材料
    raw_key_hex=$(printf '%s' "$raw_key" | od -An -tx1 | tr -d ' \n' | tr 'A-F' 'a-f')
    salt_hex=$(base64_to_hex "$salt_b64")
    if [ -z "$salt_hex" ]; then
        print_error "SCRAM: salt 解析失败"
        return 1
    fi
    salted_hex=$(pbkdf2_sha512_hex "$raw_key_hex" "$salt_hex" "$iterations")
    if [ "${#salted_hex}" -ne 128 ]; then
        print_error "SCRAM: PBKDF2 计算失败 (请确认 OpenSSL 3.0+)"
        return 1
    fi
    client_key_hex=$(hmac_sha512_hex "$salted_hex" "Client Key")
    stored_key_hex=$(sha512_hex_of_hex "$client_key_hex")
    auth_message="${client_first_bare},${rfc},c=biws,r=${server_nonce}"
    client_sig_hex=$(hmac_sha512_hex "$stored_key_hex" "$auth_message")
    if ! proof_hex=$(hex_xor "$client_key_hex" "$client_sig_hex"); then
        print_error "SCRAM: 客户端证明计算失败"
        return 1
    fi
    proof_b64=$(hex_to_base64 "$proof_hex")
    if [ -z "$proof_b64" ]; then
        print_error "SCRAM: 客户端证明编码失败"
        return 1
    fi

    # 第 2 步: CLIENT_FINAL_MESSAGE
    params=$(jq -cn --arg s "c=biws,r=${server_nonce},p=${proof_b64}" \
        '[{"mechanism": "SCRAM", "scram_type": "CLIENT_FINAL_MESSAGE", "rfc_str": $s}]')
    if ! ws_call_result "auth.login_ex" "$params" 1; then
        print_error "SCRAM CLIENT_FINAL 调用失败: ${WS_LAST_ERR_MSG:-响应超时}"
        return 1
    fi

    rtype=$(printf '%s' "$WS_LAST_RESULT" | jq -r '.response_type // empty' 2>/dev/null)
    stype=$(printf '%s' "$WS_LAST_RESULT" | jq -r '.scram_type // empty' 2>/dev/null)
    rfc=$(printf '%s' "$WS_LAST_RESULT" | jq -r '.rfc_str // empty' 2>/dev/null)

    if [ "$rtype" = "AUTH_ERR" ] || [ "$rtype" = "DENIED" ] || [ "$rtype" = "EXPIRED" ]; then
        print_error "SCRAM 认证被拒: API 密钥无效、已被吊销或用户无权限"
        return 3
    fi
    if [ "$rtype" != "SCRAM_RESPONSE" ] || [ "$stype" != "SERVER_FINAL_RESPONSE" ] || [ -z "$rfc" ]; then
        print_error "SCRAM 协议响应异常: response_type=${rtype:-<empty>}, scram_type=${stype:-<empty>}"
        return 1
    fi

    # 第 3 步: 校验服务器签名 (防中间人)
    if [ "${rfc#v=}" = "$rfc" ] || [ -z "${rfc#v=}" ]; then
        print_error "SCRAM: SERVER_FINAL 格式异常: $rfc"
        return 1
    fi
    server_sig_b64="${rfc#v=}"
    server_sig_hex=$(base64_to_hex "$server_sig_b64")
    server_key_hex=$(hmac_sha512_hex "$salted_hex" "Server Key")
    expected_sig_hex=$(hmac_sha512_hex "$server_key_hex" "$auth_message")
    if [ -z "$server_sig_hex" ] || [ "$server_sig_hex" != "$expected_sig_hex" ]; then
        print_error "SCRAM: 服务器签名校验失败，可能存在中间人攻击，已中止认证"
        return 4
    fi

    return 0
}

connect_and_authenticate() {
    local url="$1"
    local api_key="$2"
    local username="$3"
    local attempt rc rcS

    for ((attempt = 1; attempt <= AUTH_RETRIES; attempt++)); do
        ws_connect "$url" || {
            if [ "$attempt" -lt "$AUTH_RETRIES" ]; then
                print_warning "连接 TrueNAS WebSocket API 失败，${RETRY_DELAY} 秒后重试 (${attempt}/${AUTH_RETRIES})"
                sleep "$RETRY_DELAY"
            fi
            continue
        }

        # 0) 可选: 先尝试 SCRAM-SHA-512 (--scram; 适配高安全级别并防重放)
        if [ "$USE_SCRAM" -eq 1 ] && [ "$SCRAM_UNSUPPORTED" -eq 0 ]; then
            rcS=0
            try_login_scram "$username" "$api_key" || rcS=$?
            case "$rcS" in
                0)
                    AUTH_MECHANISM="auth.login_ex (SCRAM-SHA-512)"
                    return 0
                    ;;
                4)
                    # 服务器签名校验失败属安全错误: 中止认证, 不重试
                    return 1
                    ;;
                2)
                    SCRAM_UNSUPPORTED=1
                    print_warning "服务器不支持 SCRAM，回退到 API 密钥 (PLAIN) 认证"
                    ;;
                3)
                    print_warning "SCRAM 认证被拒，回退到 API 密钥 (PLAIN) 认证"
                    ;;
                *)
                    print_warning "SCRAM 认证未完成，回退到 API 密钥 (PLAIN) 认证"
                    ;;
            esac
        fi

        # 1) auth.login_ex + API_KEY_PLAIN (TrueNAS 25.10+)
        rc=0
        try_login_ex "$username" "$api_key" || rc=$?
        if [ "$rc" -eq 0 ]; then
            AUTH_MECHANISM="auth.login_ex (API_KEY_PLAIN)"
            return 0
        fi
        if [ "$rc" -eq 2 ]; then
            print_error "服务器不支持 auth.login_ex，需要 TrueNAS 25.10+"
        fi

        ws_close

        # 方法缺失或认证被拒绝: 重试无意义; 其他失败(如超时)继续重试
        if [ "$rc" -ne 1 ]; then
            break
        fi
        if [ "$attempt" -lt "$AUTH_RETRIES" ]; then
            print_warning "TrueNAS API 密钥认证失败，${RETRY_DELAY} 秒后重试 (${attempt}/${AUTH_RETRIES})"
            sleep "$RETRY_DELAY"
        fi
    done

    print_error "TrueNAS API 密钥认证失败"
    print_error "提示: 请确保 --username/truenas.username 为 API 密钥所属用户，且密钥未过期"
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

# 从 system.general.config 响应中提取当前 UI 证书 ID
# ui_certificate 字段可能为对象/数字/数字字符串
parse_ui_cert_id() {
    jq -r '
        .ui_certificate |
        if type == "object" then .id
        elif type == "number" then .
        elif type == "string" and test("^[0-9]+$") then tonumber
        else empty
        end // empty' 2>/dev/null
}

# ==========================================================
# 参数解析
# ==========================================================
# 默认值 (前缀 truenas_certs_, 保留 2 份, WS 路径 /api/current)
HOST=""
CERT=""
KEY=""
CERT_NAME=""
API_KEY=""
USERNAME=""
WS_PATH="/api/current"
PREFIX="truenas_certs_"
KEEP=2

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)      HOST="$2"; shift 2 ;;
        -c|--cert)      CERT="$2"; shift 2 ;;
        -k|--key)       KEY="$2"; shift 2 ;;
        -n|--name)      CERT_NAME="$2"; shift 2 ;;
        -A|--api-key)   API_KEY="$2"; shift 2 ;;
        -u|--username)  USERNAME="$2"; shift 2 ;;
        --scram)        USE_SCRAM=1; shift ;;
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

# 用户名取值: CLI > TRUENAS_USERNAME 环境变量 > 默认 root
if [ -z "$USERNAME" ]; then
    USERNAME="${TRUENAS_USERNAME:-root}"
fi

# 如果未指定证书名称则自动生成
if [ -z "$CERT_NAME" ]; then
    CERT_NAME="${PREFIX}$(date +%Y%m%d)_$(gen_random_suffix 4)"
fi

# ==========================================================
# 输入验证
# ==========================================================
AUTH_MODE_DISPLAY="PLAIN (API 密钥)"
if [ "$USE_SCRAM" -eq 1 ]; then
    AUTH_MODE_DISPLAY="SCRAM-SHA-512 (不支持时回退 PLAIN)"
fi
print_info "使用配置: HOST=$HOST, CERT=$CERT, KEY=$KEY, NAME=$CERT_NAME, USER=$USERNAME, AUTH=$AUTH_MODE_DISPLAY, KEEP=$KEEP"

if [ -z "$HOST" ]; then
    print_error "必须提供主机地址 (--host)"
    exit $EXIT_INVALID_INPUT
fi

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then
    print_error "keep 必须为不小于 1 的整数"
    exit $EXIT_INVALID_INPUT
fi

load_cert_key "$CERT" "$KEY"

if [ -z "$API_KEY" ]; then
    API_KEY="${TRUENAS_API_KEY:-}"
fi
if [ -z "$API_KEY" ]; then
    print_error "必须通过 --api-key 或 TRUENAS_API_KEY 环境变量提供 API 密钥"
    exit $EXIT_INVALID_INPUT
fi

# --scram 需要 OpenSSL 3.0+ (kdf 子命令 / PBKDF2)
if [ "$USE_SCRAM" -eq 1 ] && ! openssl_supports_kdf; then
    print_error "启用 --scram 需要 OpenSSL 3.0+ (kdf 子命令支持)，当前 OpenSSL 不可用或版本过低"
    exit $EXIT_RUNTIME_ERROR
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
if ! connect_and_authenticate "wss://${HOST}${WS_PATH}" "$API_KEY" "$USERNAME"; then
    exit $EXIT_RUNTIME_ERROR
fi
print_info "认证成功: $AUTH_MECHANISM"

# ==========================================================
# 步骤 2: 获取当前系统配置
# ==========================================================
CONFIG_RESP=$(ws_call "system.general.config") || {
    print_error "无法获取系统通用配置"
    exit $EXIT_RUNTIME_ERROR
}

ACTIVE_CERT_ID=$(echo "$CONFIG_RESP" | parse_ui_cert_id)

# ==========================================================
# 步骤 3: 检查同名证书是否已存在
# ==========================================================
print_info "查询已有证书..."

# 用 jq 构建查询条件，避免证书名称中的特殊字符破坏 JSON
NAME_FILTER=$(jq -cn --arg n "$CERT_NAME" '[[["name", "=", $n]]]')
EXISTING_CERTS=$(ws_call "certificate.query" "$NAME_FILTER") || EXISTING_CERTS="[]"

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
    if [[ "$DEL_JOB_ID" =~ ^[0-9]+$ ]]; then
        wait_for_job "$DEL_JOB_ID" > /dev/null || {
            print_error "删除已有证书任务失败"
            exit $EXIT_RUNTIME_ERROR
        }
    elif [ -n "$DEL_JOB_ID" ] && [ "$DEL_JOB_ID" != "null" ]; then
        print_warning "删除响应非任务 ID (${DEL_JOB_ID})，跳过等待"
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
if ! [[ "$CREATE_JOB_ID" =~ ^[0-9]+$ ]]; then
    print_error "证书创建响应异常: ${CREATE_JOB_ID:-<empty>}"
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
    ACTIVE_CERT_ID=$(echo "$CONFIG_RESP2" | parse_ui_cert_id)
fi

ALL_CERTS=$(ws_call "certificate.query" "[[], {\"order_by\": [\"-id\"]}]" 2>/dev/null) || ALL_CERTS="[]"

# 筛选托管证书中超出 KEEP 数量的部分，输出 "id<TAB>name" 列表
PRUNE_LIST=$(echo "$ALL_CERTS" | jq -r --arg pfx "$PREFIX" --argjson keep "$KEEP" \
    '[.[] | select((.name // "") | startswith($pfx))] | .[$keep:][] | "\(.id)\t\(.name)"' 2>/dev/null) || PRUNE_LIST=""

while IFS=$'\t' read -r CERT_ID CERT_NM; do
    [ -z "$CERT_ID" ] && continue

    if [ "$CERT_ID" = "$ACTIVE_CERT_ID" ]; then
        print_warning "跳过删除 $CERT_NM (ID: $CERT_ID)，该证书当前绑定到 UI"
        continue
    fi

    print_info "清理旧证书: $CERT_NM (ID: $CERT_ID)..."
    DEL_JOB=$(ws_call "certificate.delete" "[$CERT_ID, false]" 2>/dev/null) || continue
    DEL_JOB_ID=$(echo "$DEL_JOB" | jq -r '. // empty')
    if [[ "$DEL_JOB_ID" =~ ^[0-9]+$ ]]; then
        wait_for_job "$DEL_JOB_ID" > /dev/null 2>&1 || true
    fi
done <<< "$PRUNE_LIST"

# ==========================================================
# 步骤 7: 重启 UI
# ==========================================================
print_info "重启 UI..."
if ! ws_call "system.general.ui_restart" "[0]" > /dev/null 2>&1; then
    print_warning "UI 重启调用失败，新证书可能尚未生效 (部署后验证将确认实际生效情况)"
fi

print_success "证书已部署到 $HOST"
exit $EXIT_SUCCESS
