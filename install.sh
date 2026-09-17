#!/bin/sh
# isongwrt 一键安装（优先 feed，失败自动回退 GitHub Releases）
# 用法：wget -O - https://raw.githubusercontent.com/c000127/isongwrt/main/install.sh | sh
set -e

REPO="c000127/isongwrt"
PKG="luci-app-isongwrt"

if [ ! -x /bin/opkg ] && [ ! -x /usr/bin/apk ]; then
	echo "错误：未找到 opkg 或 apk（仅支持 OpenWrt/iStoreOS）" >&2
	exit 1
fi

fetch() { # <url> <outfile>
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$2" "$1"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$2" "$1"
	else
		wget -q -O "$2" "$1"
	fi
}

install_from_feed() {
	feed_script=/tmp/isongwrt-feed.sh
	fetch "https://raw.githubusercontent.com/$REPO/main/feed.sh" "$feed_script" 2>/dev/null || return 1
	sh "$feed_script" >/dev/null 2>&1 || return 1
	if [ -x /bin/opkg ]; then
		opkg install "$PKG"
	else
		apk add "$PKG" 2>/dev/null || apk --allow-untrusted add "$PKG"
	fi
}

install_from_release() {
	echo "feed 安装失败，回退到 GitHub Releases..."
	api="https://api.github.com/repos/$REPO/releases"
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
