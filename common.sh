#!/bin/bash
# ==========================================================
# common.sh: 部署脚本共享库
#
# 提供统一的日志输出、退出码、文件校验与随机后缀工具，
# 供 deploy_to_pve.sh / deploy_to_opnsense.sh /
# deploy_to_truenas.sh 通过 source 引入。
#
# 用法: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# ==========================================================

# 防止重复加载
[ -n "${_DEPLOY_COMMON_LOADED:-}" ] && return 0
_DEPLOY_COMMON_LOADED=1

# ==========================================================
# 统一退出码 (供 source 本库的脚本使用)
# ==========================================================
# shellcheck disable=SC2034
EXIT_SUCCESS=0
# shellcheck disable=SC2034
EXIT_RUNTIME_ERROR=1
# shellcheck disable=SC2034
EXIT_CERT_NOT_FOUND=2
# shellcheck disable=SC2034
EXIT_KEY_NOT_FOUND=3
EXIT_INVALID_INPUT=4

# ==========================================================
# 日志输出 (带时间戳；ERROR 输出到 stderr)
# ==========================================================
print_info()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"; }
print_warning() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1"; }
print_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2; }
print_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1"; }

# ==========================================================
# 通用工具
# ==========================================================

# 校验文件存在且可读
# 用法: validate_readable_file <path> <label> <not_found_exit_code>
validate_readable_file() {
    local path="$1" label="$2" exit_code="$3"
    if [ ! -f "$path" ]; then
        print_error "${label}未找到: $path"
        return "$exit_code"
    fi
    if [ ! -r "$path" ]; then
        print_error "${label}不可读: $path"
        return "$EXIT_INVALID_INPUT"
    fi
    return "$EXIT_SUCCESS"
}

# 生成 N 个字符的十六进制随机后缀 (默认 4)
gen_random_suffix() {
    local len="${1:-4}"
    head -c "$(( (len + 1) / 2 ))" /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c "$len"
}
