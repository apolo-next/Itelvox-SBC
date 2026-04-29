#!/usr/bin/env bash
#
# sbc-install.sh
#
# Top-level SBC installer for dSIPRouter. Run on a server where the upstream
# dsiprouter installer has already completed. Applies:
#
#   1. Kamailio perf tuning   (kamailio.cfg: children/tcp_*; defaults: SHM/PKG)
#   2. rtpengine perf tuning  (port range 30000-60000, num-threads=16)
#   3. /etc/sysctl.d/90-dsiprouter.conf  (UDP buffers, conntrack, fd limits)
#   4. systemd drop-ins       (LimitNOFILE / LimitNPROC for kam + rtpe)
#   5. local_api_patch.sh     (Local API + outbound_prefix + cfg fixes)
#   6. caller_id_masks schema (DDL from kamailio/defaults/dsip_caller_id_masks.sql)
#   7. Restart services       (kamailio, rtpengine, dsiprouter)
#
# Source-tree assumption: this script does NOT bootstrap the new feature code
# (calleridmasks blueprint, caller_id_management.html template, kamailio.cfg
# CALLER_ID_MASK route, database/__init__.py model classes). Those changes
# must already be present in $SRC_DIR — typically by rsync'ing from a known-
# good box or by checking out a custom branch. verify_source_features below
# fails fast if any are missing.
#
# Idempotent: re-running on an already-tuned box is a no-op. Each block either
# checks the live value or relies on a marker comment baked into the file it
# touches.
#
# Env overrides:
#   DSIP_SRC_DIR=/opt/dsiprouter        # dSIPRouter source checkout
#   DSIP_RUN_KAM_CFG=/etc/kamailio/kamailio.cfg          # runtime cfg
#   DSIP_RUN_RTPE_CFG=/etc/rtpengine/rtpengine.conf      # runtime cfg
#   NO_RESTART=1                        # skip final service restart
#   SKIP_LOCAL_API_PATCH=1               # skip step 5
#   SKIP_CALLER_ID_SCHEMA=1              # skip step 6
#   FORCE_CALLER_ID_SCHEMA=1             # re-apply DDL even if tables exist
#                                        # (DESTRUCTIVE — drops + recreates)

set -euo pipefail

SRC_DIR="${DSIP_SRC_DIR:-/opt/dsiprouter}"
RUN_KAM_CFG="${DSIP_RUN_KAM_CFG:-/etc/kamailio/kamailio.cfg}"
RUN_RTPE_CFG="${DSIP_RUN_RTPE_CFG:-/etc/rtpengine/rtpengine.conf}"
KAM_DEFAULTS="/etc/default/kamailio.conf"
SYSCTL_FILE="/etc/sysctl.d/90-dsiprouter.conf"
KAM_DROPIN="/etc/systemd/system/kamailio.service.d/10-limits.conf"
RTPE_DROPIN="/etc/systemd/system/rtpengine.service.d/10-limits.conf"
CALLER_ID_SQL_FILE="${SRC_DIR}/kamailio/defaults/dsip_caller_id_masks.sql"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${SRC_DIR}/.sbc_install.bak/${TS}"

# Tunables — change at the top to adjust for different hardware.
KAM_CHILDREN=8
KAM_TCP_CHILDREN=4
KAM_TCP_MAX_CONN=4096
KAM_MAX_WHILE_LOOPS=10000
KAM_SHM_MEMORY=2048           # MB
KAM_PKG_MEMORY=64             # MB
RTPE_PORT_MIN=30000
RTPE_PORT_MAX=60000
RTPE_NUM_THREADS=16
LIMIT_NOFILE=1048576
LIMIT_NPROC=65535

log()  { printf '[sbc-install] %s\n' "$*"; }
warn() { printf '[sbc-install] WARN: %s\n' "$*" >&2; }
die()  { printf '[sbc-install] ERROR: %s\n' "$*" >&2; exit 1; }

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    local rel="${f#/}"
    local dst="$BACKUP_DIR/${rel//\//__}"
    cp -p "$f" "$dst"
}

# ----------------------------------------------------------------------------
# 0. Prereqs
# ----------------------------------------------------------------------------
check_prereqs() {
    [[ $EUID -eq 0 ]] || die "must run as root"

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}${ID_LIKE:-}" in
            *debian*|*ubuntu*) : ;;
            *) die "unsupported OS: ${PRETTY_NAME:-unknown} (Debian/Ubuntu only)" ;;
        esac
    else
        die "/etc/os-release missing — cannot identify OS"
    fi

    [[ -d "$SRC_DIR" ]]                       || die "dSIPRouter source not found at $SRC_DIR"
    [[ -f "$SRC_DIR/dsiprouter.sh" ]]         || die "$SRC_DIR/dsiprouter.sh missing — wrong source dir?"
    [[ -x "$SRC_DIR/local_api_patch.sh" ]]    || die "$SRC_DIR/local_api_patch.sh missing or not executable"
    [[ -d /etc/dsiprouter ]]                  || die "/etc/dsiprouter not present — run upstream dsiprouter installer first"
    command -v kamailio  >/dev/null 2>&1      || die "kamailio binary not found — run upstream dsiprouter installer first"
    command -v rtpengine >/dev/null 2>&1      || die "rtpengine binary not found — run upstream dsiprouter installer first"
    command -v systemctl >/dev/null 2>&1      || die "systemctl required"

    log "prereqs OK ($SRC_DIR, ${PRETTY_NAME:-debian})"
}

# ----------------------------------------------------------------------------
# 0b. Verify the SBC-specific source-tree changes are present.
# ----------------------------------------------------------------------------
# This script does NOT generate the source code for the SBC features (the
# calleridmasks blueprint, the caller_id_management template, the kamailio.cfg
# CALLER_ID_MASK route, the SQLAlchemy model classes). They must already be
# in $SRC_DIR. We check the load-bearing pieces and fail fast if any are
# missing — silently proceeding would yield a half-broken install.
verify_source_features() {
    local missing=()

    # Caller-ID masks feature
    [[ -f "$SRC_DIR/gui/modules/api/calleridmasks/routes.py" ]] \
        || missing+=("gui/modules/api/calleridmasks/routes.py")
    [[ -f "$SRC_DIR/gui/modules/api/calleridmasks/functions.py" ]] \
        || missing+=("gui/modules/api/calleridmasks/functions.py")
    [[ -f "$SRC_DIR/gui/templates/caller_id_management.html" ]] \
        || missing+=("gui/templates/caller_id_management.html")
    [[ -f "$CALLER_ID_SQL_FILE" ]] \
        || missing+=("kamailio/defaults/dsip_caller_id_masks.sql")

    # Blueprint registration in dsiprouter.py
    grep -q "from modules.api.calleridmasks.routes import calleridmasks" \
        "$SRC_DIR/gui/dsiprouter.py" 2>/dev/null \
        || missing+=("gui/dsiprouter.py: calleridmasks blueprint import")

    # SQLAlchemy model classes
    grep -q "class CallerIdMaskGroups" \
        "$SRC_DIR/gui/database/__init__.py" 2>/dev/null \
        || missing+=("gui/database/__init__.py: CallerIdMaskGroups model")

    # kamailio.cfg htable modparams + route
    grep -q "caller_id_masks=>" \
        "$SRC_DIR/kamailio/configs/kamailio.cfg" 2>/dev/null \
        || missing+=("kamailio/configs/kamailio.cfg: caller_id_masks htable modparam")
    grep -q "route\[CALLER_ID_MASK\]" \
        "$SRC_DIR/kamailio/configs/kamailio.cfg" 2>/dev/null \
        || missing+=("kamailio/configs/kamailio.cfg: CALLER_ID_MASK route")

    if (( ${#missing[@]} > 0 )); then
        warn "missing SBC source-tree pieces:"
        local m
        for m in "${missing[@]}"; do warn "  - $m"; done
        die "source tree at $SRC_DIR is missing SBC features. rsync from a reference box or check out the SBC branch before re-running."
    fi
    log "source-tree features verified (calleridmasks + kamailio.cfg)"
}

# ----------------------------------------------------------------------------
# Helpers — patch a `key = value` line in-place (idempotent).
# ----------------------------------------------------------------------------

# kamailio.cfg style: `key = value` (with optional spaces). Comment-aware:
# only matches uncommented lines. If the key is missing from the file, fail
# loudly — this script is for tuning a known cfg, not for bootstrapping one.
set_kam_cfg_value() {
    local file="$1" key="$2" value="$3"
    [[ -f "$file" ]] || { warn "skip $file (not present)"; return 0; }
    if ! grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
        die "key '${key}' not found in $file — cfg layout changed?"
    fi
    local current
    current="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | head -1 | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//; s/[[:space:]]*\$//")"
    if [[ "$current" == "$value" ]]; then
        return 0
    fi
    backup_file "$file"
    sed -i -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*).*\$|\1${value}|" "$file"
    log "  $file: ${key} ${current} → ${value}"
}

# /etc/default/kamailio.conf style: `KEY=VALUE`. Uncomments commented entries.
set_shell_kv() {
    local file="$1" key="$2" value="$3"
    [[ -f "$file" ]] || { warn "skip $file (not present)"; return 0; }
    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        local current
        current="$(grep -E "^[[:space:]]*${key}=" "$file" | head -1 | cut -d= -f2-)"
        if [[ "$current" == "$value" ]]; then
            return 0
        fi
        backup_file "$file"
        sed -i -E "s|^([[:space:]]*)${key}=.*\$|\1${key}=${value}|" "$file"
        log "  $file: ${key} ${current} → ${value}"
    elif grep -qE "^[[:space:]]*#[[:space:]]*${key}=" "$file"; then
        backup_file "$file"
        sed -i -E "s|^[[:space:]]*#[[:space:]]*${key}=.*\$|${key}=${value}|" "$file"
        log "  $file: ${key} (uncommented) = ${value}"
    else
        backup_file "$file"
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
        log "  $file: ${key} (appended) = ${value}"
    fi
}

# ----------------------------------------------------------------------------
# 1. Kamailio perf tuning
# ----------------------------------------------------------------------------
apply_kamailio_perf_tuning() {
    log "1. kamailio perf tuning"

    local cfg
    for cfg in "$SRC_DIR/kamailio/configs/kamailio.cfg" "$RUN_KAM_CFG"; do
        [[ -f "$cfg" ]] || continue
        log "  patching $cfg"
        set_kam_cfg_value "$cfg" "children"            "$KAM_CHILDREN"
        set_kam_cfg_value "$cfg" "tcp_children"        "$KAM_TCP_CHILDREN"
        set_kam_cfg_value "$cfg" "tcp_max_connections" "$KAM_TCP_MAX_CONN"
        set_kam_cfg_value "$cfg" "max_while_loops"     "$KAM_MAX_WHILE_LOOPS"

        # tcp_async = yes lives uncommented in upstream cfg; flip if commented.
        if grep -qE "^[[:space:]]*#[[:space:]]*tcp_async[[:space:]]*=" "$cfg" \
           && ! grep -qE "^[[:space:]]*tcp_async[[:space:]]*=" "$cfg"; then
            backup_file "$cfg"
            sed -i -E 's|^[[:space:]]*#[[:space:]]*tcp_async[[:space:]]*=.*$|tcp_async = yes|' "$cfg"
            log "  $cfg: tcp_async (uncommented) = yes"
        fi
    done

    log "  patching $KAM_DEFAULTS"
    set_shell_kv "$KAM_DEFAULTS" "SHM_MEMORY" "$KAM_SHM_MEMORY"
    set_shell_kv "$KAM_DEFAULTS" "PKG_MEMORY" "$KAM_PKG_MEMORY"
}

# ----------------------------------------------------------------------------
# 2. rtpengine perf tuning
# ----------------------------------------------------------------------------
# rtpengine.conf is INI: `key = value`. We only touch port-min/port-max/
# num-threads. The `interface =` line is server-specific (public/private IPs)
# and must NOT be modified by this installer.
set_rtpe_value() {
    local file="$1" key="$2" value="$3"
    [[ -f "$file" ]] || { warn "skip $file (not present)"; return 0; }
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
        local current
        current="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | head -1 | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//; s/[[:space:]]*\$//")"
        if [[ "$current" == "$value" ]]; then return 0; fi
        backup_file "$file"
        sed -i -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*).*\$|\1${value}|" "$file"
        log "  $file: ${key} ${current} → ${value}"
    elif grep -qE "^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=" "$file"; then
        # commented (#num-threads = 8) — uncomment with new value
        backup_file "$file"
        sed -i -E "s|^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=.*\$|${key} = ${value}|" "$file"
        log "  $file: ${key} (uncommented) = ${value}"
    else
        # Append under the [rtpengine] section. If the section header is
        # missing the file is unrecognisable — fail rather than guess.
        grep -qE "^\[rtpengine\]" "$file" || die "no [rtpengine] section in $file"
        backup_file "$file"
        # Append after the [rtpengine] header line.
        sed -i -E "0,/^\[rtpengine\]/{s|^\[rtpengine\]|[rtpengine]\n${key} = ${value}|}" "$file"
        log "  $file: ${key} (appended) = ${value}"
    fi
}

apply_rtpengine_perf_tuning() {
    log "2. rtpengine perf tuning"
    local cfg
    for cfg in "$SRC_DIR/rtpengine/configs/rtpengine.conf" "$RUN_RTPE_CFG"; do
        [[ -f "$cfg" ]] || continue
        log "  patching $cfg"
        set_rtpe_value "$cfg" "port-min"    "$RTPE_PORT_MIN"
        set_rtpe_value "$cfg" "port-max"    "$RTPE_PORT_MAX"
        set_rtpe_value "$cfg" "num-threads" "$RTPE_NUM_THREADS"
    done
}

# ----------------------------------------------------------------------------
# 3. sysctl drop-in
# ----------------------------------------------------------------------------
install_sysctl_drop_in() {
    log "3. sysctl drop-in → $SYSCTL_FILE"

    local desired
    desired="$(cat <<'EOF'
# SBC_INSTALL:sysctl_v1
# dSIPRouter / Kamailio / rtpengine tuning for 1000+ concurrent calls.
# Applies on boot via systemd-sysctl. To activate now:
#   sysctl --system

# --- UDP socket buffers (SIP signalling + RTP) ---
# Default/max receive and send buffer sizes. Larger buffers absorb bursts
# without dropping packets when workers are briefly busy.
net.core.rmem_default = 16777216
net.core.rmem_max     = 67108864
net.core.wmem_default = 16777216
net.core.wmem_max     = 67108864
# Per-socket UDP memory pressure thresholds (pages of 4 KiB).
net.ipv4.udp_mem = 262144 524288 1048576
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- Network device queues ---
# Backlog of packets waiting to be processed by the kernel per CPU.
net.core.netdev_max_backlog = 30000
# Listen() backlog for TCP (JSONRPC, SIP-TCP/TLS).
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192

# --- Conntrack (only matters if nf_conntrack is loaded by iptables/firewalld) ---
# 30k port range * 2 directions + signalling — 262144 leaves comfortable headroom.
net.netfilter.nf_conntrack_max = 262144
# UDP flow timeout — RTP streams should not be force-aged while active.
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 600

# --- File descriptors ---
# Each TCP connection + each UDP socket consumes one fd.
fs.file-max = 2097152
fs.nr_open  = 2097152
EOF
)"

    if [[ -f "$SYSCTL_FILE" ]] && diff -q <(printf '%s\n' "$desired") "$SYSCTL_FILE" >/dev/null 2>&1; then
        log "  unchanged"
    else
        backup_file "$SYSCTL_FILE"
        printf '%s\n' "$desired" > "$SYSCTL_FILE"
        chmod 0644 "$SYSCTL_FILE"
        log "  written"
    fi

    # Apply now. Don't fail the whole install if one key isn't supported on
    # this kernel (e.g. nf_conntrack module not loaded yet).
    sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported errors (often safe — re-check after reboot)"
}

# ----------------------------------------------------------------------------
# 4. systemd drop-ins (file descriptor + process limits)
# ----------------------------------------------------------------------------
install_systemd_drop_ins() {
    log "4. systemd drop-ins"

    local desired
    desired="$(cat <<EOF
# SBC_INSTALL:systemd_limits_v1
[Service]
LimitNOFILE=${LIMIT_NOFILE}
LimitNPROC=${LIMIT_NPROC}
EOF
)"

    local f
    for f in "$KAM_DROPIN" "$RTPE_DROPIN"; do
        if [[ -f "$f" ]] && diff -q <(printf '%s\n' "$desired") "$f" >/dev/null 2>&1; then
            log "  $f: unchanged"
            continue
        fi
        backup_file "$f"
        install -D -m 0644 /dev/stdin "$f" <<<"$desired"
        log "  $f: written"
    done

    systemctl daemon-reload
}

# ----------------------------------------------------------------------------
# 5. Delegate to local_api_patch.sh (cfg/GUI/API + outbound_prefix + kernel fix)
# ----------------------------------------------------------------------------
run_local_api_patch() {
    if [[ "${SKIP_LOCAL_API_PATCH:-0}" = "1" ]]; then
        log "5. local_api_patch.sh — SKIPPED (SKIP_LOCAL_API_PATCH=1)"
        return
    fi
    log "5. local_api_patch.sh"
    # NO_RESTART=1 so the patch script doesn't restart dsiprouter mid-run;
    # we restart everything together at the end.
    NO_RESTART=1 "$SRC_DIR/local_api_patch.sh"
}

# ----------------------------------------------------------------------------
# 6. caller_id_masks schema (DDL from dsip_caller_id_masks.sql)
# ----------------------------------------------------------------------------
# The .sql file contains DROP TABLE / CREATE TABLE / CREATE VIEW. Re-running
# it would wipe live mask data, so the default mode is non-destructive: skip
# if dsip_caller_id_mask_groups already exists. Set FORCE_CALLER_ID_SCHEMA=1
# to drop+recreate (e.g. on a fresh install or after a schema change).
apply_caller_id_masks_schema() {
    if [[ "${SKIP_CALLER_ID_SCHEMA:-0}" = "1" ]]; then
        log "6. caller_id_masks schema — SKIPPED (SKIP_CALLER_ID_SCHEMA=1)"
        return
    fi

    local venv_py="${SRC_DIR}/venv/bin/python3"
    if [[ ! -x "$venv_py" ]]; then
        warn "venv python not found at $venv_py — skipping caller_id_masks schema"
        warn "                                       (re-run after dsiprouter is installed)"
        return
    fi
    if [[ ! -f "$CALLER_ID_SQL_FILE" ]]; then
        die "caller_id_masks DDL not found at $CALLER_ID_SQL_FILE"
    fi

    log "6. caller_id_masks schema"

    SQL_FILE="$CALLER_ID_SQL_FILE" \
    FORCE="${FORCE_CALLER_ID_SCHEMA:-0}" \
    "$venv_py" - <<'PYEOF'
import os, re, sys
os.chdir('/opt/dsiprouter/gui')
sys.path.insert(0, '/opt/dsiprouter/gui')
sys.path.insert(0, '/etc/dsiprouter/gui')
from sqlalchemy import text
from database import startSession, DummySession

sql_file = os.environ['SQL_FILE']
force = os.environ.get('FORCE') == '1'

with open(sql_file, 'r') as fh:
    raw = fh.read()

# Strip line comments ("-- foo") and MySQL conditional comments wrappers,
# then split on ';'. The .sql file has no string-literal semicolons, so a
# naive split is safe here.
no_line_comments = re.sub(r'--[^\n]*\n', '\n', raw)
# Keep MySQL "/*!40101 ... */" executable comments — MySQL evaluates them.
stmts = [s.strip() for s in no_line_comments.split(';')]
stmts = [s for s in stmts if s and not s.startswith('/*') or s.endswith('*/')]
# Drop any pure-whitespace fragments and bare comments left over.
stmts = [s for s in stmts if re.search(r'[A-Za-z]', s)]

db = DummySession()
try:
    db = startSession()
    exists = db.execute(text(
        "SHOW TABLES LIKE 'dsip_caller_id_mask_groups'"
    )).fetchone()
    if exists and not force:
        print('[caller_id_masks] tables already exist — skipping (FORCE_CALLER_ID_SCHEMA=1 to recreate)')
        sys.exit(0)
    if exists and force:
        print('[caller_id_masks] FORCE=1 — dropping + recreating (DESTRUCTIVE)')

    for stmt in stmts:
        db.execute(text(stmt))
    db.commit()
    print('[caller_id_masks] schema OK (%d statements applied)' % len(stmts))
except Exception as ex:
    db.rollback()
    sys.stderr.write('[caller_id_masks] schema FAILED: %s\n' % ex)
    sys.exit(2)
finally:
    db.close()
PYEOF
}

# ----------------------------------------------------------------------------
# 7. Restart
# ----------------------------------------------------------------------------
restart_services() {
    if [[ "${NO_RESTART:-0}" = "1" ]]; then
        log "7. restart — SKIPPED (NO_RESTART=1)"
        log "   manual: systemctl restart kamailio rtpengine dsiprouter"
        return
    fi
    log "7. restarting services"
    # Order: rtpengine first (kamailio talks to it on startup), then kamailio,
    # then the GUI/API.
    local svc
    for svc in rtpengine kamailio dsiprouter; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
            log "   restarting $svc"
            systemctl restart "$svc" \
                || warn "$svc restart failed — check 'journalctl -u $svc -n 100'"
        else
            warn "$svc.service not present — skipping"
        fi
    done
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
    log "starting on $(hostname) — backups → $BACKUP_DIR (created on first change)"
    check_prereqs
    verify_source_features
    apply_kamailio_perf_tuning
    apply_rtpengine_perf_tuning
    install_sysctl_drop_in
    install_systemd_drop_ins
    run_local_api_patch
    apply_caller_id_masks_schema
    restart_services
    log "DONE"
}

main "$@"
