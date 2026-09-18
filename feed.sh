#!/bin/sh
# isongwrt feed setup (OpenWrt 24.10 opkg / 25.x apk)
# Usage: wget -O - https://raw.githubusercontent.com/c000127/isongwrt/main/feed.sh | sh
# --source (or ISONGWRT_SOURCE):
#   mirror  jsDelivr -> fastly.jsdelivr -> GitHub (default)
#   direct  raw.githubusercontent -> jsDelivr
#   custom  ISONGWRT_FEED_BASE (one or more, space separated)
# Piped runs never prompt; they use the default or the environment variable.
set -e

SOURCE="${ISONGWRT_SOURCE:-}"
for arg in "$@"; do
	case "$arg" in
		--source=*) SOURCE="${arg#--source=}" ;;
		-d|--direct) SOURCE="direct" ;;
		-m|--mirror) SOURCE="mirror" ;;
	esac
done

if [ ! -x /bin/opkg ] && [ ! -x /usr/bin/apk ]; then
	echo "error: neither opkg nor apk found (OpenWrt/iStoreOS only)" >&2
	exit 1
fi

. /etc/openwrt_release 2>/dev/null || true
arch="${DISTRIB_ARCH:-$(uname -m)}"
case "${DISTRIB_RELEASE:-}" in
	*24.10*) branch="openwrt-24.10" ;;
	*25.12*) branch="openwrt-25.12" ;;
	*)
		echo "unsupported release: ${DISTRIB_RELEASE:-unknown} (install.sh can install from Releases)" >&2
		exit 1
		;;
esac

fetch() { # <url> <outfile>: try curl, then uclient-fetch, then wget
	if command -v curl >/dev/null 2>&1 && curl -fsSL --max-time 60 -o "$2" "$1"; then return 0; fi
	if command -v uclient-fetch >/dev/null 2>&1 && uclient-fetch -q -O "$2" "$1"; then return 0; fi
	if command -v wget >/dev/null 2>&1 && wget -q -T 60 -O "$2" "$1"; then return 0; fi
	return 1
}

JSD="https://cdn.jsdelivr.net/gh/c000127/isongwrt@feed"
JSD2="https://fastly.jsdelivr.net/gh/c000127/isongwrt@feed"
RAW="https://raw.githubusercontent.com/c000127/isongwrt/feed"

# interactive selection: only when /dev/tty is readable
# Interactive selection. It runs inside a subshell on purpose: on hosts without a
# usable /dev/tty (pipe, container, cron) the redirection fails inside that subshell
# only -- dash treats such a failure as fatal, so it must never happen in the main
# shell. An empty answer keeps the default source.
if [ -z "$SOURCE" ]; then
	_ans=$( { printf 'Select feed source:\n  1) jsDelivr mirror (default)\n  2) GitHub direct\n  3) custom (ISONGWRT_FEED_BASE)\nNumber [1]: ' > /dev/tty; read -r _a < /dev/tty && printf '%s' "$_a"; } 2>/dev/null ) || _ans=""
	case "$_ans" in 2) SOURCE=direct ;; 3) SOURCE=custom ;; *) SOURCE=mirror ;; esac
fi
fi
SOURCE="${SOURCE:-mirror}"

case "$SOURCE" in
	direct) FEED_BASES="$RAW $JSD $JSD2" ;;
	custom) FEED_BASES="${ISONGWRT_FEED_BASE:-$JSD}" ;;
	*)      FEED_BASES="${ISONGWRT_FEED_BASE:-$JSD $JSD2 $RAW}" ;;
esac
echo "Source: $SOURCE -> $FEED_BASES"

feed_url=""
for base in $FEED_BASES; do
	candidate="$base/$branch/$arch/isongwrt"
	# probe whether the index is reachable
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
[ -n "$feed_url" ] || { echo "error: no reachable feed ($FEED_BASES)" >&2; exit 1; }

feed_root="${feed_url%/$branch/$arch/isongwrt}"
if [ -x /bin/opkg ]; then
	# public key, when the feed is signed
	if fetch "$feed_root/key-build.pub" /tmp/key-build.pub 2>/dev/null; then
		opkg-key add /tmp/key-build.pub 2>/dev/null || true
		rm -f /tmp/key-build.pub
	fi
	grep -q isongwrt /etc/opkg/customfeeds.conf 2>/dev/null && sed -i '/isongwrt/d' /etc/opkg/customfeeds.conf
	echo "src/gz isongwrt $feed_url" >> /etc/opkg/customfeeds.conf
	echo "Feed added: $feed_url"
	opkg update
else
	if fetch "$feed_root/public-key.pem" /etc/apk/keys/isongwrt.pem 2>/dev/null; then
		echo "Installed feed public key /etc/apk/keys/isongwrt.pem"
	fi
	mkdir -p /etc/apk/repositories.d
	grep -q isongwrt /etc/apk/repositories.d/customfeeds.list 2>/dev/null && sed -i '/isongwrt/d' /etc/apk/repositories.d/customfeeds.list
	echo "$feed_url/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
	echo "Feed added: $feed_url/packages.adb"
	# unsigned feed needs --allow-untrusted; a plain update works once the key is installed
	apk update 2>/dev/null || apk --allow-untrusted update
fi

echo "Done. Install with: opkg install luci-app-isongwrt  |  apk add luci-app-isongwrt"
