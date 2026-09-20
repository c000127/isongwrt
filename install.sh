#!/bin/sh
# isongwrt installer: try the feed first, fall back to GitHub Releases.
# Usage:
#   wget -O - https://cdn.jsdelivr.net/gh/c000127/isongwrt@main/install.sh | sh
#   ... | sh -s -- --source=direct        # GitHub first
#   ... | sh -s -- --source=custom        # custom source (ISONGWRT_FEED_BASE / ISONGWRT_GH_PROXY)
# --source: mirror (default) | direct | custom
#
# Integrity: a package downloaded from Releases is only installed after its sha256
# matches the release's own SHA256SUMS.txt asset; a mismatch aborts before install.
# The feed path instead relies on the feed itself (opkg verifies the usign-signed
# index and packages; the 25.12 apk index is unsigned, hence --allow-untrusted).
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

# Interactive selection. It runs inside a subshell on purpose: on hosts without a
# usable /dev/tty (pipe, container, cron) the redirection fails inside that subshell
# only -- dash treats such a failure as fatal, so it must never happen in the main
# shell. An empty answer keeps the default source.
if [ -z "$SOURCE" ]; then
	_ans=$( { printf 'Select download source:\n  1) jsDelivr mirror (default)\n  2) GitHub direct\n  3) custom (ISONGWRT_FEED_BASE / ISONGWRT_GH_PROXY)\nNumber [1]: ' > /dev/tty; read -r _a < /dev/tty && printf '%s' "$_a"; } 2>/dev/null ) || _ans=""
	case "$_ans" in 2) SOURCE=direct ;; 3) SOURCE=custom ;; *) SOURCE=mirror ;; esac
fi
SOURCE="${SOURCE:-mirror}"
GH_PROXY="${ISONGWRT_GH_PROXY:-}"
echo "Source: $SOURCE${GH_PROXY:+ (prefix $GH_PROXY)}"

REPO="c000127/isongwrt"
PKG="luci-app-isongwrt"

fetch() { # <url> <outfile>: try curl, then uclient-fetch, then wget
	if command -v curl >/dev/null 2>&1 && curl -fsSL --max-time 60 -o "$2" "$1"; then return 0; fi
	if command -v uclient-fetch >/dev/null 2>&1 && uclient-fetch -q -O "$2" "$1"; then return 0; fi
	if command -v wget >/dev/null 2>&1 && wget -q -T 60 -O "$2" "$1"; then return 0; fi
	return 1
}

sha256_of() { # <file> -> hex digest on stdout
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
		return
	fi
	if command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$1" | awk '{print $NF}'
		return
	fi
	return 1
}

verify_sha256() { # <file> <sums file> : abort the install when the digest does not match
	_v_file="$1"; _v_sums="$2"; _v_name="${_v_file##*/}"
	# The published SHA256SUMS.txt may record build paths (./bin/packages/<arch>/isongwrt/x.ipk)
	# or plain basenames, so match on the basename of the last field.
	_v_want="$(awk -v n="$_v_name" '{ p=$NF; sub(/^\.\//, "", p); sub(/^.*\//, "", p); if (p == n) { print $1; exit } }' "$_v_sums")"
	if [ -z "$_v_want" ]; then
		echo "error: ${_v_name} is not listed in SHA256SUMS.txt -- refusing to install an unverified package" >&2
		return 1
	fi
	_v_got="$(sha256_of "$_v_file")" || {
		echo "error: no sha256 tool available (need sha256sum or openssl)" >&2
		return 1
	}
	echo "checksum: ${_v_name}"
	echo "  expected: ${_v_want}"
	echo "  actual:   ${_v_got}"
	if [ "$_v_want" != "$_v_got" ]; then
		echo "error: sha256 mismatch for ${_v_name} -- aborting, nothing was installed" >&2
		return 1
	fi
	echo "checksum OK"
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
	# The API lists releases newest first: the first matching asset and the first
	# SHA256SUMS.txt belong to the same (newest) release.
	tag=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$list" | head -1)
	if [ -x /bin/opkg ]; then
		url=$(sed -n 's/.*"browser_download_url": *"\([^"]*\.ipk\)".*/\1/p' "$list" | head -1)
	else
		url=$(sed -n 's/.*"browser_download_url": *"\([^"]*\.apk\)".*/\1/p' "$list" | head -1)
	fi
	sums_url=$(sed -n 's/.*"browser_download_url": *"\([^"]*SHA256SUMS\.txt\)".*/\1/p' "$list" | head -1)
	[ -n "$url" ] || { echo "error: no package found in Releases" >&2; return 1; }
	[ -n "$sums_url" ] || { echo "error: the release publishes no SHA256SUMS.txt -- refusing to install an unverified package" >&2; return 1; }
	echo "Release: ${tag:-unknown}"
	echo "Downloading: $url"
	pkg=/tmp/isongwrt-pkg
	fetch "$url" "$pkg" || return 1
	sums=/tmp/isongwrt-sha256sums.txt
	if ! fetch "$sums_url" "$sums"; then
		echo "error: cannot download SHA256SUMS.txt ($sums_url)" >&2
		return 1
	fi
	verify_sha256 "$pkg" "$sums" || return 1
	if [ -x /bin/opkg ]; then
		opkg install "$pkg"
	else
		apk add --allow-untrusted --force-overwrite "$pkg"
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
