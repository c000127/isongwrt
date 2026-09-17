#!/bin/sh
# isongwrt feed 添加脚本（OpenWrt 24.10 opkg / 25.x apk）
# 用法：wget -O - https://raw.githubusercontent.com/c000127/isongwrt/main/feed.sh | sh
# 可选环境变量：ISONGWRT_FEED_BASE 覆盖 feed 根地址（默认 jsDelivr → fastly → raw；raw 在部分网络不可达）
set -e

if [ ! -x /bin/opkg ] && [ ! -x /usr/bin/apk ]; then
	echo "错误：未找到 opkg 或 apk（仅支持 OpenWrt/iStoreOS）" >&2
	exit 1
fi

. /etc/openwrt_release 2>/dev/null || true
arch="${DISTRIB_ARCH:-$(uname -m)}"
case "${DISTRIB_RELEASE:-}" in
	*24.10*) branch="openwrt-24.10" ;;
	*25.12*) branch="openwrt-25.12" ;;
	*)
		echo "暂不支持的发行版: ${DISTRIB_RELEASE:-unknown}（可用 install.sh 从 Releases 安装）" >&2
		exit 1
		;;
esac

fetch() { # <url> <outfile>：依次尝试 curl / uclient-fetch / wget（有的系统 uclient-fetch 缺 libustream）
	if command -v curl >/dev/null 2>&1 && curl -fsSL --max-time 60 -o "$2" "$1"; then return 0; fi
	if command -v uclient-fetch >/dev/null 2>&1 && uclient-fetch -q -O "$2" "$1"; then return 0; fi
	if command -v wget >/dev/null 2>&1 && wget -q -T 60 -O "$2" "$1"; then return 0; fi
	return 1
}

FEED_BASES="${ISONGWRT_FEED_BASE:-https://cdn.jsdelivr.net/gh/c000127/isongwrt@feed https://fastly.jsdelivr.net/gh/c000127/isongwrt@feed https://raw.githubusercontent.com/c000127/isongwrt/feed}"

feed_url=""
for base in $FEED_BASES; do
	candidate="$base/$branch/$arch/isongwrt"
	# 探测索引是否可下载
	if [ -x /bin/opkg ]; then
		probe="$candidate/Packages.gz"
	else
		probe="$candidate/packages.adb"
	fi
	if fetch "$probe" /tmp/.isongwrt-probe 2>/dev/null; then
		feed_url="$candidate"
		rm -f /tmp/.isongwrt-probe
		break
	fi
done
[ -n "$feed_url" ] || { echo "错误：无法访问 feed（$FEED_BASES）" >&2; exit 1; }

feed_root="${feed_url%/$branch/$arch/isongwrt}"
if [ -x /bin/opkg ]; then
	# 公钥（若 feed 提供签名）
	if fetch "$feed_root/key-build.pub" /tmp/key-build.pub 2>/dev/null; then
		opkg-key add /tmp/key-build.pub 2>/dev/null || true
		rm -f /tmp/key-build.pub
	fi
	grep -q isongwrt /etc/opkg/customfeeds.conf 2>/dev/null && sed -i '/isongwrt/d' /etc/opkg/customfeeds.conf
	echo "src/gz isongwrt $feed_url" >> /etc/opkg/customfeeds.conf
	echo "已添加 feed：$feed_url"
	opkg update
else
	if fetch "$feed_root/public-key.pem" /etc/apk/keys/isongwrt.pem 2>/dev/null; then
		echo "已安装 feed 公钥 /etc/apk/keys/isongwrt.pem"
	fi
	mkdir -p /etc/apk/repositories.d
	grep -q isongwrt /etc/apk/repositories.d/customfeeds.list 2>/dev/null && sed -i '/isongwrt/d' /etc/apk/repositories.d/customfeeds.list
	echo "$feed_url/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
	echo "已添加 feed：$feed_url/packages.adb"
	# 未签名 feed 需要 --allow-untrusted；已装公钥时普通 update 即可
	apk update 2>/dev/null || apk --allow-untrusted update
fi

echo "完成。安装：opkg install luci-app-isongwrt  或  apk add luci-app-isongwrt"
