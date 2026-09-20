#!/usr/bin/env bash
# ============================================================================
# isongwrt -- one-shot deployment for a sing-box server (landing host)
#
#   Usage (run as root on the target server):
#     singbox-deploy.sh install   [--listen-port 15835] [--with-smartdns] [--no-service]
#                                 [--smartdns-port 6053] [--version v1.15.0-alpha.6]
#                                 [--source auto|direct|mirror] [--binary /path/to/sing-box]
#                                 [--checksum <sha256>] [--allow-unverified]
#                                 [--no-ntp] [--open-firewall] [--dry-run]
#     singbox-deploy.sh upgrade   [same options]
#     singbox-deploy.sh rollback
#     singbox-deploy.sh status | check | uninstall
#
#   Design:
#     * Core: the official Release binary (SagerNet/sing-box) is installed
#             as-is at /usr/local/bin/sing-box -- never renamed, repacked, rebuilt
#     * Version: newest official tag by default (alpha/rc/stable), --version pins it
#     * Protocol: shadowsocks-2022 / 2022-blake3-aes-256-gcm, 32-byte base64 key,
#             multiplex (h2mux) + padding to match the clients; no TLS anywhere
#     * Integrity: every downloaded asset is checked against the official release
#             checksums, the GitHub release asset digest or a pinned sha256 table;
#             a mismatch aborts before the binary is installed or executed
#     * Idempotent: re-running is safe; an existing ss2022 key is reused (never rotated)
#     * Backups: config and binary are copied before any change; `rollback` restores
#             the newest binary backup plus the newest config backup
#     * Verify: built-in `sing-box check`, then a health check anchored to this
#             specific service start (MainPID + ExecMainStartTimestamp)
#     * Record: version + binary/config sha256 -> /var/lib/isongwrt/deploy-record.json
#     * Secrets: local files on the server only (0600); never printed, never in the repo
#     * Downloads: --source picks direct GitHub or an accelerator prefix; only https
#             prefixes are accepted, and every use of one is announced loudly
# ============================================================================
set -euo pipefail

# ---------- defaults ----------
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
WITH_NTP=1                # built-in NTP client on by default (--no-ntp disables it)
NTP_SERVER="${ISONGWRT_NTP_SERVER:-pool.ntp.org}"
NTP_PORT="${ISONGWRT_NTP_PORT:-123}"
NTP_INTERVAL="${ISONGWRT_NTP_INTERVAL:-30m}"
NTP_WRITE_SYSTEM=0        # 1 = also write the corrected time back (needs CAP_SYS_TIME)
SOURCE="${ISONGWRT_SOURCE:-auto}"          # auto | direct | mirror
GH_PROXY="${ISONGWRT_GH_PROXY:-https://ghfast.top/}"
PIN_CHECKSUM="${ISONGWRT_CHECKSUM:-}"      # expected sha256 of the downloaded asset
ALLOW_UNVERIFIED=0                         # 1 = proceed without any checksum (loud warning)
MIRROR_USED=0                              # 1 = at least one download went through GH_PROXY
MIRROR_NOTICE_SHOWN=0
SHA_WANT=""                                # digest resolved by resolve_sha256
SHA_SOURCE=""                              # where that digest came from
GH_REPO="SagerNet/sing-box"
SRV_USER="${ISONGWRT_SRV_USER:-sing-box}"   # service account, created when missing
SRV_GROUP="${ISONGWRT_SRV_GROUP:-$SRV_USER}" # service group, created when missing
# Paths can be overridden by environment variables (sandbox tests, custom layouts)
BIN="${ISONGWRT_BIN:-/usr/local/bin/sing-box}"          # official name, never renamed
CONF_DIR="${ISONGWRT_CONF_DIR:-/etc/sing-box}"          # config root, root-owned
CONF_SUBDIR="conf"
# The working directory (-D) holds runtime state (cache.db) and must stay writable
# by the service, while CONF_DIR itself is read-only to it.
WORK_DIR="${ISONGWRT_WORK_DIR:-/var/lib/sing-box}"
DATA_DIR="${ISONGWRT_DATA_DIR:-/var/lib/isongwrt}"
# Read-only fallbacks for hosts deployed with an earlier (pre-isongwrt) layout.
LEGACY_DATA_DIR="${ISONGWRT_LEGACY_DATA_DIR:-/var/lib/isongwrt-legacy}"
LEGACY_BACKUP_DIR="${ISONGWRT_LEGACY_BACKUP_DIR:-/var/backups/isongwrt-legacy}"
BACKUP_DIR="${ISONGWRT_BACKUP_DIR:-/var/backups/isongwrt}"
SMARTDNS_CONF="${ISONGWRT_SMARTDNS_CONF:-/etc/smartdns/isongwrt.conf}"
SMARTDNS_ENVFILE="${ISONGWRT_SMARTDNS_ENVFILE:-/etc/default/smartdns}"
UNIT_FILE="${ISONGWRT_UNIT_FILE:-/etc/systemd/system/sing-box.service}"
RECORD="${DATA_DIR}/deploy-record.json"
HISTORY="${DATA_DIR}/deploy-history.log"
PASSWORD_FILE="${DATA_DIR}/ss2022.password"
ACTION="install"
BUILD_META_JSON=""
VERSION_TAG=""                             # set by resolve_version / install_binary
ARCH_TAG=""                                # set by preflight

log()  { printf '\033[32m[isongwrt]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[isongwrt]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[isongwrt] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '\033[36m[dry-run]\033[0m %s\n' "$*"; else "$@"; fi; }

usage() {
  cat <<'USAGE'
isongwrt server deployment -- installs and manages a sing-box server.

Usage: bash singbox-deploy.sh <action> [options]

Actions:
  install      install or re-install (idempotent; an existing key is reused)
  upgrade      install the newest release (or the --version one) over an existing install
  rollback     restore the newest binary backup and the newest config backup
  status       show kernel version, service state, listeners and the deploy record
  check        run `sing-box check` only
  uninstall    stop and remove the service + binary (config and key are kept)

Options:
  --role NAME                  RECORDED ONLY: no role-specific config template exists
                               yet, the generated profile is always the landing one
                               (default: landing)
  --listen-port N              ss2022 port, TCP + UDP (default: 15835)
  --version vX.Y.Z[-pre.N]     pin the release (default: newest official tag)
  --source auto|direct|mirror  download path (default: auto = direct, then the prefix)
  --gh-proxy URL               https prefix for `mirror` / the auto fallback
                               (default: https://ghfast.top/ ; https:// is enforced)
  --checksum SHA256            expected sha256 of the release asset (64 hex chars)
  --allow-unverified           install even when no checksum can be obtained (unsafe)
  --binary PATH                use a local binary instead of downloading one
  --with-smartdns              deploy smartdns on 127.0.0.1:6053
  --smartdns-port N            smartdns port (default: 6053)
  --smartdns-upstreams "LIST"  smartdns upstream servers
  --with-ntp                   built-in NTP client (on by default)
  --no-ntp                     disable the NTP client and remove 05_ntp.json
  --ntp-server / --ntp-port / --ntp-interval
                               NTP settings (default: pool.ntp.org / 123 / 30m)
  --ntp-write-system           also set the system clock (adds CAP_SYS_TIME)
  --open-firewall              allow the port in ufw when ufw is active
  --no-service                 write config only; do not touch systemd
  --dry-run                    print the plan, change nothing
  -h, --help                   this help
USAGE
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
      --checksum) PIN_CHECKSUM="$2"; shift 2 ;;
      --allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
      --open-firewall) OPEN_FIREWALL=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --no-service) NO_SERVICE=1; shift ;;
      --with-ntp) WITH_NTP=1; shift ;;          # already the default, accepted explicitly
      --no-ntp) WITH_NTP=0; shift ;;
      --ntp-server) NTP_SERVER="$2"; shift 2 ;;
      --ntp-port) NTP_PORT="$2"; shift 2 ;;
      --ntp-interval) NTP_INTERVAL="$2"; shift 2 ;;
      --ntp-write-system) NTP_WRITE_SYSTEM=1; WITH_NTP=1; shift ;;
      --help|-h) usage ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done
  case "$SOURCE" in auto|direct|mirror) ;; *) die "--source accepts only auto|direct|mirror" ;; esac
  if [[ -n "$PIN_CHECKSUM" ]]; then
    PIN_CHECKSUM="${PIN_CHECKSUM,,}"
    [[ "$PIN_CHECKSUM" =~ ^[0-9a-f]{64}$ ]] || die "--checksum needs a 64-character hex sha256"
  fi
  case "$ROLE" in
    landing) ;;
    *) warn "--role ${ROLE}: recorded in the deploy record only, the generated config is still the landing profile" ;;
  esac
  check_proxy
}

# Only https prefixes are accepted: an accelerator on plain http:// would let anyone
# on the path replace the binary (the checksum catches it, but never send it there).
check_proxy() {
  if [[ -z "$GH_PROXY" ]]; then
    [[ "$SOURCE" == "mirror" ]] && die "--source mirror needs --gh-proxy <https prefix>"
    return 0
  fi
  case "$GH_PROXY" in
    https://*) ;;
    http://*)  die "--gh-proxy: plain http:// is refused, use https:// (third-party prefix)" ;;
    *://*)     die "--gh-proxy: only https:// prefixes are supported" ;;
    *)         GH_PROXY="https://${GH_PROXY}" ;;
  esac
  GH_PROXY="${GH_PROXY%/}/"
  return 0
}

# ---------------------------------------------------------------------------
# Downloads (direct / accelerator prefix / automatic fallback)
# ---------------------------------------------------------------------------
mirror_notice() {
  [[ $MIRROR_NOTICE_SHOWN -eq 1 ]] && return 0
  MIRROR_NOTICE_SHOWN=1
  warn "######################################################################"
  warn "# THIRD-PARTY MIRROR IN USE: downloads go through ${GH_PROXY}"
  warn "# ${1}"
  warn "# This host is not GitHub: the content is only trusted because the"
  warn "# official checksum is verified before the binary is installed or run."
  warn "# Prefer --source direct (or --binary) on production hosts."
  warn "######################################################################"
  return 0
}

dl() { # dl <url> <dest>
  local url="$1" dest="$2"
  case "$SOURCE" in
    direct) curl -fSL --retry 2 --connect-timeout 15 -o "$dest" "$url" ;;
    mirror)
      mirror_notice "--source mirror was requested explicitly."
      MIRROR_USED=1
      curl -fSL --retry 2 --connect-timeout 15 -o "$dest" "${GH_PROXY}${url}" ;;
    auto)
      if curl -fSL --retry 1 --connect-timeout 10 -o "$dest" "$url" 2>/dev/null; then
        return 0
      fi
      [[ -n "$GH_PROXY" ]] || die "direct download failed and no --gh-proxy prefix is configured: ${url}"
      mirror_notice "Direct GitHub access failed, so the prefix is used instead."
      MIRROR_USED=1
      curl -fSL --retry 2 --connect-timeout 15 -o "$dest" "${GH_PROXY}${url}" ;;
  esac
}

resolve_version() {
  if [[ -n "$PIN_VERSION" ]]; then VERSION_TAG="$PIN_VERSION"; log "target version (pinned): ${VERSION_TAG}"; return 0; fi
  local tmp; tmp="$(mktemp)"
  dl "https://github.com/${GH_REPO}/releases.atom" "$tmp" >/dev/null 2>&1 \
    || die "cannot fetch the release list (try --source mirror --gh-proxy <prefix>, or pin --version)"
  VERSION_TAG="$(sed -n 's#.*<id>tag:github.com,2008:Repository/[0-9]*/\(v[^<]*\)</id>.*#\1#p' "$tmp" \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  rm -f "$tmp"
  [[ -n "$VERSION_TAG" ]] || die "cannot parse the release list (unexpected response)"
  log "target version (newest official): ${VERSION_TAG}"
}

# ---------------------------------------------------------------------------
# Integrity: official checksums, GitHub release asset digest, pinned table
# ---------------------------------------------------------------------------
sha256_of() { # <file> -> hex digest
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    return 1
  fi
}

fetch_text() { # <url> <dest> : best-effort download, never fatal
  local url="$1" dest="$2"
  dl "$url" "$dest" >/dev/null 2>&1 || return 1
  [[ -s "$dest" ]] || return 1
  return 0
}

sums_entry() { # <sums file> <basename> -> digest (paths or bare names both work)
  awk -v n="$2" '{ p=$NF; sub(/^\.\//, "", p); sub(/^.*\//, "", p); if (p == n) { print $1; exit } }' "$1"
}

# sha256 of the assets this script has itself verified, used only when neither the
# upstream checksums file nor the GitHub API digest can be reached. Add new releases
# here as they are validated (digests come from the release metadata / the API).
pinned_sha256() { # <asset> -> digest
  case "$1" in
    sing-box-1.15.0-alpha.6-linux-amd64-glibc.tar.gz) echo 3b795e275143de3b0eb04fcf67ce7316a462f2c5a3c5b08d44052c136d265cee ;;
    sing-box-1.15.0-alpha.6-linux-amd64.tar.gz)       echo e19c5e3961ae707d762dc3e6236186c33f0aaf91130567078e1b2af148cda0ae ;;
    sing-box-1.15.0-alpha.6-linux-arm64-glibc.tar.gz) echo 4041e8ce15e00555ae9ac4655f3cb2237ba4433050fefb5f4eea1709fe4b06c9 ;;
    sing-box-1.15.0-alpha.6-linux-arm64.tar.gz)       echo ee75787073fe51b9b3c6987ded36198eb1b77a771447b0c287dde622039245b4 ;;
    sing-box-1.15.0-alpha.5-linux-amd64-glibc.tar.gz) echo 8c580d58e795593481928fb5fe90b00b037b63d9fab1e794a02c1fe07d05a29c ;;
    sing-box-1.15.0-alpha.5-linux-amd64.tar.gz)       echo 7ce0d1dd3305c60d573a2fe89fc5c5453871e240afe5602afe0ce88edfbf316d ;;
    sing-box-1.15.0-alpha.5-linux-arm64-glibc.tar.gz) echo 214bfb25eca65dc2d9290aad3d60f6ad64a8c925133a37be214235b90a30c596 ;;
    sing-box-1.15.0-alpha.5-linux-arm64.tar.gz)       echo 6f19ce29bbd201074b17739ac5fd0006092f2b83bc98b96e6a1013fd6344fea2 ;;
    *) return 1 ;;
  esac
}

# resolve_sha256 <asset> <base url> : sets SHA_WANT + SHA_SOURCE, returns 1 when no
# checksum can be obtained. It must not run inside a command substitution: the two
# globals are the result.
resolve_sha256() {
  local asset="$1" base="$2" tmp want cand
  SHA_WANT=""; SHA_SOURCE=""
  if [[ -n "$PIN_CHECKSUM" ]]; then SHA_WANT="$PIN_CHECKSUM"; SHA_SOURCE="--checksum"; return 0; fi
  tmp="$(mktemp)"
  # 1) checksums file published next to the assets (upstream does not ship one today,
  #    so this path is here for the day it appears)
  for cand in "sing-box_${VERSION_TAG#v}_checksums.txt" "${VERSION_TAG}_checksums.txt" "checksums.txt"; do
    if fetch_text "${base}/${cand}" "$tmp"; then
      want="$(sums_entry "$tmp" "$asset")"
      if [[ -n "$want" ]]; then
        SHA_WANT="$want"; SHA_SOURCE="official ${cand}"; rm -f "$tmp"; return 0
      fi
      warn "checksums file ${cand} has no entry for ${asset}"
    fi
  done
  rm -f "$tmp"
  # 2) GitHub release API: every asset carries a sha256 digest. Unauthenticated calls
  #    are rate limited, so a failure here is normal and just moves on to the pin table.
  tmp="$(mktemp)"
  if fetch_text "https://api.github.com/repos/${GH_REPO}/releases/tags/${VERSION_TAG}" "$tmp"; then
    # The key order inside an asset object is not part of the API contract: collect the
    # name/digest pair of each object separately instead of assuming an order.
    want="$(awk -v want="$asset" '
      /\{/ { n=""; d="" }
      match($0, /"name": *"[^"]*"/) {
        s=substr($0, RSTART, RLENGTH); sub(/.*"name": *"/, "", s); sub(/"$/, "", s); n=s
      }
      match($0, /"digest": *"sha256:[0-9a-f]+"/) {
        s=substr($0, RSTART, RLENGTH); sub(/.*sha256:/, "", s); sub(/"$/, "", s); d=s
      }
      { if (n == want && d != "") { print d; exit } }
    ' "$tmp")"
    if [[ -n "$want" ]]; then
      SHA_WANT="$want"; SHA_SOURCE="github release digest"; rm -f "$tmp"; return 0
    fi
    warn "the GitHub release metadata carries no digest for ${asset}; trying the pinned table"
  else
    warn "cannot read the GitHub release metadata (offline or API rate limit); trying the pinned table"
  fi
  rm -f "$tmp"
  # 3) pinned table shipped with this script (offline fallback)
  if want="$(pinned_sha256 "$asset")"; then SHA_WANT="$want"; SHA_SOURCE="pinned table"; return 0; fi
  return 1
}

verify_asset() { # <file> <asset name> <base url>
  local file="$1" asset="$2" base="$3" got
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[36m[dry-run]\033[0m would verify sha256 of %s against the official checksum\n' "$asset"
    return 0
  fi
  if ! resolve_sha256 "$asset" "$base"; then
    if [[ $ALLOW_UNVERIFIED -eq 1 ]]; then
      warn "NO CHECKSUM available for ${asset} and --allow-unverified was given: installing UNVERIFIED content"
      return 0
    fi
    die "no checksum available for ${asset} (upstream checksums file, GitHub API digest and the pinned table all failed). Re-run with --checksum <sha256> computed on a trusted host, or accept the risk with --allow-unverified. Asset URL: ${base}/${asset}"
  fi
  got="$(sha256_of "$file")" || die "no sha256 tool available (need sha256sum or openssl)"
  log "checksum source: ${SHA_SOURCE:-unknown}"
  log "  expected sha256: ${SHA_WANT}"
  log "  actual   sha256: ${got}"
  [[ "$SHA_WANT" == "$got" ]] || die "sha256 MISMATCH for ${asset}: the downloaded file was NOT installed"
  log "checksum OK: ${asset}"
  return 0
}

# ---------------------------------------------------------------------------
# Preflight / dependencies
# ---------------------------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "must run as root"
  command -v curl >/dev/null 2>&1 || die "curl is required (apt-get install -y curl)"
  local arch; arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$arch" in amd64|x86_64) ARCH_TAG="amd64" ;; arm64|aarch64) ARCH_TAG="arm64" ;; *) die "unsupported architecture: $arch" ;; esac
  if [[ "$ACTION" == "install" || "$ACTION" == "upgrade" ]]; then
    local avail; avail="$(df -BG / | awk 'NR==2{print int($4)}')"
    [[ "$avail" -ge 2 ]] || die "less than 2G free disk (${avail}G)"
    if ss -tln 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
      ss -tlnp 2>/dev/null | grep ":${LISTEN_PORT} " | grep -q "sing-box" \
        || die "port ${LISTEN_PORT} is already in use: $(ss -tlnp | grep ":${LISTEN_PORT} " | head -1)"
    fi
  fi
  log "preflight OK (role=${ROLE} port=${LISTEN_PORT} arch=${ARCH_TAG} source=${SOURCE})"
}

ensure_deps() {
  export DEBIAN_FRONTEND=noninteractive
  local need=()
  command -v openssl >/dev/null 2>&1 || need+=(openssl)
  command -v ss >/dev/null 2>&1 || need+=(iproute2)
  if [[ ${#need[@]} -gt 0 ]]; then
    log "installing dependencies: ${need[*]}"
    run apt-get update -qq
    run apt-get install -y -qq "${need[@]}"
  fi
}

# ---------------------------------------------------------------------------
# Kernel: the official Release binary, installed as-is
# ---------------------------------------------------------------------------
install_binary() {
  run install -d -m 0755 "$(dirname "$BIN")"
  if [[ -n "$BIN_PATH" ]]; then
    [[ -x "$BIN_PATH" ]] || die "the given binary is not executable: $BIN_PATH"
    if [[ -n "$PIN_CHECKSUM" ]]; then
      verify_asset "$BIN_PATH" "$(basename "$BIN_PATH")" "$(dirname "$BIN_PATH")"
    else
      warn "using a local binary (${BIN_PATH}) -- no checksum was verified for it"
    fi
    run install -m 0755 "$BIN_PATH" "$BIN"
    VERSION_TAG="custom"; BUILD_META_JSON="{\"source\":\"user-provided\",\"path\":\"${BIN_PATH}\"}"
    log "installed the given binary: ${BIN_PATH} -> ${BIN}"
    return 0
  fi
  # Debian/Ubuntu prefer the glibc build, everything else uses the static one
  local flavor=""
  if ldd --version 2>/dev/null | head -1 | grep -qiE 'glibc|libc6'; then flavor="-glibc"; fi
  local base="https://github.com/${GH_REPO}/releases/download/${VERSION_TAG}"
  local tarball="sing-box-${VERSION_TAG#v}-linux-${ARCH_TAG}${flavor}.tar.gz"
  local tmpd; tmpd="$(mktemp -d)"
  log "downloading the official asset: ${tarball}"
  if ! dl "${base}/${tarball}" "${tmpd}/${tarball}" 2>/dev/null; then
    [[ -n "$flavor" ]] || die "download failed: ${tarball}"
    warn "the glibc asset is unavailable, falling back to the static build"
    flavor=""; tarball="sing-box-${VERSION_TAG#v}-linux-${ARCH_TAG}.tar.gz"
    dl "${base}/${tarball}" "${tmpd}/${tarball}" || die "download failed: ${tarball}"
  fi
  verify_asset "${tmpd}/${tarball}" "$tarball" "$base"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[36m[dry-run]\033[0m would unpack %s and install its sing-box -> %s\n' "$tarball" "$BIN"
  else
    tar -xzf "${tmpd}/${tarball}" -C "$tmpd"
    local src; src="$(find "$tmpd" -type f -name sing-box | head -1)"
    [[ -n "$src" ]] || die "no sing-box executable inside the archive"
    install -m 0755 "$src" "$BIN"
  fi
  rm -rf "$tmpd"
  BUILD_META_JSON="{\"source\":\"official-release\",\"asset\":\"${tarball}\",\"checksum\":\"${SHA_SOURCE:-unknown}\"}"
  log "official binary installed -> ${BIN} (version check runs next)"
}

ensure_user() {
  # --user-group makes the account own a group of the same name on every distribution;
  # the config directory and the unit rely on that group existing.
  id "$SRV_USER" &>/dev/null \
    || run useradd --system --no-create-home --user-group --shell /usr/sbin/nologin "$SRV_USER"
  getent group "$SRV_GROUP" >/dev/null 2>&1 || run groupadd --system "$SRV_GROUP"
}

# Runtime state directory (cache.db lives here): writable by the service, unlike
# /etc/sing-box, which stays root-owned so the service cannot rewrite its own config.
ensure_state_dir() {
  run install -d -m 0750 -o "$SRV_USER" -g "$SRV_GROUP" "$WORK_DIR"
}

fix_state_owner() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  [[ -d "$WORK_DIR" ]] || return 0
  # `sing-box check` runs as root and may create files here; hand them to the service
  chown -R "$SRV_USER":"$SRV_GROUP" "$WORK_DIR" 2>/dev/null \
    || warn "could not change the owner of ${WORK_DIR} to ${SRV_USER}:${SRV_GROUP}"
  return 0
}

# ---------------------------------------------------------------------------
# Config generation (idempotent: an existing key is reused)
# ---------------------------------------------------------------------------
gen_configs() {
  local password
  if [[ -f "$PASSWORD_FILE" ]]; then
    password="$(cat "$PASSWORD_FILE")"; log "reusing the existing key: ${PASSWORD_FILE}"
  elif [[ -f "${LEGACY_DATA_DIR}/ss2022.password" ]]; then
    password="$(cat "${LEGACY_DATA_DIR}/ss2022.password")"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '\033[36m[dry-run]\033[0m would migrate the legacy key %s -> %s\n' "${LEGACY_DATA_DIR}/ss2022.password" "$PASSWORD_FILE"
    else
      install -d -m 0700 "$DATA_DIR"; printf '%s' "$password" > "$PASSWORD_FILE"; chmod 600 "$PASSWORD_FILE"
      log "migrated the legacy key -> ${PASSWORD_FILE}"
    fi
  else
    password="$(openssl rand -base64 32)"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '\033[36m[dry-run]\033[0m would generate an ss2022 key -> %s (not written in dry-run)\n' "$PASSWORD_FILE"
    else
      install -d -m 0700 "$DATA_DIR"; printf '%s' "$password" > "$PASSWORD_FILE"; chmod 600 "$PASSWORD_FILE"
      log "generated the ss2022 key -> ${PASSWORD_FILE} (never share or commit it)"
    fi
  fi

  run install -d -m 0750 "${CONF_DIR}/${CONF_SUBDIR}"
  local cdir="${CONF_DIR}/${CONF_SUBDIR}"

  _write() { # _write <file> <<EOF ... EOF
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '\033[36m[dry-run]\033[0m would write %s (%s lines)\n' "$1" "$(wc -l < /dev/stdin)"
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

  if [[ $WITH_NTP -eq 1 ]]; then
    # Built-in NTP client (on by default): clock drift on a VPS breaks the ss2022
    # replay window and TLS handshakes, so the kernel keeps its own time.
    if [[ $NTP_WRITE_SYSTEM -eq 1 ]]; then
      _write "${cdir}/05_ntp.json" <<EOF
{
  "ntp": { "enabled": true, "server": "${NTP_SERVER}", "server_port": ${NTP_PORT},
           "interval": "${NTP_INTERVAL}", "write_to_system": true }
}
EOF
    else
      _write "${cdir}/05_ntp.json" <<EOF
{
  "ntp": { "enabled": true, "server": "${NTP_SERVER}", "server_port": ${NTP_PORT}, "interval": "${NTP_INTERVAL}" }
}
EOF
    fi
  elif [[ -f "${cdir}/05_ntp.json" ]]; then
    # --no-ntp must also clean up a shard written by an earlier run, otherwise NTP
    # would stay enabled on a host that was deployed with the default settings.
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '\033[36m[dry-run]\033[0m would remove %s (NTP disabled)\n' "${cdir}/05_ntp.json"
    else
      rm -f "${cdir}/05_ntp.json"
      log "removed ${cdir}/05_ntp.json (--no-ntp)"
    fi
  fi

  if [[ $DRY_RUN -eq 0 ]]; then
    normalize_conf_perms
    log "config written: ${cdir}/"
  fi
}

normalize_conf_perms() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  [[ -d "$CONF_DIR" ]] || return 0
  # The config root stays owned by root:<service group> 750: the service reads the
  # shards but can never rewrite its own configuration (persistence after a compromise).
  # Runtime state (cache.db) lives in WORK_DIR instead, which the service does own.
  chown -R root:"$SRV_GROUP" "$CONF_DIR"
  chmod 750 "$CONF_DIR"
  if [[ -d "${CONF_DIR}/${CONF_SUBDIR}" ]]; then
    chmod 750 "${CONF_DIR}/${CONF_SUBDIR}"
    find "${CONF_DIR}/${CONF_SUBDIR}" -maxdepth 1 -type f -name '*.json' -exec chmod 640 {} +
  fi
  return 0
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
gen_systemd() {
  local after="network-online.target"
  systemctl list-unit-files 2>/dev/null | grep -q '^smartdns.service' && after="${after} smartdns.service"
  local caps="CapabilityBoundingSet="
  if [[ $NTP_WRITE_SYSTEM -eq 1 ]]; then
    caps="AmbientCapabilities=CAP_SYS_TIME
CapabilityBoundingSet=CAP_SYS_TIME"
  fi
  local unit="$UNIT_FILE"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[36m[dry-run]\033[0m would write %s (ExecStart=%s run -D %s -C %s)\n' "$unit" "$BIN" "$WORK_DIR" "${CONF_DIR}/${CONF_SUBDIR}"
  else
    run install -d -m 0755 "$(dirname "$unit")"
    cat > "$unit" <<EOF
[Unit]
Description=sing-box service (isongwrt)
Documentation=https://sing-box.sagernet.org
After=${after}
Wants=network-online.target

[Service]
User=${SRV_USER}
Group=${SRV_GROUP}
ExecStart=${BIN} run -D ${WORK_DIR} -C ${CONF_DIR}/${CONF_SUBDIR}
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
WorkingDirectory=${WORK_DIR}
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=${WORK_DIR}
RestrictSUIDSGID=yes
${caps}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
  return 0
}

# ---------------------------------------------------------------------------
# smartdns (optional)
# ---------------------------------------------------------------------------
deploy_smartdns() {
  log "deploying smartdns (127.0.0.1:${SMARTDNS_PORT}, off port 53 to avoid conflicts)"
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v smartdns >/dev/null 2>&1; then
    run apt-get install -y -qq smartdns || warn "could not install smartdns; install it yourself and re-run"
  fi

  # Design: the distribution file /etc/smartdns/smartdns.conf (a dpkg conffile) is left
  # untouched -- editing it breaks on upgrade and loses its comments.
  #   1) our config lives in $SMARTDNS_CONF
  #   2) it is activated through SMART_DNS_OPTS="-c <that file>" in $SMARTDNS_ENVFILE
  # Note: a systemd drop-in cannot be used here -- the unit's EnvironmentFile takes
  #       precedence over Environment= and would override the drop-in value with an
  #       empty string; the options file exists for exactly this purpose.
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[36m[dry-run]\033[0m would write %s, set SMART_DNS_OPTS="-c %s" in %s, then restart smartdns\n' \
      "$SMARTDNS_CONF" "$SMARTDNS_CONF" "$SMARTDNS_ENVFILE"
    return 0
  fi

  install -d -m 0755 "$(dirname "$SMARTDNS_CONF")"
  cat > "$SMARTDNS_CONF" <<EOF
# isongwrt managed -- generated by the isongwrt server deployment script
# The distribution file /etc/smartdns/smartdns.conf is left untouched; this file is
# activated by SMART_DNS_OPTS="-c <this file>" in ${SMARTDNS_ENVFILE}
# Full option reference: https://pymumu.github.io/smartdns/config/basic-config/
server-name isongwrt-dns
# Loopback only and not port 53: used by the local sing-box, keeps systemd-resolved /
# dnsmasq on 53 untouched and never exposes an open resolver to the internet
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
    warn "overwriting the existing SMART_DNS_OPTS in ${SMARTDNS_ENVFILE} (original kept as ${SMARTDNS_ENVFILE}.isongwrt-orig)"
    sed -i "s|^[[:space:]]*SMART_DNS_OPTS=.*|SMART_DNS_OPTS=\"-c ${SMARTDNS_CONF}\"|" "$SMARTDNS_ENVFILE"
  else
    printf 'SMART_DNS_OPTS="-c %s"\n' "$SMARTDNS_CONF" >> "$SMARTDNS_ENVFILE"
  fi

  # Remove the drop-in older versions may have written (the two mechanisms cannot coexist)
  if [[ -f /etc/systemd/system/smartdns.service.d/90-isongwrt.conf ]]; then
    rm -f /etc/systemd/system/smartdns.service.d/90-isongwrt.conf
    rmdir /etc/systemd/system/smartdns.service.d 2>/dev/null || true
    warn "removed the old drop-in (the options file is used instead)"
  fi

  systemctl daemon-reload
  systemctl enable smartdns >/dev/null 2>&1 || true
  # A failure here must not abort the whole install (set -e): sing-box is next and the
  # operator gets an explicit hint instead of a half-finished deployment.
  systemctl restart smartdns \
    || warn "could not restart smartdns; check journalctl -u smartdns -n 30 (is SMART_DNS_OPTS effective in ${SMARTDNS_ENVFILE}?)"
  sleep 1
  if command -v dig >/dev/null 2>&1; then
    dig +time=3 +tries=1 @127.0.0.1 -p "${SMARTDNS_PORT}" example.com A >/dev/null 2>&1 \
      && log "smartdns health check passed (127.0.0.1:${SMARTDNS_PORT}, config ${SMARTDNS_CONF})" \
      || warn "smartdns did not answer dig -- check journalctl -u smartdns -n 30 (is SMART_DNS_OPTS effective in ${SMARTDNS_ENVFILE}?)"
  fi
  return 0
}

cleanup_smartdns() {
  local found=0 envfile="$SMARTDNS_ENVFILE"
  if [[ -f "${envfile}.isongwrt-orig" ]]; then
    log "restoring ${envfile} from ${envfile}.isongwrt-orig"
    run cp -a "${envfile}.isongwrt-orig" "$envfile"; found=1
    run rm -f "${envfile}.isongwrt-orig"
  elif grep -qF 'isongwrt.conf' "$envfile" 2>/dev/null; then
    log "dropping the isongwrt SMART_DNS_OPTS line from ${envfile}"
    run sed -i '/isongwrt\.conf/d' "$envfile"; found=1
  fi
  if [[ -f "$SMARTDNS_CONF" ]]; then
    log "removing ${SMARTDNS_CONF}"
    run rm -f "$SMARTDNS_CONF"; found=1
  fi
  if [[ $found -eq 1 ]]; then
    run systemctl daemon-reload
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '\033[36m[dry-run]\033[0m systemctl restart smartdns\n'
    else
      systemctl restart smartdns 2>/dev/null || warn "smartdns was not restarted (not installed or not running?)"
    fi
    log "smartdns is back on its distribution configuration (the package itself is left installed)"
  else
    log "no isongwrt smartdns configuration found -- nothing to restore"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Firewall (optional)
# ---------------------------------------------------------------------------
open_firewall() {
  [[ $OPEN_FIREWALL -eq 1 ]] || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    run ufw allow "${LISTEN_PORT}"/tcp
    run ufw allow "${LISTEN_PORT}"/udp
    warn "allowed ${LISTEN_PORT}/tcp+udp in ufw -- report this firewall change to the user"
  else
    warn "no active ufw detected; make sure ${LISTEN_PORT}/tcp+udp is allowed"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Deploy record / health check
# ---------------------------------------------------------------------------
bin_version() { # best-effort version reported by the installed binary
  local v=""
  [[ -x "$BIN" ]] || { printf ''; return 0; }
  v="$("$BIN" version 2>/dev/null | head -1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -1 || true)"
  printf '%s' "$v"
}

write_record() { # write_record <action> [previous version]
  local action="$1" prev="${2:-}" conf_sha bin_sha build_meta actual tags
  [[ $DRY_RUN -eq 1 ]] && { printf '\033[36m[dry-run]\033[0m would write %s (action=%s)\n' "$RECORD" "$action"; return 0; }
  install -d -m 0700 "$DATA_DIR"
  conf_sha="$(cat "${CONF_DIR}"/${CONF_SUBDIR}/*.json | sha256sum | cut -d' ' -f1)"
  bin_sha="$(sha256_of "$BIN")"
  # Do not write ${VAR:-{...}}: the shell would end the expansion at the inner } and
  # leave a stray } inside the JSON.
  build_meta="${BUILD_META_JSON:-}"
  [[ -n "$build_meta" ]] || build_meta='{"source":"unknown"}'
  actual="$(bin_version)"
  tags="\"${VERSION_TAG:-unknown}\""
  [[ -n "$prev" ]] && tags="\"${prev}\", \"${VERSION_TAG:-unknown}\""
  cat > "$RECORD" <<EOF
{
  "action": "${action}",
  "version": "${VERSION_TAG:-unknown}",
  "revision": "${actual}",
  "previous_version": "${prev}",
  "tags": [${tags}],
  "role": "${ROLE}",
  "listen_port": ${LISTEN_PORT},
  "method": "${METHOD}",
  "build": ${build_meta},
  "binary_sha256": "${bin_sha}",
  "config_sha256": "${conf_sha}",
  "ntp": $( [[ $WITH_NTP -eq 1 ]] && echo true || echo false ),
  "ntp_server": "${NTP_SERVER}",
  "smartdns": $( [[ $WITH_SMARTDNS -eq 1 ]] && echo true || echo false ),
  "smartdns_port": ${SMARTDNS_PORT},
  "download_source": "${SOURCE}",
  "mirror_used": $( [[ $MIRROR_USED -eq 1 ]] && echo true || echo false ),
  "recorded_at": "$(date -Is)"
}
EOF
  chmod 600 "$RECORD"; log "deploy record: ${RECORD}"
  # Append-only history: keeps every action, including rollbacks, with its revision.
  printf '%s action=%s version=%s previous=%s binary_sha256=%s\n' \
    "$(date -Is)" "$action" "${VERSION_TAG:-unknown}" "${prev:--}" "$bin_sha" >> "$HISTORY"
  chmod 600 "$HISTORY"
  return 0
}

do_check_quiet() {
  [[ $DRY_RUN -eq 1 ]] && { printf '\033[36m[dry-run]\033[0m sing-box check -D %s -C %s\n' "$WORK_DIR" "${CONF_DIR}/${CONF_SUBDIR}"; return 0; }
  "$BIN" check -D "$WORK_DIR" -C "${CONF_DIR}/${CONF_SUBDIR}" \
    || die "sing-box check failed (config in ${CONF_DIR}/${CONF_SUBDIR}/)"
  log "sing-box check passed; binary reports: $(bin_version)"
  return 0
}

unit_start_epoch() { # epoch of the current ExecMainStart, empty when unavailable
  local mono up now
  mono="$(systemctl show -p ExecMainStartTimestampMonotonic --value sing-box 2>/dev/null || true)"
  [[ "$mono" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
  [[ "$mono" -gt 0 ]] || { printf ''; return 0; }
  up="$(awk '{print $1}' /proc/uptime 2>/dev/null || echo 0)"
  now="$(date +%s)"
  awk -v n="$now" -v u="$up" -v m="$mono" 'BEGIN{printf "%d", n - (u - m/1000000)}'
}

health_check() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  local i mainpid start fatals
  # 1) the unit must be running with a main process (this start, not a leftover)
  mainpid=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    mainpid="$(systemctl show -p MainPID --value sing-box 2>/dev/null || echo 0)"
    [[ "$mainpid" =~ ^[0-9]+$ && "$mainpid" -gt 0 ]] && break
    sleep 1
  done
  [[ "$mainpid" =~ ^[0-9]+$ && "$mainpid" -gt 0 ]] \
    || die "sing-box is not running (MainPID=${mainpid}) -- journalctl -u sing-box -n 50 --no-pager"
  # 2) the listening socket must belong to that exact process (the unit's MainPID,
  #    i.e. the cgroup/start this script just performed), not to some other daemon
  for i in 1 2 3 4 5; do
    if ss -tlnp 2>/dev/null | grep -F ":${LISTEN_PORT} " | grep -qE "pid=${mainpid}(,|\))"; then break; fi
    sleep 1
  done
  if ! ss -tlnp 2>/dev/null | grep -F ":${LISTEN_PORT} " | grep -qE "pid=${mainpid}(,|\))"; then
    if ss -tln 2>/dev/null | grep -qF ":${LISTEN_PORT} "; then
      die "port ${LISTEN_PORT} is listening but not from this start (MainPID=${mainpid}): $(ss -tlnp | grep -F ":${LISTEN_PORT} " | head -1)"
    fi
    die "port ${LISTEN_PORT} is not listening -- journalctl -u sing-box -n 50 --no-pager"
  fi
  # 3) FATAL lines, counted only from this start onwards (background rule-set retries
  #    log ERROR, which is noise, so only FATAL fails the health check)
  start="$(unit_start_epoch)"
  if [[ -n "$start" ]]; then
    fatals="$(journalctl -u sing-box --since "@${start}" --no-pager 2>/dev/null | grep -c 'FATAL' || true)"
  else
    warn "cannot read ExecMainStartTimestampMonotonic; falling back to the last minute of logs"
    fatals="$(journalctl -u sing-box --since '-1min' --no-pager 2>/dev/null | grep -c 'FATAL' || true)"
  fi
  [[ "${fatals:-0}" -eq 0 ]] || die "FATAL in the startup log (journalctl -u sing-box -n 50 --no-pager)"
  log "health check passed (port ${LISTEN_PORT} held by pid ${mainpid}, no FATAL since this start)"
  log "rollback: $(basename "$0") rollback   (binaries: ${BIN}.prev* ; config: ${BACKUP_DIR})"
  return 0
}

# ---------------------------------------------------------------------------
# Automatic rollback of a failed install/upgrade
# ---------------------------------------------------------------------------
SNAP_DIR=""
CHANGED=0

begin_transaction() {
  CHANGED=1
  [[ $DRY_RUN -eq 1 ]] && return 0
  SNAP_DIR="$(mktemp -d)"
  if [[ -d "$CONF_DIR" ]]; then cp -a "$CONF_DIR" "${SNAP_DIR}/conf"; fi
  if [[ -f "$BIN" ]]; then cp -a "$BIN" "${SNAP_DIR}/bin"; fi
  if [[ -f "$UNIT_FILE" ]]; then cp -a "$UNIT_FILE" "${SNAP_DIR}/unit"; fi
  return 0
}

commit_transaction() {
  CHANGED=0
  if [[ -n "$SNAP_DIR" && -d "$SNAP_DIR" ]]; then rm -rf "$SNAP_DIR"; fi
  SNAP_DIR=""
  return 0
}

on_exit() {
  local code=$?
  [[ $CHANGED -eq 1 && $code -ne 0 && $DRY_RUN -eq 0 ]] || return 0
  warn "the run failed (exit ${code}) -- restoring the previous state"
  if [[ -n "$SNAP_DIR" && -d "$SNAP_DIR" ]]; then
    if [[ -d "${SNAP_DIR}/conf" ]]; then
      rm -rf "$CONF_DIR"; cp -a "${SNAP_DIR}/conf" "$CONF_DIR" || true
    else
      rm -rf "${CONF_DIR}/${CONF_SUBDIR}" || true
    fi
    [[ -f "${SNAP_DIR}/bin" ]] && cp -a "${SNAP_DIR}/bin" "$BIN" || true
    [[ -f "${SNAP_DIR}/unit" ]] && cp -a "${SNAP_DIR}/unit" "$UNIT_FILE" || true
    rm -rf "$SNAP_DIR" || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart sing-box >/dev/null 2>&1 || warn "could not restart sing-box while rolling back"
  fi
  warn "previous state restored; check journalctl -u sing-box -n 50 --no-pager and $(basename "$0") status"
  return 0
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
do_install() {
  preflight; ensure_deps; ensure_user
  if [[ -z "$BIN_PATH" ]]; then resolve_version; fi
  begin_transaction
  if [[ -d "$CONF_DIR" && $DRY_RUN -eq 0 ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"; install -d "$BACKUP_DIR"
    cp -a "$CONF_DIR" "${BACKUP_DIR}/sing-box-conf-${ts}"
    log "backed up the existing config -> ${BACKUP_DIR}/sing-box-conf-${ts}"
  fi
  # Keep the binary that is about to be replaced so `rollback` works after an install
  # too, and keep one copy per version instead of overwriting a single .prev.
  if [[ -f "$BIN" ]]; then
    local curver; curver="$(bin_version)"; curver="${curver#v}"
    run cp -a "$BIN" "${BIN}.prev"
    [[ -n "$curver" ]] && run cp -a "$BIN" "${BIN}.prev-${curver}"
    log "previous binary kept: ${BIN}.prev${curver:+ and ${BIN}.prev-${curver}}"
  fi
  install_binary
  ensure_state_dir
  gen_configs
  [[ $WITH_SMARTDNS -eq 1 ]] && deploy_smartdns
  do_check_quiet
  fix_state_owner
  if [[ $NO_SERVICE -eq 1 ]]; then
    warn "--no-service given: systemd is skipped (start it yourself: ${BIN} run -D ${WORK_DIR} -C ${CONF_DIR}/${CONF_SUBDIR})"
  else
    gen_systemd
    run systemctl enable sing-box
    run systemctl restart sing-box
    open_firewall
    health_check
  fi
  write_record "install" ""
  commit_transaction
  log "done: server ${VERSION_TAG} ready (port ${LISTEN_PORT}, method ${METHOD}$( [[ $WITH_NTP -eq 1 ]] && printf ', NTP %s' "$NTP_SERVER" ))"
}

do_upgrade() {
  [[ -x "$BIN" ]] || die "not installed yet (run install first)"
  preflight; ensure_deps; ensure_user; resolve_version
  local cur cur_norm target_norm
  cur="$(bin_version)"; cur_norm="${cur#v}"; target_norm="${VERSION_TAG#v}"
  # `sing-box version` prints the version without the leading "v" of the release tag,
  # so compare the normalised forms -- otherwise this shortcut never triggers and every
  # upgrade silently overwrites the single .prev backup.
  if [[ -n "$cur_norm" && "$cur_norm" == "$target_norm" ]]; then
    log "already on ${VERSION_TAG} (the binary reports ${cur}) -- nothing to do"
    return 0
  fi
  log "upgrading ${cur:-unknown} -> ${VERSION_TAG}"
  begin_transaction
  run cp -a "$BIN" "${BIN}.prev"
  [[ -n "$cur_norm" ]] && run cp -a "$BIN" "${BIN}.prev-${cur_norm}"
  if [[ $DRY_RUN -eq 0 ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"; install -d "$BACKUP_DIR"
    cp -a "$CONF_DIR" "${BACKUP_DIR}/sing-box-conf-pre-${VERSION_TAG}-${ts}"
  fi
  install_binary
  ensure_state_dir
  fix_state_owner
  do_check_quiet
  if [[ $NO_SERVICE -eq 1 ]]; then
    warn "--no-service given: the systemd unit was not refreshed or restarted"
  else
    gen_systemd
    run systemctl restart sing-box
    health_check
  fi
  write_record "upgrade" "$cur_norm"
  commit_transaction
  log "upgrade complete: ${VERSION_TAG}"
}

newest_file() { # <path...> -> newest existing file by mtime
  local f newest="" newest_ts=0 ts
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    ts="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    if [[ "$ts" -gt "$newest_ts" ]]; then newest="$f"; newest_ts="$ts"; fi
  done
  [[ -n "$newest" ]] && printf '%s' "$newest"
  return 0
}

newest_dir() { # <path...> -> newest existing directory by mtime
  local d newest="" newest_ts=0 ts
  for d in "$@"; do
    [[ -d "$d" ]] || continue
    ts="$(stat -c %Y "$d" 2>/dev/null || echo 0)"
    if [[ "$ts" -gt "$newest_ts" ]]; then newest="$d"; newest_ts="$ts"; fi
  done
  [[ -n "$newest" ]] && printf '%s' "$newest"
  return 0
}

do_rollback() {
  preflight
  local prev_bin conf_src from_ver
  prev_bin="$(newest_file "${BIN}.prev" "${BIN}".prev-* 2>/dev/null)"
  # Config backups may live in the current backup dir or in the directory used by an
  # earlier layout, so both are considered.
  conf_src="$(newest_dir "${BACKUP_DIR}"/sing-box-conf-* "${LEGACY_BACKUP_DIR}"/sing-box-conf-*)"
  if [[ -z "$prev_bin" && -z "$conf_src" ]]; then
    die "nothing to roll back to: no ${BIN}.prev* and no config backup in ${BACKUP_DIR} or ${LEGACY_BACKUP_DIR}"
  fi
  from_ver="$(bin_version)"; from_ver="${from_ver#v}"
  if [[ -n "$prev_bin" ]]; then
    log "restoring the binary from ${prev_bin}"
    run cp -a "$prev_bin" "$BIN"
  else
    warn "no binary backup (${BIN}.prev*) -- keeping the current binary and rolling back the configuration only"
  fi
  if [[ -n "$conf_src" ]]; then
    log "restoring the config from ${conf_src}"
    run install -d -m 0750 "$CONF_DIR"
    run cp -a "${conf_src}/." "${CONF_DIR}/"
  else
    warn "no config backup found -- keeping the current configuration"
  fi
  normalize_conf_perms
  # Record the revision that is actually in place now instead of an empty tag
  local restored; restored="$(bin_version)"; restored="${restored#v}"
  if [[ -n "$restored" ]]; then VERSION_TAG="v${restored}"; else VERSION_TAG="unknown"; fi
  fix_state_owner
  do_check_quiet
  if [[ $NO_SERVICE -eq 1 ]]; then
    warn "--no-service given: the service was not restarted"
  else
    run systemctl restart sing-box
    health_check
  fi
  write_record "rollback" "$from_ver"
  log "rollback complete (previous revision ${from_ver:-unknown})"
}

do_status() {
  echo "== kernel =="; "$BIN" version 2>/dev/null | head -3 || echo "(not installed)"
  echo "== service =="; systemctl is-active sing-box 2>/dev/null || true
  echo "== listeners =="; ss -tlnp 2>/dev/null | grep -E "sing-box|:${LISTEN_PORT} " || echo "(none)"
  echo "== smartdns =="; systemctl is-active smartdns 2>/dev/null || echo "(not installed/enabled)"
  echo "== deploy record =="
  if [[ -f "$RECORD" ]]; then cat "$RECORD"
  elif [[ -f "${LEGACY_DATA_DIR}/deploy-record.json" ]]; then
    echo "(legacy deployment record at ${LEGACY_DATA_DIR})"; cat "${LEGACY_DATA_DIR}/deploy-record.json"
  else echo "(none)"; fi
}

do_uninstall() {
  warn "stopping and removing the sing-box service and binary (config and key stay in ${CONF_DIR}, ${DATA_DIR})"
  run systemctl disable --now sing-box 2>/dev/null || true
  run rm -f "$UNIT_FILE"
  run systemctl daemon-reload
  run rm -f "$BIN"
  cleanup_smartdns
  log "uninstalled (full cleanup: rm -rf ${CONF_DIR} ${DATA_DIR} ${BACKUP_DIR})"
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
