#!/bin/sh
# isongwrt 一键安装（优先 feed，失败自动回退 GitHub Releases）
# 用法：
#   wget -O - https://cdn.jsdelivr.net/gh/c000127/isongwrt@main/install.sh | sh
#   ... | sh -s -- --source=direct        # GitHub 直连优先
#   ... | sh -s -- --source=custom        # 自定义源（配 ISONGWRT_FEED_BASE / ISONGWRT_GH_PROXY）
# 源选择：mirror（默认，jsDelivr 优先）/ direct（GitHub 直连优先）/ custom
set -e

SOURCE="${ISONGWRT_SOURCE:-}"
for arg in "$@"; do
	case "$arg" in
		--source=*) SOURCE="${arg#--source=}" ;;
		-d|--direct) SOURCE="direct" ;;
		-m|--mirror) SOURCE="mirror" ;;
	esac
done
if [ -z "$SOURCE" ] && [ -r /dev/tty ]; then
	printf '请选择下载源：\n  1) 镜像优先 jsDelivr（推荐，国内可用）\n  2) GitHub 直连\n  3) 自定义（ISONGWRT_FEED_BASE / ISONGWRT_GH_PROXY）\n输入序号 [1]: ' > /dev/tty
	if read -r _ans < /dev/tty 2>/dev/null; then
		case "$_ans" in 2) SOURCE=direct ;; 3) SOURCE=custom ;; *) SOURCE=mirror ;; esac
	fi
fi
SOURCE="${SOURCE:-mirror}"
GH_PROXY="${ISONGWRT_GH_PROXY:-}"
echo "下载源：$SOURCE${GH_PROXY:+（GitHub 加速前缀 $GH_PROXY）}"

REPO="c000127/isongwrt"
PKG="luci-app-isongwrt"

if [ ! -x /bin/opkg ] && [ ! -x /usr/bin/apk ]; then
	echo "错误：未找到 opkg 或 apk（仅支持 OpenWrt/iStoreOS）" >&2
	exit 1
fi

fetch() { # <url> <outfile>：依次尝试 curl / uclient-fetch / wget（有的系统 uclient-fetch 缺 libustream）
	if command -v curl >/dev/null 2>&1 && curl -fsSL --max-time 60 -o "$2" "$1"; then return 0; fi
	if command -v uclient-fetch >/dev/null 2>&1 && uclient-fetch -q -O "$2" "$1"; then return 0; fi
	if command -v wget >/dev/null 2>&1 && wget -q -T 60 -O "$2" "$1"; then return 0; fi
	return 1
}

install_from_feed() {
	feed_script=/tmp/isongwrt-feed.sh
	JSD="https://cdn.jsdelivr.net/gh/$REPO@main"
	JSD2="https://fastly.jsdelivr.net/gh/$REPO@main"
	RAW="https://raw.githubusercontent.com/$REPO/main"
	case "$SOURCE" in
		direct) SCRIPT_BASES="$RAW $JSD $JSD2" ;;
		custom) SCRIPT_BASES="${ISONGWRT_FEED_BASE:-$JSD}" ;;
		*)      SCRIPT_BASES="$JSD $JSD2 $RAW" ;;
	esac
	for base in $SCRIPT_BASES; do
		fetch "$base/feed.sh" "$feed_script" 2>/dev/null && break
	done
	[ -s "$feed_script" ] || return 1
	sh "$feed_script" --source="$SOURCE" >/dev/null 2>&1 || return 1
	if [ -x /bin/opkg ]; then
		opkg install "$PKG"
	else
		apk add "$PKG" 2>/dev/null || apk --allow-untrusted add "$PKG"
	fi
}

install_from_release() {
	echo "feed 安装失败，回退到 GitHub Releases..."
	api="${GH_PROXY}https://api.github.com/repos/$REPO/releases"
	list=/tmp/isongwrt-releases.json
	if ! fetch "$api" "$list" 2>/dev/null; then
		echo "错误：无法访问 GitHub API，请手动从 Releases 下载安装包" >&2
		return 1
	fi
	if [ -x /bin/opkg ]; then
		url=$(sed -n 's/.*"browser_download_url": *"\([^"]*\.ipk\)".*/\1/p' "$list" | head -1)
	else
		url=$(sed -n 's/.*"browser_download_url": *"\([^"]*\.apk\)".*/\1/p' "$list" | head -1)
	fi
	[ -n "$url" ] || { echo "错误：Releases 中未找到安装包" >&2; return 1; }
	echo "下载：$url"
	fetch "$url" /tmp/isongwrt-pkg || return 1
	if [ -x /bin/opkg ]; then
		opkg install /tmp/isongwrt-pkg
	else
		apk add --allow-untrusted --force-overwrite /tmp/isongwrt-pkg
	fi
}

if install_from_feed; then
	echo "已通过 feed 安装 $PKG"
else
	install_from_release
	echo "已通过 Releases 安装 $PKG"
fi

echo
echo "安装完成。请刷新 LuCI（或执行 /etc/init.d/uhttpd restart），菜单：服务 → isongwrt"
