#!/bin/bash
# ==========================================================
# deploy_to_pve.sh: 部署 SSL 证书到 Proxmox VE
#
# 通过 PVE 官方 REST API 上传证书并触发 pveproxy 重载。
#
# 用法:
#   deploy_to_pve.sh -H <host> -n <node> --token-id <id> \
#       --token-secret <secret> -c <cert> -k <key>
# ==========================================================

set -euo pipefail

# ==========================================================
# 常量定义
# ==========================================================
DEFAULT_HOST=""
DEFAULT_NODE="pve"
DEFAULT_TOKEN_ID=""
DEFAULT_TOKEN_SECRET=""
DEFAULT_CERT=""
DEFAULT_KEY=""
REQUEST_TIMEOUT=30

EXIT_SUCCESS=0
EXIT_RUNTIME_ERROR=1
EXIT_CERT_NOT_FOUND=2
EXIT_KEY_NOT_FOUND=3
EXIT_INVALID_INPUT=4

# ==========================================================
# 工具函数
# ==========================================================
print_info()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"; }
# shellcheck disable=SC2317
print_warning() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1"; }
print_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2; }
print_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1"; }

print_usage() {
    print_info "用法: $0 -H <host> -n <node> --token-id <id> --token-secret <secret> -c <cert> -k <key>"
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
# 参数解析
# ==========================================================
HOST="$DEFAULT_HOST"
NODE="$DEFAULT_NODE"
TOKEN_ID="$DEFAULT_TOKEN_ID"
TOKEN_SECRET="$DEFAULT_TOKEN_SECRET"
CERT="$DEFAULT_CERT"
KEY="$DEFAULT_KEY"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)         HOST="$2"; shift 2 ;;
        -n|--node)         NODE="$2"; shift 2 ;;
        --token-id)        TOKEN_ID="$2"; shift 2 ;;
        --token-secret)    TOKEN_SECRET="$2"; shift 2 ;;
        -c|--cert)         CERT="$2"; shift 2 ;;
        -k|--key)          KEY="$2"; shift 2 ;;
        -h|--help)
            print_usage
            exit $EXIT_SUCCESS
            ;;
        *) print_error "未知选项: $1"; exit $EXIT_INVALID_INPUT ;;
    esac
done

# ==========================================================
# 输入验证
# ==========================================================
print_info "使用配置: HOST=$HOST, NODE=$NODE, AUTH=api-token, CERT=$CERT, KEY=$KEY"

if [ -z "$HOST" ]; then
    print_error "必须提供主机地址 (--host)"
    exit $EXIT_INVALID_INPUT
fi

if [ -z "$TOKEN_ID" ] || [ -z "$TOKEN_SECRET" ]; then
    print_error "必须提供 token-id 和 token-secret"
    exit $EXIT_INVALID_INPUT
fi

print_info "验证本地证书文件..."
validate_readable_file "$CERT" "证书文件" $EXIT_CERT_NOT_FOUND
validate_readable_file "$KEY" "密钥文件" $EXIT_KEY_NOT_FOUND

# ==========================================================
# 步骤 1: 读取证书和密钥数据
# ==========================================================
CERT_DATA=$(cat "$CERT") || { print_error "无法读取证书文件: $CERT"; exit $EXIT_RUNTIME_ERROR; }
KEY_DATA=$(cat "$KEY") || { print_error "无法读取密钥文件: $KEY"; exit $EXIT_RUNTIME_ERROR; }

# ==========================================================
# 步骤 2: 通过 PVE REST API 上传证书
# ==========================================================
BASE_URL="https://${HOST}:8006/api2/json"
UPLOAD_URL="${BASE_URL}/nodes/${NODE}/certificates/custom"

print_info "使用 API Token ($TOKEN_ID) 连接 PVE ($HOST)..."
print_info "上传证书到节点 '$NODE' 并应用..."

PVE_TMP=$(mktemp /tmp/pve_response_XXXXXXXX.tmp)

HTTP_CODE=$(curl -s -o "$PVE_TMP" -w "%{http_code}" \
    -k \
    -X POST \
    -H "Authorization: PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}" \
    --data-urlencode "certificates=${CERT_DATA}" \
    --data-urlencode "key=${KEY_DATA}" \
    -d "force=1" \
    -d "restart=1" \
    --max-time "$REQUEST_TIMEOUT" \
    "$UPLOAD_URL" 2>/dev/null) || {
    print_error "证书上传失败: curl 请求出错"
    rm -f "$PVE_TMP"
    exit $EXIT_RUNTIME_ERROR
}

RESPONSE_BODY=$(cat "$PVE_TMP" 2>/dev/null)
rm -f "$PVE_TMP"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    print_error "证书上传失败 (HTTP $HTTP_CODE): $RESPONSE_BODY"
    exit $EXIT_RUNTIME_ERROR
fi

print_info "PVE 正在处理证书并在后台重启 pveproxy..."
print_success "证书已部署到 $HOST"
exit $EXIT_SUCCESS
