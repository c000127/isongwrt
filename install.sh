#!/bin/sh
# isongwrt installer: try the feed first, fall back to GitHub Releases.
# Usage:
#   wget -O - https://cdn.jsdelivr.net/gh/c000127/isongwrt@main/install.sh | sh
#   ... | sh -s -- --source=direct        # GitHub first
#   ... | sh -s -- --source=custom        # custom source (ISONGWRT_FEED_BASE / ISONGWRT_GH_PROXY)
# --source: mirror (default) | direct | custom
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
	printf 'Select download source:\n  1) jsDelivr mirror (default)\n  2) GitHub direct\n  3) custom (ISONGWRT_FEED_BASE / ISONGWRT_GH_PROXY)\nNumber [1]: ' > /dev/tty
	if read -r _ans < /dev/tty 2>/dev/null; then
		case "$_ans" in 2) SOURCE=direct ;; 3) SOURCE=custom ;; *) SOURCE=mirror ;; esac
	fi
fi
SOURCE="${SOURCE:-mirror}"
GH_PROXY="${ISONGWRT_GH_PROXY:-}"
echo "Source: $SOURCE${GH_PROXY:+ (prefix $GH_PROXY)}"

REPO="c000127/isongwrt"
PKG="luci-app-isongwrt"

if [ ! -x /bin/opkg ] && [ ! -x /usr/bin/apk ]; then
	echo "error: neither opkg nor apk found (OpenWrt/iStoreOS only)" >&2
	exit 1
fi

fetch() { # <url> <outfile>: try curl, then uclient-fetch, then wget
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
	echo "feed install failed, falling back to GitHub Releases"
	api="${GH_PROXY}https://api.github.com/repos/$REPO/releases"
	list=/tmp/isongwrt-releases.json
	if ! fetch "$api" "$list" 2>/dev/null; then
		echo "error: cannot reach the GitHub API; download the package from Releases manually" >&2
		return 1
	fi
	if [ -x /bin/opkg ]; then
		url=$(sed -n 's/.*"browser_download_url": *"\([^"]*\.ipk\)".*/\1/p' "$list" | head -1)
	else
		url=$(sed -n 's/.*"browser_download_url": *"\([^"]*\.apk\)".*/\1/p' "$list" | head -1)
	fi
	[ -n "$url" ] || { echo "error: no package found in Releases" >&2; return 1; }
	echo "Downloading: $url"
	fetch "$url" /tmp/isongwrt-pkg || return 1
	if [ -x /bin/opkg ]; then
		opkg install /tmp/isongwrt-pkg
	else
		apk add --allow-untrusted --force-overwrite /tmp/isongwrt-pkg
	fi
}

if install_from_feed; then
	echo "Installed $PKG from the feed"
else
	install_from_release
	echo "Installed $PKG from Releases"
fi

echo
echo "Done. Reload LuCI (or run /etc/init.d/uhttpd restart); menu: Services -> isongwrt"
