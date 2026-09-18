#!/usr/bin/env bash
# ============================================================================
# isongwrt —— sing-box 服务端（落地机）一键部署脚本
#
#   用法（在目标服务器上以 root 运行）:
#     singbox-deploy.sh install   [--listen-port 15835] [--with-smartdns] [--no-service]
#                                 [--smartdns-port 6053] [--version v1.15.0-alpha.6]
#                                 [--source auto|direct|mirror] [--binary /path/to/sing-box]
#                                 [--open-firewall] [--dry-run]
#     singbox-deploy.sh upgrade   [同上]
#     singbox-deploy.sh rollback
#     singbox-deploy.sh status | check | uninstall
#
#   设计约定:
#     * 内核: 一律使用 **官方 Release 原样二进制**（SagerNet/sing-box），
#             安装为 /usr/local/bin/sing-box —— 不改名、不二次打包、不自编译
#     * 版本: 默认取官方最新 tag（alpha/rc/stable 均可能出现），可用 --version 锁定
#     * 协议: shadowsocks-2022 / 2022-blake3-aes-256-gcm，32B base64 密钥，
#             multiplex(h2mux)+padding 对齐客户端；全程无 TLS
#     * 幂等: 重复运行安全；密钥已存在则复用（不轮换）
#     * 备份: 改动前备份配置与二进制，rollback 可恢复
#     * 校验: 内建 sing-box check；启动后端口 + FATAL 级日志健康检查
#     * 指纹: 版本 + 二进制/配置 sha256 → /var/lib/isongwrt/deploy-record.json
#     * 密钥: 只落在服务器本地文件（0600），脚本不回显、仓库不含
#     * 下载: --source 可选直连 GitHub 或经加速前缀（国内服务器常用）
# ============================================================================
set -euo pipefail

# ---------- 默认值 ----------
ROLE="landing"
LISTEN_PORT="${ISONGWRT_SS2022_PORT:-15835}"
METHOD="2022-blake3-aes-256-gcm"
WITH_SMARTDNS=0
SMARTDNS_PORT="${ISONGWRT_SMARTDNS_PORT:-6053}"
SMARTDNS_UPSTREAMS="${ISONGWRT_SMARTDNS_UPSTREAMS:-1.1.1.1 8.8.8.8 9.9.9.9}"
BIN_PATH=""
PIN_VERSION=""
OPEN_FIREWALL=0
DRY_RUN=0
NO_SERVICE=0
SOURCE="${ISONGWRT_SOURCE:-auto}"          # auto | direct | mirror
GH_PROXY="${ISONGWRT_GH_PROXY:-https://ghfast.top/}"
GH_REPO="SagerNet/sing-box"
SRV_USER="sing-box"
# 路径可用环境变量覆盖（便于沙箱测试或自定义布局）
BIN="${ISONGWRT_BIN:-/usr/local/bin/sing-box}"          # 官方名称，不改
CONF_DIR="${ISONGWRT_CONF_DIR:-/etc/sing-box}"
CONF_SUBDIR="conf"
WORK_DIR="${CONF_DIR}"
DATA_DIR="${ISONGWRT_DATA_DIR:-/var/lib/isongwrt}"
LEGACY_DATA_DIR="/var/lib/isongwrt-legacy"         # 兼容旧部署记录（可读不可写）
BACKUP_DIR="${ISONGWRT_BACKUP_DIR:-/var/backups/isongwrt}"
SMARTDNS_CONF="${ISONGWRT_SMARTDNS_CONF:-/etc/smartdns/isongwrt.conf}"
SMARTDNS_ENVFILE="${ISONGWRT_SMARTDNS_ENVFILE:-/etc/default/smartdns}"
UNIT_FILE="${ISONGWRT_UNIT_FILE:-/etc/systemd/system/sing-box.service}"
RECORD="${DATA_DIR}/deploy-record.json"
PASSWORD_FILE="${DATA_DIR}/ss2022.password"
ACTION="install"

log()  { printf '\033[32m[isongwrt]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[isongwrt]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[isongwrt] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '\033[36m[dry-run]\033[0m %s\n' "$*"; else "$@"; fi; }

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

parse_args() {
  [[ $# -lt 1 ]] && usage
  while [[ $# -gt 0 ]]; do
    case "$1" in
      install|upgrade|rollback|status|check|uninstall) ACTION="$1"; shift ;;
      --role) ROLE="$2"; shift 2 ;;
      --listen-port) LISTEN_PORT="$2"; shift 2 ;;
      --with-smartdns) WITH_SMARTDNS=1; shift ;;
      --smartdns-port) SMARTDNS_PORT="$2"; shift 2 ;;
      --smartdns-upstreams) SMARTDNS_UPSTREAMS="$2"; shift 2 ;;
      --binary) BIN_PATH="$(readlink -f "$2")"; shift 2 ;;
      --version) PIN_VERSION="$2"; shift 2 ;;
      --source) SOURCE="$2"; shift 2 ;;
      --gh-proxy) GH_PROXY="$2"; shift 2 ;;
      --open-firewall) OPEN_FIREWALL=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --no-service) NO_SERVICE=1; shift ;;
      --help|-h) usage ;;
      *) die "未知参数: $1（--help 查看用法）" ;;
    esac
  done
  case "$SOURCE" in auto|direct|mirror) ;; *) die "--source 只支持 auto|direct|mirror" ;; esac
}

# ---------------------------------------------------------------------------
# 下载（支持直连 / 加速前缀 / 自动回退）
# ---------------------------------------------------------------------------
dl() { # dl <url> <dest>
  local url="$1" dest="$2"
  case "$SOURCE" in
    direct) curl -fSL --retry 2 --connect-timeout 15 -o "$dest" "$url" ;;
    mirror) curl -fSL --retry 2 --connect-timeout 15 -o "$dest" "${GH_PROXY}${url}" ;;
    auto)
      if ! curl -fSL --retry 1 --connect-timeout 10 -o "$dest" "$url" 2>/dev/null; then
        warn "直连失败，改用加速前缀 ${GH_PROXY}"
        curl -fSL --retry 2 --connect-timeout 15 -o "$dest" "${GH_PROXY}${url}"
      fi ;;
  esac
}

resolve_version() {
  if [[ -n "$PIN_VERSION" ]]; then VERSION_TAG="$PIN_VERSION"; log "目标版本（指定）: ${VERSION_TAG}"; return; fi
  local tmp; tmp="$(mktemp)"
  dl "https://github.com/${GH_REPO}/releases.atom" "$tmp" >/dev/null 2>&1 \
    || die "无法获取版本列表（可用 --source mirror --gh-proxy <前缀> 或 --version 锁定）"
  VERSION_TAG="$(sed -n 's#.*<id>tag:github.com,2008:Repository/[0-9]*/\(v[^<]*\)</id>.*#\1#p' "$tmp" \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  rm -f "$tmp"
  [[ -n "$VERSION_TAG" ]] || die "解析版本失败（响应异常）"
  log "目标版本（官方最新）: ${VERSION_TAG}"
}

# ---------------------------------------------------------------------------
# 前置检查 / 依赖
# ---------------------------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "需要 root 运行"
  command -v curl >/dev/null || die "缺 curl（apt-get install -y curl）"
  local arch; arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$arch" in amd64|x86_64) ARCH_TAG="amd64" ;; arm64|aarch64) ARCH_TAG="arm64" ;; *) die "暂不支持架构: $arch" ;; esac
  if [[ "$ACTION" == "install" || "$ACTION" == "upgrade" ]]; then
    local avail; avail="$(df -BG / | awk 'NR==2{print int($4)}')"
    [[ "$avail" -ge 2 ]] || die "磁盘可用空间不足 2G（${avail}G）"
    if ss -tln 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
      ss -tlnp 2>/dev/null | grep ":${LISTEN_PORT} " | grep -q "sing-box" \
        || die "端口 ${LISTEN_PORT} 已被占用：$(ss -tlnp | grep ":${LISTEN_PORT} " | head -1)"
    fi
  fi
  log "preflight OK（role=${ROLE} port=${LISTEN_PORT} arch=${ARCH_TAG} source=${SOURCE}）"
}

ensure_deps() {
  export DEBIAN_FRONTEND=noninteractive
  local need=()
  command -v openssl >/dev/null || need+=(openssl)
  command -v ss >/dev/null || need+=(iproute2)
  command -v dig >/dev/null || need+=(dnsutils)
  if [[ ${#need[@]} -gt 0 ]]; then
    log "安装依赖: ${need[*]}"
    run apt-get update -qq
    run apt-get install -y -qq "${need[@]}"
  fi
}

# ---------------------------------------------------------------------------
# 内核：官方 Release 原样二进制
# ---------------------------------------------------------------------------
install_binary() {
  run install -d -m 0755 "$(dirname "$BIN")"
  if [[ -n "$BIN_PATH" ]]; then
    [[ -x "$BIN_PATH" ]] || die "指定二进制不可执行: $BIN_PATH"
    run install -m 0755 "$BIN_PATH" "$BIN"
    VERSION_TAG="custom"; BUILD_META_JSON="{\"source\":\"user-provided\",\"path\":\"${BIN_PATH}\"}"
    log "使用指定二进制: ${BIN_PATH} → ${BIN}"
    return
  fi
  # Debian/Ubuntu 优先 glibc 构建，其余用静态构建
  local flavor=""
  if ldd --version 2>/dev/null | head -1 | grep -qiE 'glibc|libc6'; then flavor="-glibc"; fi
  local base="https://github.com/${GH_REPO}/releases/download/${VERSION_TAG}"
  local tarball="sing-box-${VERSION_TAG#v}-linux-${ARCH_TAG}${flavor}.tar.gz"
  local tmpd; tmpd="$(mktemp -d)"
  log "下载官方产物: ${tarball}"
  if ! dl "${base}/${tarball}" "${tmpd}/${tarball}" 2>/dev/null; then
    [[ -n "$flavor" ]] || die "下载失败: ${tarball}"
    warn "glibc 产物不可用，退回静态构建"
    flavor=""; tarball="sing-box-${VERSION_TAG#v}-linux-${ARCH_TAG}.tar.gz"
    dl "${base}/${tarball}" "${tmpd}/${tarball}" || die "下载失败: ${tarball}"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[36m[dry-run]\033[0m 解压 %s 并安装其中的 sing-box → %s\n' "$tarball" "$BIN"
  else
    tar -xzf "${tmpd}/${tarball}" -C "$tmpd"
    local src; src="$(find "$tmpd" -type f -name sing-box | head -1)"
    [[ -n "$src" ]] || die "压缩包内未找到 sing-box 可执行文件"
    install -m 0755 "$src" "$BIN"
  fi
  rm -rf "$tmpd"
  BUILD_META_JSON="{\"source\":\"official-release\",\"asset\":\"${tarball}\"}"
  log "已安装官方二进制 → ${BIN}（版本校验见下一步）"
}

ensure_user() {
  id "$SRV_USER" &>/dev/null || run useradd --system --no-create-home --shell /usr/sbin/nologin "$SRV_USER"
}

# ---------------------------------------------------------------------------
# 配置生成（幂等：密钥存在则复用）
# ---------------------------------------------------------------------------
gen_configs() {
  local password
  if [[ -f "$PASSWORD_FILE" ]]; then
    password="$(cat "$PASSWORD_FILE")"; log "复用已存在密钥: ${PASSWORD_FILE}"
  elif [[ -f "${LEGACY_DATA_DIR}/ss2022.password" ]]; then
    password="$(cat "${LEGACY_DATA_DIR}/ss2022.password")"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '\033[36m[dry-run]\033[0m 迁移旧密钥 %s → %s\n' "${LEGACY_DATA_DIR}/ss2022.password" "$PASSWORD_FILE"
    else
      install -d -m 0700 "$DATA_DIR"; printf '%s' "$password" > "$PASSWORD_FILE"; chmod 600 "$PASSWORD_FILE"
      log "从旧部署目录迁移密钥 → ${PASSWORD_FILE}"
    fi
  else
    password="$(openssl rand -base64 32)"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '\033[36m[dry-run]\033[0m 生成 ss2022 密钥 → %s（dry-run 不落盘）\n' "$PASSWORD_FILE"
    else
      install -d -m 0700 "$DATA_DIR"; printf '%s' "$password" > "$PASSWORD_FILE"; chmod 600 "$PASSWORD_FILE"
      log "已生成 ss2022 密钥 → ${PASSWORD_FILE}（勿入库/勿外传）"
    fi
  fi

  run install -d -m 0750 "${CONF_DIR}/${CONF_SUBDIR}"
  local cdir="${CONF_DIR}/${CONF_SUBDIR}"

  _write() { # _write <file> <<EOF ... EOF
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '\033[36m[dry-run]\033[0m 生成 %s（%s 行）\n' "$1" "$(wc -l < /dev/stdin)"
    else
      cat > "$1"
    fi
  }

  _write "${cdir}/00_log.json" <<'EOF'
{
  "log": { "level": "info", "timestamp": true }
}
EOF

  _write "${cdir}/01_inbounds.json" <<EOF
{
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${LISTEN_PORT},
      "method": "${METHOD}",
      "password": "${password}",
      "multiplex": { "enabled": true, "padding": true }
    }
  ]
}
EOF

  _write "${cdir}/02_outbounds.json" <<'EOF'
{
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

  local dns_tag="google"; [[ $WITH_SMARTDNS -eq 1 ]] && dns_tag="smartdns"
  _write "${cdir}/03_route.json" <<EOF
{
  "http_clients": [ { "tag": "default" } ],
  "route": {
    "final": "direct",
    "default_http_client": "default",
    "default_domain_resolver": { "server": "${dns_tag}", "strategy": "prefer_ipv4" },
    "rules": [
      { "action": "sniff" },
      { "protocol": "bittorrent", "action": "reject" },
      { "rule_set": "geosite-category-ads-all", "action": "reject" },
      { "ip_is_private": true, "action": "reject" },
      { "action": "resolve", "strategy": "prefer_ipv4" },
      { "rule_set": "geoip-cn", "action": "reject" }
    ],
    "rule_set": [
      {
        "tag": "geosite-category-ads-all",
        "type": "remote", "format": "binary", "update_interval": "1d",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs"
      },
      {
        "tag": "geoip-cn",
        "type": "remote", "format": "binary", "update_interval": "1d",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
      }
    ]
  }
}
EOF

  if [[ $WITH_SMARTDNS -eq 1 ]]; then
    _write "${cdir}/04_dns.json" <<EOF
{
  "dns": {
    "servers": [
      { "type": "udp", "tag": "smartdns", "server": "127.0.0.1", "server_port": ${SMARTDNS_PORT} }
    ],
    "strategy": "prefer_ipv4"
  }
}
EOF
  else
    _write "${cdir}/04_dns.json" <<'EOF'
{
  "dns": {
    "servers": [
      { "type": "udp", "tag": "google",     "server": "8.8.8.8" },
      { "type": "udp", "tag": "cloudflare", "server": "1.1.1.1" }
    ],
    "strategy": "prefer_ipv4"
  }
}
EOF
  fi

  if [[ $DRY_RUN -eq 0 ]]; then
    chown -R root:"$SRV_USER" "$CONF_DIR" 2>/dev/null || true
    chmod 750 "$CONF_DIR"; chmod 640 "${cdir}"/*.json
    chown "$SRV_USER":"$SRV_USER" "$WORK_DIR" 2>/dev/null || true
    chmod 750 "$WORK_DIR" 2>/dev/null || true
    log "配置生成完毕: ${cdir}/"
  fi
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
gen_systemd() {
  local after="network.target"
  systemctl list-unit-files 2>/dev/null | grep -q '^smartdns.service' && after="${after} smartdns.service"
  local unit="$UNIT_FILE"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[36m[dry-run]\033[0m 写入 %s（ExecStart=%s run -D %s -C %s）\n' "$unit" "$BIN" "$WORK_DIR" "${CONF_DIR}/${CONF_SUBDIR}"
  else
    cat > "$unit" <<EOF
[Unit]
Description=sing-box service (isongwrt)
Documentation=https://sing-box.sagernet.org
After=${after}

[Service]
User=${SRV_USER}
Group=${SRV_USER}
ExecStart=${BIN} run -D ${WORK_DIR} -C ${CONF_DIR}/${CONF_SUBDIR}
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
WorkingDirectory=${WORK_DIR}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
}

# ---------------------------------------------------------------------------
# smartdns（可选）
# ---------------------------------------------------------------------------
deploy_smartdns() {
  log "部署 smartdns（监听 127.0.0.1:${SMARTDNS_PORT}，规避 53 端口冲突）"
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v smartdns >/dev/null 2>&1; then
    run apt-get install -y -qq smartdns || warn "apt 安装 smartdns 失败，请自行安装后重跑"
  fi

  # 设计：不改动发行版的 /etc/smartdns/smartdns.conf（dpkg conffile，改它升级时会冲突、也丢掉文档注释）。
  #   1) 我们的配置单独放 $SMARTDNS_CONF
  #   2) 通过 $SMARTDNS_ENVFILE（/etc/default/smartdns）里的 SMART_DNS_OPTS="-c <该文件>" 生效
  # 注意：**不能**用 systemd drop-in 的 Environment= 来做（实测过：单元的 EnvironmentFile 优先级更高，
  #       会把 drop-in 的值覆盖成空），所以必须改这个「选项文件」——它本来就是为此存在的。
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[36m[dry-run]\033[0m 写入 %s，并在 %s 设置 SMART_DNS_OPTS="-c %s"，随后重启 smartdns\n' \
      "$SMARTDNS_CONF" "$SMARTDNS_ENVFILE" "$SMARTDNS_CONF"
    return 0
  fi

  install -d -m 0755 "$(dirname "$SMARTDNS_CONF")"
  cat > "$SMARTDNS_CONF" <<EOF
# isongwrt managed —— 本文件由 isongwrt 服务端部署脚本生成
# 发行版的 /etc/smartdns/smartdns.conf 保持原样不动；本文件通过
#   ${SMARTDNS_ENVFILE} 中的 SMART_DNS_OPTS="-c <本文件>" 生效
# 完整选项说明: https://pymumu.github.io/smartdns/config/basic-config/
server-name isongwrt-dns
# 只监听回环 + 非 53 端口：给本机 sing-box 用；避免与 systemd-resolved/dnsmasq 抢 53，也避免变成公网开放解析器
bind 127.0.0.1:${SMARTDNS_PORT}
bind-tcp 127.0.0.1:${SMARTDNS_PORT}
speed-check-mode ping,tcp:80,tcp:443
cache-size 4096
prefetch-domain yes
serve-expired yes
$(for up in $SMARTDNS_UPSTREAMS; do printf 'server %s\n' "$up"; done)
EOF
  chmod 0644 "$SMARTDNS_CONF"

  [[ -f "$SMARTDNS_ENVFILE" ]] || printf '# isongwrt managed\nSMART_DNS_OPTS=\n' > "$SMARTDNS_ENVFILE"
  [[ -f "${SMARTDNS_ENVFILE}.isongwrt-orig" ]] || cp "$SMARTDNS_ENVFILE" "${SMARTDNS_ENVFILE}.isongwrt-orig" 2>/dev/null || true
  if grep -qE '^[[:space:]]*SMART_DNS_OPTS=' "$SMARTDNS_ENVFILE"; then
    warn "覆盖 ${SMARTDNS_ENVFILE} 里已有的 SMART_DNS_OPTS（原值见 ${SMARTDNS_ENVFILE}.isongwrt-orig）"
    sed -i "s|^[[:space:]]*SMART_DNS_OPTS=.*|SMART_DNS_OPTS=\"-c ${SMARTDNS_CONF}\"|" "$SMARTDNS_ENVFILE"
  else
    printf 'SMART_DNS_OPTS="-c %s"\n' "$SMARTDNS_CONF" >> "$SMARTDNS_ENVFILE"
  fi

  # 清理历史版本可能写入的 systemd drop-in（两套机制不能并存）
  if [[ -f /etc/systemd/system/smartdns.service.d/90-isongwrt.conf ]]; then
    rm -f /etc/systemd/system/smartdns.service.d/90-isongwrt.conf
    rmdir /etc/systemd/system/smartdns.service.d 2>/dev/null || true
    warn "已移除旧版 drop-in（改用 ${SMARTDNS_ENVFILE} 注入）"
  fi

  systemctl daemon-reload
  systemctl enable smartdns >/dev/null 2>&1 || true
  systemctl restart smartdns
  sleep 1
  if command -v dig >/dev/null; then
    dig +time=3 +tries=1 @127.0.0.1 -p "${SMARTDNS_PORT}" example.com A >/dev/null 2>&1 \
      && log "smartdns 健康检查通过（127.0.0.1:${SMARTDNS_PORT}，配置 ${SMARTDNS_CONF}）" \
      || warn "smartdns 未响应 dig —— 查 journalctl -u smartdns -n 30（确认 ${SMARTDNS_ENVFILE} 里 SMART_DNS_OPTS 已生效）"
  fi
}

# ---------------------------------------------------------------------------
# 防火墙（可选）
# ---------------------------------------------------------------------------
open_firewall() {
  [[ $OPEN_FIREWALL -eq 1 ]] || return 0
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
    run ufw allow "${LISTEN_PORT}"/tcp
    run ufw allow "${LISTEN_PORT}"/udp
    warn "已放行 ${LISTEN_PORT}/tcp+udp（ufw）——请向用户报告该防火墙变更"
  else
    warn "未检测到启用中的 ufw；请自行确认 ${LISTEN_PORT}/tcp+udp 已放行"
  fi
}

# ---------------------------------------------------------------------------
# 部署记录 / 健康检查
# ---------------------------------------------------------------------------
write_record() {
  [[ $DRY_RUN -eq 1 ]] && { printf '\033[36m[dry-run]\033[0m 写部署记录 %s\n' "$RECORD"; return; }
  install -d -m 0700 "$DATA_DIR"
  local conf_sha bin_sha
  conf_sha="$(cat "${CONF_DIR}"/${CONF_SUBDIR}/*.json | sha256sum | cut -d' ' -f1)"
  bin_sha="$(sha256sum "$BIN" | cut -d' ' -f1)"
  cat > "$RECORD" <<EOF
{
  "action": "installed",
  "version": "${VERSION_TAG:-unknown}",
  "role": "${ROLE}",
  "listen_port": ${LISTEN_PORT},
  "method": "${METHOD}",
  "build": ${BUILD_META_JSON:-{\"source\":\"unknown\"}},
  "binary_sha256": "${bin_sha}",
  "config_sha256": "${conf_sha}",
  "smartdns": $( [[ $WITH_SMARTDNS -eq 1 ]] && echo true || echo false ),
  "smartdns_port": ${SMARTDNS_PORT},
  "installed_at": "$(date -Is)"
}
EOF
  chmod 600 "$RECORD"; log "部署记录: ${RECORD}"
}

do_check_quiet() {
  [[ $DRY_RUN -eq 1 ]] && { printf '\033[36m[dry-run]\033[0m sing-box check -D %s -C %s\n' "$WORK_DIR" "${CONF_DIR}/${CONF_SUBDIR}"; return; }
  "$BIN" check -D "$WORK_DIR" -C "${CONF_DIR}/${CONF_SUBDIR}" \
    || die "sing-box check 未通过（配置见 ${CONF_DIR}/${CONF_SUBDIR}/）"
  log "sing-box check 通过 ✅  版本: $("$BIN" version 2>/dev/null | head -1)"
}

health_check() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  local i; for i in 1 2 3 4 5; do
    ss -tln 2>/dev/null | grep -q ":${LISTEN_PORT} " && break; sleep 1
  done
  ss -tln 2>/dev/null | grep -q ":${LISTEN_PORT} " \
    || die "端口 ${LISTEN_PORT} 未监听 —— 查 journalctl -u sing-box -n 50 --no-pager"
  # 只认 FATAL（后台 rule-set 更新失败会打 ERROR，属噪音，不视为启动失败）
  local fatals
  fatals="$(journalctl -u sing-box --since '-1min' --no-pager 2>/dev/null | grep -c 'FATAL' || true)"
  [[ "${fatals:-0}" -eq 0 ]] \
    && log "健康检查通过（端口 ${LISTEN_PORT} 监听中，无 FATAL）" \
    || die "启动日志出现 FATAL（journalctl -u sing-box -n 50 --no-pager）"
  log "回滚方式: ${BIN}.prev + ${BACKUP_DIR}/；执行 $(basename "$0") rollback"
}

# ---------------------------------------------------------------------------
# 动作
# ---------------------------------------------------------------------------
do_install() {
  preflight; ensure_deps; ensure_user
  if [[ -d "$CONF_DIR" && $DRY_RUN -eq 0 ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"; install -d "$BACKUP_DIR"
    cp -a "$CONF_DIR" "${BACKUP_DIR}/sing-box-conf-${ts}"
    log "已备份既有配置 → ${BACKUP_DIR}/sing-box-conf-${ts}"
  fi
  if [[ -z "$BIN_PATH" ]]; then resolve_version; fi
  install_binary
  gen_configs
  [[ $WITH_SMARTDNS -eq 1 ]] && deploy_smartdns
  do_check_quiet
  if [[ $NO_SERVICE -eq 1 ]]; then
    warn "已指定 --no-service：跳过 systemd（请自行启动：${BIN} run -D ${WORK_DIR} -C ${CONF_DIR}/${CONF_SUBDIR}）"
  else
    gen_systemd
    run systemctl enable sing-box
    run systemctl restart sing-box
    open_firewall
    health_check
  fi
  write_record
  log "完成：服务端 ${VERSION_TAG} 已就绪（端口 ${LISTEN_PORT}，方法 ${METHOD}）"
}

do_upgrade() {
  [[ -x "$BIN" ]] || die "尚未安装（先 install）"
  preflight; ensure_deps; ensure_user; resolve_version
  local cur; cur="$("$BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
  if [[ "$cur" == "$VERSION_TAG" ]]; then log "当前已是 ${VERSION_TAG}，无需升级"; exit 0; fi
  log "升级 ${cur:-?} → ${VERSION_TAG}"
  run cp -a "$BIN" "${BIN}.prev"
  if [[ $DRY_RUN -eq 0 ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"; install -d "$BACKUP_DIR"
    cp -a "$CONF_DIR" "${BACKUP_DIR}/sing-box-conf-pre-${VERSION_TAG}-${ts}"
  fi
  install_binary
  do_check_quiet
  run systemctl restart sing-box
  health_check
  write_record
}

do_rollback() {
  [[ -f "${BIN}.prev" ]] || die "无 ${BIN}.prev 可回滚"
  local latest_conf; latest_conf="$(ls -1dt "${BACKUP_DIR}"/sing-box-conf-* 2>/dev/null | head -1 || true)"
  log "回滚二进制 + 配置 ${latest_conf:-（保留现有配置）}"
  run cp -a "${BIN}.prev" "$BIN"
  [[ -n "$latest_conf" ]] && run cp -a "${latest_conf}/." "${CONF_DIR}/"
  do_check_quiet
  run systemctl restart sing-box
  health_check
}

do_status() {
  echo "== 内核 =="; "$BIN" version 2>/dev/null | head -3 || echo "（未安装）"
  echo "== 服务 =="; systemctl is-active sing-box 2>/dev/null || true
  echo "== 监听 =="; ss -tlnp 2>/dev/null | grep -E "sing-box|:${LISTEN_PORT} " || echo "（无监听）"
  echo "== smartdns =="; systemctl is-active smartdns 2>/dev/null || echo "（未安装/未启用）"
  echo "== 部署记录 =="
  if [[ -f "$RECORD" ]]; then cat "$RECORD"
  elif [[ -f "${LEGACY_DATA_DIR}/deploy-record.json" ]]; then
    echo "（旧 isongwrt-legacy 记录）"; cat "${LEGACY_DATA_DIR}/deploy-record.json"
  else echo "（无记录）"; fi
}

do_uninstall() {
  warn "将停止并移除 sing-box 服务与二进制（配置/密钥保留在 ${CONF_DIR}、${DATA_DIR}）"
  run systemctl disable --now sing-box 2>/dev/null || true
  run rm -f "$UNIT_FILE"
  run systemctl daemon-reload
  run rm -f "$BIN"
  log "已卸载（如需彻底清理：rm -rf ${CONF_DIR} ${DATA_DIR} ${BACKUP_DIR}）"
}

main() {
  parse_args "$@"
  case "$ACTION" in
    install)   do_install ;;
    upgrade)   do_upgrade ;;
    rollback)  do_rollback ;;
    status)    do_status ;;
    check)     do_check_quiet ;;
    uninstall) do_uninstall ;;
    *) usage ;;
  esac
}
main "$@"
