#!/usr/bin/env bash
#
# sbc-lab-setup.sh
#
# Optional companion to sbc-install.sh. Sets up a load-test lab on the SBC:
#
#   1. Install docker.io + mysql-client (if missing).
#   2. Add IP aliases on $LAB_IF (.50 client, .51 sipp UAC, .52 PSTN/UAS).
#      Persisted via a systemd oneshot unit so they come back after reboot.
#   3. Extract lab assets (Dockerfiles + asterisk configs + sipp scenarios +
#      SQL) to /opt/test-lab/.
#   4. Build the lab/asterisk:ubuntu22 and lab/sipp:bookworm Docker images.
#   5. Apply loadtest SQL provisioning to the kamailio DB (idempotent: skips
#      if the loadtest rows already exist).
#   6. Start lab-asterisk-client and lab-asterisk-pstn containers.
#
# Idempotent. Re-running is safe — every step checks state before acting.
# This script does NOT touch dSIPRouter, kamailio, or rtpengine — run
# sbc-install.sh first.
#
# Env overrides (defaults match the reference SBC sbc01.itelvox.com):
#   LAB_IF=ens192                 # interface to attach IP aliases on
#   LAB_NET_PREFIX=172.17.100     # /24 used by the lab
#   LAB_SBC_IP=172.17.100.10      # this SBC's private IP (Kamailio listens here)
#   LAB_CLIENT_IP=172.17.100.50   # Asterisk-client / test PBX
#   LAB_UAC_IP=172.17.100.51      # sipp UAC
#   LAB_PSTN_IP=172.17.100.52     # Asterisk-PSTN / sipp UAS
#   LAB_DIR=/opt/test-lab         # where to extract assets
#   SKIP_DEPS=1                   # don't install/upgrade packages
#   SKIP_IP_ALIASES=1             # don't touch network config
#   SKIP_DOCKER_BUILD=1           # don't build images
#   SKIP_SQL=1                    # don't apply loadtest provisioning
#   SKIP_CONTAINERS=1             # don't start asterisk containers
#   FORCE_REEXTRACT=1             # overwrite existing $LAB_DIR contents

set -euo pipefail

LAB_IF="${LAB_IF:-ens192}"
LAB_NET_PREFIX="${LAB_NET_PREFIX:-172.17.100}"
LAB_SBC_IP="${LAB_SBC_IP:-${LAB_NET_PREFIX}.10}"
LAB_CLIENT_IP="${LAB_CLIENT_IP:-${LAB_NET_PREFIX}.50}"
LAB_UAC_IP="${LAB_UAC_IP:-${LAB_NET_PREFIX}.51}"
LAB_PSTN_IP="${LAB_PSTN_IP:-${LAB_NET_PREFIX}.52}"
LAB_DIR="${LAB_DIR:-/opt/test-lab}"
LAB_NETMASK_BITS=24

ALIAS_UNIT=/etc/systemd/system/sbc-lab-ip-aliases.service
ALIAS_SCRIPT=/usr/local/sbin/sbc-lab-ip-aliases

ASTERISK_IMG="lab/asterisk:ubuntu22"
SIPP_IMG="lab/sipp:bookworm"

log()  { printf '[sbc-lab] %s\n' "$*"; }
warn() { printf '[sbc-lab] WARN: %s\n' "$*" >&2; }
die()  { printf '[sbc-lab] ERROR: %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Prereqs
# ----------------------------------------------------------------------------
check_prereqs() {
    [[ $EUID -eq 0 ]] || die "must run as root"

    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        case "${ID:-}${ID_LIKE:-}" in
            *debian*|*ubuntu*) : ;;
            *) die "unsupported OS: ${PRETTY_NAME:-unknown}" ;;
        esac
    fi
    command -v ip       >/dev/null 2>&1 || die "iproute2 not installed"
    command -v systemctl>/dev/null 2>&1 || die "systemctl required"
    ip link show "$LAB_IF" >/dev/null 2>&1 \
        || die "interface $LAB_IF not found — set LAB_IF=<your nic>"

    # Check that LAB_SBC_IP is actually present on LAB_IF — otherwise the
    # lab topology (containers expecting Kamailio at $LAB_SBC_IP) won't work.
    if ! ip -br addr show dev "$LAB_IF" | grep -qE "(^|[[:space:]/])${LAB_SBC_IP}/"; then
        warn "LAB_SBC_IP=${LAB_SBC_IP} not on ${LAB_IF}"
        warn "  current: $(ip -br addr show dev "$LAB_IF" | awk '{print $3, $4, $5, $6, $7}')"
        warn "  the lab assumes Kamailio is reachable at ${LAB_SBC_IP}:5060"
        warn "  override LAB_SBC_IP / LAB_NET_PREFIX, or add the SBC IP to ${LAB_IF}"
    fi

    log "prereqs OK (${LAB_IF}, sbc=${LAB_SBC_IP}, client=${LAB_CLIENT_IP}, uac=${LAB_UAC_IP}, pstn=${LAB_PSTN_IP})"
}

# ----------------------------------------------------------------------------
# 1. Packages
# ----------------------------------------------------------------------------
install_deps() {
    if [[ "${SKIP_DEPS:-0}" = "1" ]]; then
        log "1. deps — SKIPPED (SKIP_DEPS=1)"; return
    fi
    log "1. installing deps (docker.io, mysql-client)"
    local need=()
    command -v docker >/dev/null 2>&1 || need+=(docker.io)
    command -v mysql  >/dev/null 2>&1 || need+=(default-mysql-client)
    if (( ${#need[@]} == 0 )); then
        log "  all deps present"
    else
        log "  apt-get install: ${need[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
    fi
    systemctl enable --now docker.service >/dev/null 2>&1 || warn "could not enable docker.service"
}

# ----------------------------------------------------------------------------
# 2. IP aliases (.50, .51, .52) — persisted via systemd oneshot unit
# ----------------------------------------------------------------------------
install_ip_aliases() {
    if [[ "${SKIP_IP_ALIASES:-0}" = "1" ]]; then
        log "2. IP aliases — SKIPPED (SKIP_IP_ALIASES=1)"; return
    fi
    log "2. IP aliases on ${LAB_IF}"

    # Generate the script that systemd will run on boot. Idempotent itself
    # (uses `ip addr add ... || true` to ignore "already exists").
    local desired_script
    desired_script="$(cat <<EOF
#!/bin/sh
# SBC_LAB:ip_aliases_v1 — managed by sbc-lab-setup.sh
set -e
for ip in ${LAB_CLIENT_IP} ${LAB_UAC_IP} ${LAB_PSTN_IP}; do
    ip addr add "\${ip}/${LAB_NETMASK_BITS}" dev ${LAB_IF} 2>/dev/null || true
done
exit 0
EOF
)"
    if [[ -f "$ALIAS_SCRIPT" ]] && diff -q <(printf '%s\n' "$desired_script") "$ALIAS_SCRIPT" >/dev/null 2>&1; then
        log "  $ALIAS_SCRIPT: unchanged"
    else
        printf '%s\n' "$desired_script" > "$ALIAS_SCRIPT"
        chmod 0755 "$ALIAS_SCRIPT"
        log "  $ALIAS_SCRIPT: written"
    fi

    local desired_unit
    desired_unit="$(cat <<EOF
# SBC_LAB:ip_aliases_v1
[Unit]
Description=SBC lab IP aliases on ${LAB_IF}
After=network-online.target
Wants=network-online.target
Before=docker.service kamailio.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ALIAS_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
)"
    if [[ -f "$ALIAS_UNIT" ]] && diff -q <(printf '%s\n' "$desired_unit") "$ALIAS_UNIT" >/dev/null 2>&1; then
        log "  $ALIAS_UNIT: unchanged"
    else
        printf '%s\n' "$desired_unit" > "$ALIAS_UNIT"
        log "  $ALIAS_UNIT: written"
        systemctl daemon-reload
    fi
    systemctl enable --now sbc-lab-ip-aliases.service >/dev/null 2>&1 \
        || warn "could not enable sbc-lab-ip-aliases.service"

    # Apply NOW (the script is idempotent so this is safe even if already up)
    "$ALIAS_SCRIPT"

    local missing=()
    local ip
    for ip in "$LAB_CLIENT_IP" "$LAB_UAC_IP" "$LAB_PSTN_IP"; do
        ip -br addr show dev "$LAB_IF" \
            | grep -qE "(^|[[:space:]/])${ip}/" \
            || missing+=("$ip")
    done
    if (( ${#missing[@]} > 0 )); then
        warn "aliases not visible after add: ${missing[*]} — check 'ip addr show ${LAB_IF}'"
    else
        log "  aliases live: ${LAB_CLIENT_IP}, ${LAB_UAC_IP}, ${LAB_PSTN_IP}"
    fi
}

# ----------------------------------------------------------------------------
# 3. Extract lab assets to $LAB_DIR
# ----------------------------------------------------------------------------
extract_lab_assets() {
    log "3. lab assets → $LAB_DIR"

    local marker="$LAB_DIR/.sbc_lab_extracted"
    if [[ -f "$marker" && "${FORCE_REEXTRACT:-0}" != "1" ]]; then
        log "  already extracted (touch marker present); use FORCE_REEXTRACT=1 to overwrite"
        return
    fi
    mkdir -p "$LAB_DIR"

    # Find the payload start (line after __PAYLOAD_BELOW__) and pipe through
    # base64 -d | tar -xz into $LAB_DIR.
    local me="${BASH_SOURCE[0]}"
    awk '/^__PAYLOAD_BELOW__$/{flag=1; next} flag' "$me" \
        | base64 -d \
        | tar -xz -C "$LAB_DIR"

    # Persist runtime dirs that the tarball excluded (sounds, logs).
    mkdir -p "$LAB_DIR/asterisk-client/logs" "$LAB_DIR/asterisk-client/sounds" \
             "$LAB_DIR/asterisk-pstn/logs"   "$LAB_DIR/asterisk-pstn/sounds"   \
             "$LAB_DIR/sipp/logs"            "$LAB_DIR/sipp/media"             \
             "$LAB_DIR/shared"

    # Patch IPs in the asterisk + sipp configs if they don't match the
    # current LAB_* envs. The reference tarball was captured with the IPs
    # from sbc01.itelvox.com (172.17.100.10/.50/.51/.52). On a server with
    # different topology, sed-fix on extract.
    if [[ "$LAB_SBC_IP"    != "172.17.100.10" \
       || "$LAB_CLIENT_IP" != "172.17.100.50" \
       || "$LAB_UAC_IP"    != "172.17.100.51" \
       || "$LAB_PSTN_IP"   != "172.17.100.52" ]]; then
        log "  patching IPs in extracted configs"
        local f
        while IFS= read -r -d '' f; do
            sed -i \
                -e "s/172\\.17\\.100\\.10\\b/${LAB_SBC_IP}/g" \
                -e "s/172\\.17\\.100\\.50\\b/${LAB_CLIENT_IP}/g" \
                -e "s/172\\.17\\.100\\.51\\b/${LAB_UAC_IP}/g" \
                -e "s/172\\.17\\.100\\.52\\b/${LAB_PSTN_IP}/g" \
                "$f"
        done < <(find "$LAB_DIR" -type f \( -name '*.conf' -o -name '*.xml' -o -name '*.sh' -o -name '*.sql' \) -print0)
    fi
    chmod +x "$LAB_DIR/sipp/run.sh" "$LAB_DIR/sipp/run-uas.sh" 2>/dev/null || true

    touch "$marker"
    log "  extracted ($(find "$LAB_DIR" -type f | wc -l) files)"
}

# ----------------------------------------------------------------------------
# 4. Docker images
# ----------------------------------------------------------------------------
build_docker_images() {
    if [[ "${SKIP_DOCKER_BUILD:-0}" = "1" ]]; then
        log "4. docker build — SKIPPED (SKIP_DOCKER_BUILD=1)"; return
    fi
    log "4. docker images"

    if docker image inspect "$ASTERISK_IMG" >/dev/null 2>&1; then
        log "  $ASTERISK_IMG: already built"
    else
        log "  building $ASTERISK_IMG"
        docker build -t "$ASTERISK_IMG" -f "$LAB_DIR/Dockerfile.asterisk" "$LAB_DIR"
    fi
    if docker image inspect "$SIPP_IMG" >/dev/null 2>&1; then
        log "  $SIPP_IMG: already built"
    else
        log "  building $SIPP_IMG"
        docker build -t "$SIPP_IMG" -f "$LAB_DIR/Dockerfile.sipp" "$LAB_DIR"
    fi
}

# ----------------------------------------------------------------------------
# 5. Apply loadtest SQL (idempotent: skip if test rows already exist)
# ----------------------------------------------------------------------------
apply_loadtest_sql() {
    if [[ "${SKIP_SQL:-0}" = "1" ]]; then
        log "5. loadtest SQL — SKIPPED (SKIP_SQL=1)"; return
    fi
    log "5. loadtest SQL"

    local venv_py="/opt/dsiprouter/venv/bin/python3"
    if [[ ! -x "$venv_py" ]]; then
        warn "venv python not found — skipping loadtest SQL"
        return
    fi

    SQL_DIR="${LAB_DIR}/sql" "$venv_py" - <<'PYEOF'
import os, re, sys, glob
os.chdir('/opt/dsiprouter/gui')
sys.path.insert(0, '/opt/dsiprouter/gui')
sys.path.insert(0, '/etc/dsiprouter/gui')
from sqlalchemy import text
from database import startSession, DummySession

sql_dir = os.environ['SQL_DIR']

db = DummySession()
try:
    db = startSession()
    # Idempotency probe: the loadtest setup tags rows with description LIKE
    # 'name:loadtest_%'. If any are already present, skip the install side.
    n = db.execute(text(
        "SELECT COUNT(*) FROM dr_gateways WHERE description LIKE 'name:loadtest_%'"
    )).scalar()
    if n and n > 0:
        print(f'[loadtest] skip — {n} loadtest rows already in dr_gateways')
        sys.exit(0)

    # Apply 01-loadtest-setup.sql + 02-digitalk-prefix-6661.sql.
    # 03-outbound-prefix-schema.sql is superseded by local_api_patch.sh's
    # apply_outbound_prefix_schema — apply only if the table is absent.
    # 99-loadtest-rollback.sql is a manual escape hatch, never auto-applied.
    files = ['01-loadtest-setup.sql', '02-digitalk-prefix-6661.sql']
    has_outbound_prefix = db.execute(text(
        "SHOW TABLES LIKE 'dsip_endpoint_outbound_prefix'"
    )).fetchone()
    if not has_outbound_prefix:
        files.insert(0, '03-outbound-prefix-schema.sql')

    for fname in files:
        path = os.path.join(sql_dir, fname)
        if not os.path.exists(path):
            print(f'[loadtest] missing: {path}', file=sys.stderr)
            continue
        with open(path) as fh:
            raw = fh.read()
        no_comments = re.sub(r'--[^\n]*\n', '\n', raw)
        stmts = [s.strip() for s in no_comments.split(';')]
        stmts = [s for s in stmts if re.search(r'[A-Za-z]', s)]
        for stmt in stmts:
            db.execute(text(stmt))
        print(f'[loadtest] applied {fname} ({len(stmts)} stmts)')
    db.commit()
except Exception as ex:
    db.rollback()
    sys.stderr.write('[loadtest] FAILED: %s\n' % ex)
    sys.exit(2)
finally:
    db.close()
PYEOF
}

# ----------------------------------------------------------------------------
# 6. Start asterisk containers
# ----------------------------------------------------------------------------
start_containers() {
    if [[ "${SKIP_CONTAINERS:-0}" = "1" ]]; then
        log "6. containers — SKIPPED (SKIP_CONTAINERS=1)"; return
    fi
    log "6. containers"

    start_one() {
        local name="$1" cfg_dir="$2"
        if docker ps --format "{{.Names}}" | grep -qx "$name"; then
            log "  $name: already running"
            return
        fi
        if docker ps -a --format "{{.Names}}" | grep -qx "$name"; then
            log "  $name: starting existing container"
            docker start "$name" >/dev/null
            return
        fi
        log "  $name: creating + starting"
        docker run -d --name "$name" --restart=unless-stopped --net=host \
            -v "${LAB_DIR}/${cfg_dir}/etc:/etc/asterisk:ro" \
            -v "${LAB_DIR}/${cfg_dir}/logs:/var/log/asterisk" \
            -v "${LAB_DIR}/${cfg_dir}/sounds:/var/lib/asterisk/custom_sounds" \
            "$ASTERISK_IMG" >/dev/null
    }
    start_one "lab-asterisk-client" "asterisk-client"
    start_one "lab-asterisk-pstn"   "asterisk-pstn"
}

print_next_steps() {
    cat <<EOF

Lab is ready.

Test PBX (Asterisk-client):     ${LAB_CLIENT_IP}:5060
Loopback PSTN (Asterisk-pstn):  ${LAB_PSTN_IP}:5060
sipp UAC source:                ${LAB_UAC_IP}

Common runs:
  cd ${LAB_DIR}/sipp && ./run.sh ramp     # 10 cps / 50 max — sanity
  cd ${LAB_DIR}/sipp && ./run.sh medium   # 200 cps / 800 max
  cd ${LAB_DIR}/sipp && ./run.sh heavy    # 500 cps / 2000 max

Switch PSTN-eco to sipp UAS for higher CPS:
  docker stop lab-asterisk-pstn
  cd ${LAB_DIR}/sipp && ./run-uas.sh

Tear down loadtest provisioning:
  /opt/dsiprouter/venv/bin/python3 -c "
  import sys; sys.path.insert(0,'/opt/dsiprouter/gui'); sys.path.insert(0,'/etc/dsiprouter/gui')
  from sqlalchemy import text
  from database import startSession
  db = startSession()
  for line in open('${LAB_DIR}/sql/99-loadtest-rollback.sql'):
      pass  # see file for the actual rollback statements"
  # — easier: mysql -u kamailio -p kamailio < ${LAB_DIR}/sql/99-loadtest-rollback.sql

EOF
}

main() {
    check_prereqs
    install_deps
    install_ip_aliases
    extract_lab_assets
    build_docker_images
    apply_loadtest_sql
    start_containers
    print_next_steps
    log "DONE"
}

main "$@"
exit 0

# ============================================================================
#                        EMBEDDED LAB ASSETS PAYLOAD
# ----------------------------------------------------------------------------
# Everything below __PAYLOAD_BELOW__ is a base64-encoded gzipped tarball of
# /opt/test-lab/ (Dockerfiles + asterisk configs + sipp scenarios + SQL).
# extract_lab_assets() reads it via `awk` + `base64 -d` + `tar -xz`. Edit by
# regenerating: `cd /opt/test-lab && tar --exclude=*/logs --exclude=*/sounds
# --exclude=shared -czf - . | base64`
# ============================================================================
__PAYLOAD_BELOW__
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
