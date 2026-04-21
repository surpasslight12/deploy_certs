#!/bin/bash
# ==========================================================
# deploy_to_opnsense.sh: 部署 SSL 证书到 OPNsense
#
# 采用 "官方 Trust API + SSH 绑定" 的混合实现：
#   - 通过官方 Trust API 导入/查询/删除证书并触发 reconfigure
#   - 通过 SSH 上传 PHP 脚本更新 WebGUI ssl-certref 绑定并重载
#
# 用法:
#   deploy_to_opnsense.sh -H <host> -u <user> -P <password> \
#       -c <cert> -k <key> --api-key <key> --api-secret <secret> [options]
# ==========================================================

set -euo pipefail

# ==========================================================
# 常量定义
# ==========================================================
DEFAULT_HOST=""
DEFAULT_PORT=22
DEFAULT_USER=""
DEFAULT_PASSWORD=""
DEFAULT_API_KEY=""
DEFAULT_API_SECRET=""
DEFAULT_API_PORT=443
DEFAULT_CERT=""
DEFAULT_KEY=""
DEFAULT_REMOTE_DIR="/tmp"
DEFAULT_PREFIX="opnsense_certs_"
DEFAULT_KEEP=2
API_TIMEOUT=20
SSH_TIMEOUT=15

EXIT_SUCCESS=0
EXIT_RUNTIME_ERROR=1
EXIT_CERT_NOT_FOUND=2
EXIT_KEY_NOT_FOUND=3
EXIT_INVALID_INPUT=4

# ==========================================================
# 工具函数
# ==========================================================
print_info()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"; }
print_warning() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1"; }
print_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2; }
print_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1"; }

print_usage() {
    print_info "用法: $0 -H <host> -u <user> -P <password> --api-key <key> --api-secret <secret> -c <cert> -k <key>"
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
# 特定功能函数
# ==========================================================

# 规范化前缀：去除末尾下划线
normalize_prefix() {
    local p="$1"
    echo "${p%%_}"
}

# 生成证书描述名: prefix_YYYYMMDD_XXXX
generate_cert_descr() {
    local prefix="$1"
    local norm
    norm=$(normalize_prefix "$prefix")
    local date_str
    date_str=$(date +%Y%m%d)
    local short
    short=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 4)
    if [ -n "$norm" ]; then
        echo "${norm}_${date_str}_${short}"
    else
        echo "${date_str}_${short}"
    fi
}

# OPNsense Trust API 请求辅助函数
# 用法: api_request <method> <path> [json_payload]
api_request() {
    local method="$1"
    local path="$2"
    local json_payload="${3:-}"
    local url="${API_BASE_URL}${path}"
    local curl_args=(-s -k --max-time "$API_TIMEOUT" -X "$method"
        -u "${API_KEY}:${API_SECRET}"
        -H "Accept: application/json")

    if [ -n "$json_payload" ]; then
        curl_args+=(-H "Content-Type: application/json" -d "$json_payload")
    fi

    local response http_code
    response=$(curl "${curl_args[@]}" -w "\n%{http_code}" "$url" 2>/dev/null) || {
        print_error "curl 请求失败: $method $path"
        return 1
    }

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        print_error "HTTP $http_code: $body"
        return 1
    fi

    echo "$body"
}

# 通过 SSH 在远程 OPNsense 上执行命令
ssh_exec() {
    local cmd="$1"
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_TIMEOUT" \
        -p "$PORT" "${USER}@${HOST}" "$cmd" 2>&1
}

# 通过 SCP 上传本地文件到远程
scp_upload() {
    local local_path="$1" remote_path="$2"
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_TIMEOUT" \
        -P "$PORT" "$local_path" "${USER}@${HOST}:${remote_path}" 2>&1
}

# ==========================================================
# 参数解析
# ==========================================================
HOST="$DEFAULT_HOST"
PORT="$DEFAULT_PORT"
USER="$DEFAULT_USER"
PASSWORD="$DEFAULT_PASSWORD"
API_KEY="$DEFAULT_API_KEY"
API_SECRET="$DEFAULT_API_SECRET"
API_PORT="$DEFAULT_API_PORT"
CERT="$DEFAULT_CERT"
KEY="$DEFAULT_KEY"
REMOTE_DIR="$DEFAULT_REMOTE_DIR"
PREFIX="$DEFAULT_PREFIX"
KEEP="$DEFAULT_KEEP"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)        HOST="$2"; shift 2 ;;
        -p|--port)        PORT="$2"; shift 2 ;;
        -u|--user)        USER="$2"; shift 2 ;;
        -P|--password)    PASSWORD="$2"; shift 2 ;;
        --api-key)        API_KEY="$2"; shift 2 ;;
        --api-secret)     API_SECRET="$2"; shift 2 ;;
        --api-port)       API_PORT="$2"; shift 2 ;;
        -c|--cert)        CERT="$2"; shift 2 ;;
        -k|--key)         KEY="$2"; shift 2 ;;
        -d|--remote-dir)  REMOTE_DIR="$2"; shift 2 ;;
        --prefix)         PREFIX="$2"; shift 2 ;;
        --keep)           KEEP="$2"; shift 2 ;;
        -h|--help)
            print_usage
            exit $EXIT_SUCCESS
            ;;
        *) print_error "未知选项: $1"; exit $EXIT_INVALID_INPUT ;;
    esac
done

API_BASE_URL="https://${HOST}:${API_PORT}/api"

# ==========================================================
# 输入验证
# ==========================================================
print_info "使用配置: HOST=$HOST, USER=$USER, API=已启用, CERT=$CERT, KEY=$KEY"

if [ -z "$HOST" ] || [ -z "$USER" ] || [ -z "$PASSWORD" ]; then
    print_error "必须提供 host、user 和 password"
    exit $EXIT_INVALID_INPUT
fi

if [ -z "$API_KEY" ] || [ -z "$API_SECRET" ]; then
    print_error "必须提供 api-key 和 api-secret"
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

# ==========================================================
# WebGUI ssl-certref 绑定 PHP 脚本
# ==========================================================
read -r -d '' PHP_BINDER << 'PHPEOF' || true
<?php
if ($argc < 2) { echo "Usage: php bind.php <refid>\n"; exit(2); }
$refid = $argv[1];

$conf = '/conf/config.xml';
if (!file_exists($conf) || !is_writable($conf)) {
    echo "Error: /conf/config.xml not writable or missing\n";
    exit(5);
}

libxml_use_internal_errors(true);
$dom = new DOMDocument('1.0', 'UTF-8');
$dom->preserveWhiteSpace = false;
$dom->formatOutput = true;

if ($dom->loadXML(file_get_contents($conf)) === false) {
    echo "Error: Failed to parse /conf/config.xml\n";
    exit(4);
}

$systems = $dom->getElementsByTagName('system');
if ($systems->length === 0) {
    echo "Error: Missing <system> node in /conf/config.xml\n";
    exit(3);
}

$system = $systems->item(0);
$webgui = null;
foreach ($system->childNodes as $child) {
    if ($child->nodeType === XML_ELEMENT_NODE && $child->nodeName === 'webgui') {
        $webgui = $child;
        break;
    }
}
if ($webgui === null) {
    $webgui = $dom->createElement('webgui');
    $system->appendChild($webgui);
}

$sslref = null;
foreach ($webgui->childNodes as $child) {
    if ($child->nodeType === XML_ELEMENT_NODE && $child->nodeName === 'ssl-certref') {
        $sslref = $child;
        break;
    }
}
if ($sslref === null) {
    $sslref = $dom->createElement('ssl-certref');
    $webgui->appendChild($sslref);
}

while ($sslref->hasChildNodes()) { $sslref->removeChild($sslref->firstChild); }
$sslref->appendChild($dom->createTextNode($refid));

if ($dom->save($conf) === false) {
    echo "Error: Failed to write updated config.xml\n";
    exit(3);
}

echo "Successfully updated WebGUI ssl-certref in /conf/config.xml\n";
@exec('/usr/local/sbin/configctl webgui restart 2>&1', $rout, $rrc);
echo implode("\n", $rout) . "\n";
echo "SUCCESS: WebGUI certificate binding updated and reloaded.\n";
exit(0);
?>
PHPEOF

# ==========================================================
# 步骤 1: 通过 Trust API 导入证书
# ==========================================================
print_info "通过 OPNsense Trust API 导入证书..."

DESCRIPTION=$(generate_cert_descr "$PREFIX")

IMPORT_PAYLOAD=$(jq -n \
    --arg descr "$DESCRIPTION" \
    --arg crt "$CERT_DATA" \
    --arg prv "$KEY_DATA" \
    '{"cert": {"action": "import", "descr": $descr, "crt_payload": $crt, "prv_payload": $prv}}')

IMPORT_RESULT=$(api_request POST "/trust/cert/add" "$IMPORT_PAYLOAD") || {
    print_error "证书导入 API 调用失败"
    exit $EXIT_RUNTIME_ERROR
}

IMPORT_STATUS=$(echo "$IMPORT_RESULT" | jq -r '.result // empty')
if [ "$IMPORT_STATUS" != "saved" ]; then
    print_error "证书导入失败: $IMPORT_RESULT"
    exit $EXIT_RUNTIME_ERROR
fi

CERT_UUID=$(echo "$IMPORT_RESULT" | jq -r '.uuid // empty')
if [ -z "$CERT_UUID" ]; then
    print_error "证书导入未返回 uuid: $IMPORT_RESULT"
    exit $EXIT_RUNTIME_ERROR
fi

# 获取导入证书的 refid
CERT_INFO=$(api_request GET "/trust/cert/get/${CERT_UUID}") || {
    print_error "无法获取已导入证书信息"
    exit $EXIT_RUNTIME_ERROR
}

CERT_REFID=$(echo "$CERT_INFO" | jq -r '.cert.refid // empty')
if [ -z "$CERT_REFID" ]; then
    print_error "已导入证书缺少 refid: $CERT_INFO"
    exit $EXIT_RUNTIME_ERROR
fi

print_info "已导入证书: descr=$DESCRIPTION, uuid=$CERT_UUID, refid=$CERT_REFID"

# ==========================================================
# 步骤 2: 重新配置信任存储
# ==========================================================
print_info "通过 OPNsense API 重新配置信任存储..."

RECONF_RESULT=$(api_request POST "/trust/settings/reconfigure" "{}") || {
    print_error "Trust reconfigure API 调用失败"
    exit $EXIT_RUNTIME_ERROR
}

RECONF_STATUS=$(echo "$RECONF_RESULT" | jq -r '.status // empty')
if [ "$RECONF_STATUS" != "ok" ]; then
    print_error "信任存储重新配置失败: $RECONF_RESULT"
    exit $EXIT_RUNTIME_ERROR
fi

# ==========================================================
# 步骤 3: 通过 SSH 绑定证书到 WebGUI
# ==========================================================
print_info "通过 SSH 连接 OPNsense ($HOST)，用户: $USER..."
print_info "将导入的证书绑定到 WebGUI..."

# 上传 PHP 脚本、执行、清理
TMP_PHP=$(mktemp /tmp/opns_bind_XXXXXXXX.php)
echo "$PHP_BINDER" > "$TMP_PHP"

RID=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
REMOTE_PHP="${REMOTE_DIR%/}/${RID}_bind.php"

scp_upload "$TMP_PHP" "$REMOTE_PHP" > /dev/null 2>&1 || {
    print_error "通过 SCP 上传 PHP 绑定脚本失败"
    rm -f "$TMP_PHP"
    exit $EXIT_RUNTIME_ERROR
}
rm -f "$TMP_PHP"

# 执行 PHP 绑定脚本并捕获输出
BIND_OUTPUT=$(ssh_exec "php '$REMOTE_PHP' '$CERT_REFID'; rm -f '$REMOTE_PHP'") || true

if [ -n "$BIND_OUTPUT" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        print_info "远端: $line"
    done <<< "$BIND_OUTPUT"
fi

if ! echo "$BIND_OUTPUT" | grep -q "SUCCESS:"; then
    print_error "绑定证书到 WebGUI 失败"
    exit $EXIT_RUNTIME_ERROR
fi

# ==========================================================
# 步骤 4: 清理旧的托管证书
# ==========================================================
NORM_PREFIX=$(normalize_prefix "$PREFIX")

SEARCH_PAYLOAD=$(jq -n \
    --arg phrase "$NORM_PREFIX" \
    '{"current": 1, "rowCount": 200, "searchPhrase": $phrase, "sort": {"descr": "desc"}}')

SEARCH_RESULT=$(api_request POST "/trust/cert/search" "$SEARCH_PAYLOAD") || {
    print_warning "无法搜索托管证书进行清理"
    print_success "证书已部署到 $HOST"
    exit $EXIT_SUCCESS
}

# 筛选 descr 以规范化前缀开头的证书，收集超出 KEEP 数量的 UUID
PRUNE_UUIDS=$(echo "$SEARCH_RESULT" | jq -r --arg pfx "$NORM_PREFIX" --argjson keep "$KEEP" \
    '[.rows[] | select(.descr | startswith($pfx))] | .[$keep:][] | .uuid // empty')

REMOVED=0
for uuid in $PRUNE_UUIDS; do
    [ -z "$uuid" ] && continue

    # 检查证书是否正在使用或匹配当前活跃的 refid
    CI=$(api_request GET "/trust/cert/get/${uuid}" 2>/dev/null) || continue
    CI_REFID=$(echo "$CI" | jq -r '.cert.refid // empty')
    CI_IN_USE=$(echo "$CI" | jq -r '.cert.in_use // "0"')

    if [ "$CI_REFID" = "$CERT_REFID" ] || [ "$CI_IN_USE" = "1" ]; then
        continue
    fi

    DEL_RESULT=$(api_request POST "/trust/cert/del/${uuid}" "{}" 2>/dev/null) || continue
    DEL_STATUS=$(echo "$DEL_RESULT" | jq -r '.result // empty')
    if [ "$DEL_STATUS" = "deleted" ]; then
        REMOVED=$((REMOVED + 1))
    fi
done

if [ "$REMOVED" -gt 0 ]; then
    # 清理后重新配置信任存储
    api_request POST "/trust/settings/reconfigure" "{}" > /dev/null 2>&1 || true
    print_info "已通过 Trust API 清理 $REMOVED 个旧的托管证书"
fi

print_success "证书已部署到 $HOST"
exit $EXIT_SUCCESS
