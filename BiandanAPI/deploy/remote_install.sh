#!/bin/bash
# 在服务器上以 root 运行：deploy.sh 先把文件传到 /tmp/biandan-api-deploy/，再通过 ssh 执行本脚本。
# 安装程序和 systemd 服务，把 /biandan/api/ 的转发加进 nginx（先备份，nginx -t 不通过就还原）。
set -euo pipefail
SRC=/tmp/biandan-api-deploy
CONF=/etc/nginx/conf.d/default.conf
SNIPPET=/etc/nginx/snippets/biandan-api.conf
INCLUDE="    include ${SNIPPET};"
BACKUP=/root/nginx-backup
STAMP=$(date +%Y%m%d-%H%M%S)
die() { echo "✗ $*" >&2; exit 1; }

# ---- 用户和密钥文件 ----
id biandan-api >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /var/lib/biandan-api --shell /sbin/nologin biandan-api
install -d -m 750 -o root -g biandan-api /etc/biandan-api
if [ ! -f /etc/biandan-api/keys ]; then
    printf '# 每行一把：角色(push/read) 名称 sha256:哈希。用 BiandanAPI/deploy.sh --add-key 增加。\n' > /etc/biandan-api/keys
fi
chown root:biandan-api /etc/biandan-api/keys
chmod 640 /etc/biandan-api/keys

# ---- 程序和服务 ----
install -m 755 "${SRC}/biandan-api-linux-amd64" /usr/local/bin/biandan-api.new
NEW_VERSION=$(/usr/local/bin/biandan-api.new version) || die "新程序在服务器上运行不了"
mv -f /usr/local/bin/biandan-api.new /usr/local/bin/biandan-api
install -m 644 "${SRC}/biandan-api.service" /etc/systemd/system/biandan-api.service
systemctl daemon-reload
systemctl enable --quiet biandan-api
systemctl restart biandan-api
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 2 http://127.0.0.1:18730/v1/health >/dev/null 2>&1; then ok=1; break; fi
    sleep 0.5
done
if [ "${ok}" != 1 ]; then
    journalctl -u biandan-api -n 20 --no-pager
    die "服务没有起来"
fi
echo "服务 ${NEW_VERSION} 已运行：$(curl -fsS --max-time 2 http://127.0.0.1:18730/v1/health)"

# ---- nginx ----
install -d -m 755 /etc/nginx/snippets "${BACKUP}"
need_include=1
grep -qF "include ${SNIPPET};" "${CONF}" && need_include=0
if [ "${need_include}" = 0 ] && cmp -s "${SRC}/nginx-locations.conf" "${SNIPPET}"; then
    echo "nginx 转发配置没有变化"
else
    cp -p "${CONF}" "${BACKUP}/default.conf.${STAMP}"
    had_snippet=0
    if [ -f "${SNIPPET}" ]; then cp -p "${SNIPPET}" "${BACKUP}/biandan-api.conf.${STAMP}"; had_snippet=1; fi
    restore() {
        cat "${BACKUP}/default.conf.${STAMP}" > "${CONF}"
        if [ "${had_snippet}" = 1 ]; then cp -p "${BACKUP}/biandan-api.conf.${STAMP}" "${SNIPPET}"; else rm -f "${SNIPPET}"; fi
    }
    install -m 644 "${SRC}/nginx-locations.conf" "${SNIPPET}"
    if [ "${need_include}" = 1 ]; then
        # 插在 443 那个 server 里第一个「location / {」前面
        awk -v inc="${INCLUDE}" '
            /listen[[:space:]]+443/ { in443 = 1 }
            in443 && !done && /^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{/ {
                print "    # 便单日程 API（BiandanAPI/deploy.sh 安装）"; print inc; print ""; done = 1
            }
            { print }
            END { if (!done) exit 3 }
        ' "${CONF}" > /tmp/biandan-api-default.conf || { restore; die "在 ${CONF} 里没找到 443 的 location /，没有改 nginx"; }
        cat /tmp/biandan-api-default.conf > "${CONF}"
        rm -f /tmp/biandan-api-default.conf
    fi
    if ! nginx -t >/tmp/biandan-api-nginx-test.log 2>&1; then
        cat /tmp/biandan-api-nginx-test.log
        restore
        die "nginx -t 没通过，已还原配置"
    fi
    systemctl reload nginx
    echo "nginx 已加上 /biandan/api/ 转发（原配置备份在 ${BACKUP}/default.conf.${STAMP}）"
fi

# 经 nginx 访问一次（绕过 ESA，直接打本机）。这里只确认转发通不通，不校验证书；证书另外检查。
rm -rf "${SRC}"
local_check=$(curl -kfsS --max-time 5 --resolve www.aigslb.link:443:127.0.0.1 https://www.aigslb.link/biandan/api/v1/health) || die "经 nginx 访问不到服务"
echo "经 nginx：${local_check}"
CERT=/etc/letsencrypt/live/www.aigslb.link/fullchain.pem
if [ -f "${CERT}" ] && ! openssl x509 -checkend 0 -noout -in "${CERT}" >/dev/null 2>&1; then
    echo "⚠︎ 源站证书已过期（$(openssl x509 -enddate -noout -in "${CERT}" | cut -d= -f2)）。经 ESA 访问不受影响时可以先不管，但 ESA 回源若校验证书会失败。"
fi
