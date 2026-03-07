#!/usr/bin/env bash
set -euo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 运行。"
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  echo "当前脚本仅支持 Debian / Ubuntu。"
  exit 1
fi

generate_password() {
  local pw=""
  while [ "${#pw}" -lt 16 ]; do
    pw="${pw}$(LC_ALL=C head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' || true)"
  done
  printf '%s' "${pw:0:16}"
}

can_render_qr_terminal() {
  [[ -t 1 ]] || return 1
  command -v qrencode >/dev/null 2>&1 || return 1

  local term="${TERM:-}"
  case "$term" in
    dumb|"")
      return 1
      ;;
  esac

  return 0
}

show_qr_or_fallback() {
  local url="$1"
  local user_file_base="$2"

  echo "链接:   ${url}"

  if can_render_qr_terminal; then
    echo "二维码如下，请直接扫码："
    echo "------------------------------"
    if qrencode -t ANSIUTF8 "${url}"; then
      echo "------------------------------"
      return 0
    fi
  fi

  echo "当前终端可能不支持 UTF-8 / ANSI 二维码显示，已回退。"
  echo "你可以直接复制上面的链接，或使用备用 PNG 文件扫码。"

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o "${user_file_base}.png" "${url}" >/dev/null 2>&1 || true
    if [[ -f "${user_file_base}.png" ]]; then
      echo "备用二维码文件已生成: ${user_file_base}.png"
    fi
  fi
}

read -rp "请输入域名（例如 deth.icyzb.top）: " DOMAIN
read -rp "请输入邮箱（用于申请证书）: " EMAIL

if [[ -z "${DOMAIN}" || -z "${EMAIL}" ]]; then
  echo "域名和邮箱不能为空。"
  exit 1
fi

echo
echo "提醒：Cloudflare 中 ${DOMAIN} 必须设置为 DNS only（灰云）"
echo

AUTH_LINES=""
USER_INFO=""
USER_COUNT=0
USER_DIR="/root/naive-users/${DOMAIN}"

echo
echo "开始安装依赖..."
echo

apt update
apt install -y \
  curl \
  wget \
  git \
  golang \
  xz-utils \
  build-essential \
  ca-certificates \
  ufw \
  qrencode

mkdir -p /root/tmp /root/naive "${USER_DIR}"
export TMPDIR=/root/tmp
export GOCACHE=/root/.cache/go-build
export PATH=$PATH:/root/go/bin:/usr/local/bin

go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

cd /root/naive
/root/go/bin/xcaddy build \
  --output /usr/local/bin/caddy-naive \
  --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive

chmod +x /usr/local/bin/caddy-naive

mkdir -p /var/www/site
cat >/var/www/site/index.html <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Welcome</title>
</head>
<body>
  <h1>Welcome to ${DOMAIN}</h1>
  <p>This is a normal website.</p>
</body>
</html>
HTML

while true; do
  read -rp "请输入用户名: " USERNAME

  if [[ -z "${USERNAME}" ]]; then
    echo "用户名不能为空，请重新输入。"
    continue
  fi

  PASSWORD="$(generate_password)"
  URL="https://${USERNAME}:${PASSWORD}@${DOMAIN}:443"
  USER_BASE="${USER_DIR}/${USERNAME}"

  AUTH_LINES="${AUTH_LINES}"$'\n'"        basic_auth ${USERNAME} ${PASSWORD}"
  USER_INFO="${USER_INFO}"$'\n'"${USERNAME}:${PASSWORD}"
  USER_COUNT=$((USER_COUNT + 1))

  echo "${URL}" > "${USER_BASE}.txt"

  echo
  echo "=============================="
  echo "用户名: ${USERNAME}"
  echo "密码:   ${PASSWORD}"
  show_qr_or_fallback "${URL}" "${USER_BASE}"
  echo "链接已保存到: ${USER_BASE}.txt"
  echo "=============================="
  echo

  read -rp "是否继续添加用户？(y/n): " ADD_MORE
  case "${ADD_MORE}" in
    y|Y) ;;
    n|N) break ;;
    *) break ;;
  esac
done

if [[ "${USER_COUNT}" -eq 0 ]]; then
  echo "至少需要添加一个用户。"
  exit 1
fi

mkdir -p /etc/caddy
cat >/etc/caddy/Caddyfile <<CADDY
{
    order forward_proxy before file_server
}

:443, ${DOMAIN} {
    tls ${EMAIL}

    forward_proxy {${AUTH_LINES}
        hide_ip
        hide_via
        probe_resistance
    }

    file_server {
        root /var/www/site
    }
}
CADDY

/usr/local/bin/caddy-naive fmt --overwrite /etc/caddy/Caddyfile

cat >/etc/systemd/system/caddy-naive.service <<'SERVICE'
[Unit]
Description=Caddy (Naive forward_proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8
ExecStart=/usr/local/bin/caddy-naive run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy-naive reload --config /etc/caddy/Caddyfile
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl disable --now caddy 2>/dev/null || true
systemctl enable --now caddy-naive

ufw allow 80/tcp || true
ufw allow 443/tcp || true

SUMMARY_FILE="${USER_DIR}/users.txt"
{
  echo "Domain: ${DOMAIN}"
  echo "Generated at: $(date '+%F %T')"
  echo
  echo "${USER_INFO}"
} > "${SUMMARY_FILE}"

echo
echo "=========================================="
echo "安装完成。"
echo "域名: ${DOMAIN}"
echo "账号汇总文件: ${SUMMARY_FILE}"
echo "单用户文件目录: ${USER_DIR}"
echo
echo "如果终端无法显示二维码，可使用 .png 备用二维码文件。"
echo
echo "服务状态检查："
echo "  systemctl status caddy-naive --no-pager -l"
echo
echo "模块检查："
echo "  /usr/local/bin/caddy-naive list-modules | grep forward_proxy"
echo "=========================================="