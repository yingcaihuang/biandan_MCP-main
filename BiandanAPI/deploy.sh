#!/bin/bash
# 部署和管理便单日程 API（biandan-api）。服务器用 ~/.ssh/config 里的 biandan-update（密钥登录 root）。
#
# 用法（在 BiandanAPI 目录）：
#   ./deploy.sh                            测试、编译、上传、重启服务、配置 nginx 转发、检查公网
#   ./deploy.sh --check                    只检查公网接口
#   ./deploy.sh --add-key read <名称>       新建一把读取密钥（建议每台 ESP32 一把）
#   ./deploy.sh --add-key push <名称>       新建一把推送密钥（给便单 App）
#   ./deploy.sh --add-key report <名称>     新建一把上报密钥（给上报通用数据的程序，见 DATA_API.md）
#   ./deploy.sh --remove-key <角色> <名称>   删除一把密钥，立即生效
#   ./deploy.sh --list-keys                列出服务器上的密钥名称
#
# 新建的密钥只保存在本机 ~/.biandan-api/<角色>-<名称>.key（权限 600），服务器只存 SHA-256。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HOST=${BIANDAN_API_HOST:-biandan-update}
PUBLIC=${BIANDAN_API_PUBLIC:-https://www.aigslb.link/biandan/api}
SECRETS=${BIANDAN_API_SECRETS:-${HOME}/.biandan-api}
SSH_OPTS=(-o BatchMode=yes -o LogLevel=ERROR)

die() { echo "✗ $*" >&2; exit 1; }
step() { echo "==> $*"; }
remote() { ssh "${SSH_OPTS[@]}" "${HOST}" "$@"; }

check_name() {
    [[ "$1" == push || "$1" == read || "$1" == report ]] || die "角色只能是 push、read 或 report"
    [[ "$2" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "名称只能用字母、数字、点、下划线、短横线，最多 64 个"
}

add_key() {
    local role=$1 name=$2 file out key line
    check_name "${role}" "${name}"
    file="${SECRETS}/${role}-${name}.key"
    [ ! -e "${file}" ] || die "本机已经有 ${file}，换个名称，或先 --remove-key 再删掉这个文件"
    remote test -f /etc/biandan-api/keys || die "服务器上还没有密钥文件，先运行一次 ./deploy.sh"
    if remote "grep -qE '^${role} ${name} ' /etc/biandan-api/keys"; then die "服务器上已经有 ${role} ${name}"; fi
    out=$(cd "${HERE}" && go run . genkey "${role}" "${name}" 2>/dev/null) || die "生成密钥失败"
    key=$(printf '%s\n' "${out}" | sed -n 's/^KEY //p')
    line=$(printf '%s\n' "${out}" | sed -n 's/^LINE //p')
    [ -n "${key}" ] && [ -n "${line}" ] || die "生成密钥失败"
    mkdir -p "${SECRETS}"
    chmod 700 "${SECRETS}"
    (umask 077; printf '%s\n' "${key}" > "${file}")
    printf '%s\n' "${line}" | remote 'cat >> /etc/biandan-api/keys && systemctl reload biandan-api'
    echo "已新建 ${role} 密钥「${name}」，已生效。密钥保存在 ${file}（权限 600），服务器只存哈希。"
}

remove_key() {
    local role=$1 name=$2
    check_name "${role}" "${name}"
    remote "grep -qE '^${role} ${name} ' /etc/biandan-api/keys" || die "服务器上没有 ${role} ${name}"
    remote "sed -i '/^${role} ${name} /d' /etc/biandan-api/keys && systemctl reload biandan-api"
    echo "已删除服务器上的 ${role} 密钥「${name}」，已生效。本机文件 ${SECRETS}/${role}-${name}.key 没有动，需要的话自己删。"
}

list_keys() {
    remote "awk '!/^#/ && NF == 3 { print \$1, \$2 }' /etc/biandan-api/keys"
}

check_public() {
    local out code
    out=$(curl -sS --max-time 15 "${PUBLIC}/v1/health") || die "公网访问 ${PUBLIC}/v1/health 失败"
    echo "健康检查：${out}"
    printf '%s' "${out}" | grep -q '"service":"biandan-api"' || die "公网返回的不是 biandan-api（ESA 缓存或转发没生效）"
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST --max-time 15 "${PUBLIC}/v1/schedule")
    [ "${code}" = 401 ] || die "不带密钥 POST /v1/schedule 应返回 401，实际 ${code}"
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST --max-time 15 "${PUBLIC}/v1/data/ingest")
    [ "${code}" = 401 ] || die "不带密钥 POST /v1/data/ingest 应返回 401，实际 ${code}"
    echo "公网接口正常：${PUBLIC}（不带密钥的请求返回 401）"
}

deploy() {
    command -v go >/dev/null || die "需要 Go（brew install go）"
    step "1. 检查和测试"
    (cd "${HERE}" && test -z "$(gofmt -l .)" && go vet ./... && go test -count=1 ./...) || die "测试没通过"
    step "2. 编译 linux/amd64"
    (cd "${HERE}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o dist/biandan-api-linux-amd64 .)
    step "3. 上传到 ${HOST}"
    remote 'rm -rf /tmp/biandan-api-deploy && mkdir -m 700 /tmp/biandan-api-deploy'
    scp -q "${SSH_OPTS[@]}" "${HERE}/dist/biandan-api-linux-amd64" "${HERE}/deploy/biandan-api.service" \
        "${HERE}/deploy/nginx-locations.conf" "${HOST}:/tmp/biandan-api-deploy/"
    step "4. 安装服务、配置 nginx"
    remote 'bash -s' < "${HERE}/deploy/remote_install.sh"
    step "5. 检查公网"
    check_public
}

case "${1:-}" in
    "") deploy ;;
    --check) check_public ;;
    --add-key) [ $# -eq 3 ] || die "用法：./deploy.sh --add-key push|read|report <名称>"; add_key "$2" "$3" ;;
    --remove-key) [ $# -eq 3 ] || die "用法：./deploy.sh --remove-key push|read|report <名称>"; remove_key "$2" "$3" ;;
    --list-keys) list_keys ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "不认识的参数：$1（--help 看用法）" ;;
esac
