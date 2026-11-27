#!/usr/bin/env bash
# KR-MP (赤羽的王国保卫战 FL 8.2.0 联机 MOD) · Linux 云服务器 1 行傻瓜开服脚本
# 用法: curl -fsSL https://gitee.com/chiyu-studio/chiyu-kr-coop/raw/main/tools/deploy_server.sh | sudo bash
set -euo pipefail

BIN_PATH="/usr/local/bin/kr-mp-server"
SERVICE_NAME="kr-mp-server"
TCP_PORT="${KR_MP_PORT:-17780}"
HTTP_PORT="${KR_MP_HTTP_PORT:-17781}"
GRACE_SEC="${KR_MP_GRACE:-300}"

echo "============================================================"
echo "  赤羽的王国保卫战 FL 8.2.0 · 公网中继服 1 行全自动部署脚本"
echo "============================================================"

if [ "$(id -u)" -ne 0 ]; then
  echo "[错误] 请使用 root 或 sudo 运行本脚本！"
  exit 1
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
  echo "[错误] 当前系统架构为 $ARCH，预编译二进制仅支持 x86_64 (amd64)。"
  exit 1
fi

echo "[1/4] 正在获取最新版本信息与 SHA-256 校验值..."
VER_JSON=""
for VURL in \
  "https://gitee.com/chiyu-studio/chiyu-kr-coop/raw/main/version.json" \
  "https://raw.githubusercontent.com/996asd/chiyu-kr-coop/main/version.json"; do
  if VER_JSON="$(curl -fsSL --connect-timeout 10 "$VURL" 2>/dev/null)" && [ -n "$VER_JSON" ]; then
    break
  fi
done

if [ -z "$VER_JSON" ]; then
  echo "[错误] 无法访问 Gitee / GitHub 获取 version.json，请检查服务器网络。"
  exit 1
fi

VERSION="$(printf '%s' "$VER_JSON" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
EXPECT_SHA="$(printf '%s' "$VER_JSON" | sed -n 's/.*"server_linux_sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 | tr '[:upper:]' '[:lower:]')"
VERSION="${VERSION:-2.3.0}"
echo "  目标版本: v${VERSION}"

echo "[2/4] 正在下载 kr-mp-server-linux-amd64..."
TMP_BIN="$(mktemp /tmp/kr-mp-server.XXXXXX)"
trap 'rm -f "$TMP_BIN"' EXIT

DL_OK=0
for DURL in \
  "https://gitee.com/chiyu-studio/chiyu-kr-coop/releases/download/v${VERSION}/kr-mp-server-linux-amd64" \
  "https://github.com/996asd/chiyu-kr-coop/releases/download/v${VERSION}/kr-mp-server-linux-amd64"; do
  echo "  尝试下载: $DURL"
  if curl -fL --connect-timeout 15 --max-time 120 -o "$TMP_BIN" "$DURL"; then
    DL_OK=1
    break
  fi
done

if [ "$DL_OK" -ne 1 ]; then
  echo "[错误] 下载 kr-mp-server-linux-amd64 失败。"
  exit 1
fi

if [ -n "$EXPECT_SHA" ] && command -v sha256sum >/dev/null 2>&1; then
  GOT_SHA="$(sha256sum "$TMP_BIN" | awk '{print tolower($1)}')"
  if [ "$GOT_SHA" != "$EXPECT_SHA" ]; then
    echo "[错误] SHA-256 校验失败！预期: $EXPECT_SHA，实际: $GOT_SHA"
    exit 1
  fi
  echo "  SHA-256 完整性校验通过 √"
fi

systemctl stop "$SERVICE_NAME" 2>/dev/null || true
install -m 0755 "$TMP_BIN" "$BIN_PATH"

echo "[3/4] 正在配置 systemd 开机自启守护服务..."
cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=KR-MP Public Relay Server (FL 8.2.0 Co-op)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -addr :${TCP_PORT} -http 127.0.0.1:${HTTP_PORT} -grace ${GRACE_SEC}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

echo "[4/4] 正在检查系统防火墙放行 TCP ${TCP_PORT}..."
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "active"; then
  ufw allow "${TCP_PORT}/tcp" >/dev/null || true
  echo "  已通过 ufw 放行 TCP ${TCP_PORT}"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${TCP_PORT}/tcp" >/dev/null || true
  firewall-cmd --reload >/dev/null || true
  echo "  已通过 firewalld 放行 TCP ${TCP_PORT}"
else
  echo "  未检测到本机 ufw/firewalld（注意：请务必在云厂商控制台安全组放行 TCP ${TCP_PORT} ！）"
fi

PUB_IP="$(curl -fsSL --connect-timeout 4 https://api.ip.sb/ip 2>/dev/null || curl -fsSL --connect-timeout 4 https://ifconfig.me 2>/dev/null || echo "<你的服务器公网IP>")"
PUB_IP="$(printf '%s' "$PUB_IP" | tr -d '[:space:]')"

echo ""
echo "============================================================"
echo "  [部署成功] KR-MP 公网中继服 v${VERSION} 已后台常驻运行！"
echo "============================================================"
echo "  游戏内「公网服务器」页直接填写地址: ${PUB_IP}:${TCP_PORT}"
echo "  重要提醒: 请确保阿里云/腾讯云等控制台安全组已放行 TCP ${TCP_PORT}"
echo "  查看运行状态: systemctl status ${SERVICE_NAME}"
echo "  查看实时日志: journalctl -u ${SERVICE_NAME} -f"
echo "============================================================"
