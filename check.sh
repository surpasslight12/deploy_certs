#!/bin/bash
# ==========================================================
# check.sh: 静态检查 (bash 语法 / shellcheck / 配置模板 / PHP 语法)
#
# 用法: bash check.sh
# ==========================================================

set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPTS=(common.sh check.sh deploy_all.sh deploy_to_pve.sh deploy_to_opnsense.sh deploy_to_truenas.sh)

echo "[1/4] bash 语法检查..."
bash -n "${SCRIPTS[@]}"

echo "[2/4] shellcheck..."
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x -S warning "${SCRIPTS[@]}"
else
    echo "      跳过 (未安装 shellcheck: sudo apt install -y shellcheck)"
fi

echo "[3/4] 配置模板 JSON 校验..."
if command -v jq >/dev/null 2>&1; then
    jq empty deploy_config.example.json
else
    echo "      跳过 (未安装 jq: sudo apt install -y jq)"
fi

echo "[4/4] PHP 语法检查..."
if command -v php >/dev/null 2>&1; then
    php -l opnsense_bind.php
else
    echo "      跳过 (未安装 php)"
fi

echo "全部检查通过"
