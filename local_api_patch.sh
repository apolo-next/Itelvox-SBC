#!/usr/bin/env bash
#
# local_api_patch.sh
#
# Re-applies the Local API blueprint, the CDR tab/menu hide, and the -iip/-eip
# forced-IP flags on top of a fresh dsiprouter checkout. Run after every
# upgrade (or after `git pull` blows away local edits).
#
# Idempotent: each block checks for a marker and skips if already applied.
# Touched files (in /opt/dsiprouter):
#   - gui/modules/local_api/__init__.py        (created)
#   - gui/modules/local_api/routes.py          (created)
#   - gui/dsiprouter.py                        (3 lines added)
#   - dsiprouter.sh                            (4 blocks added: -iip/-eip)
#   - gui/templates/endpointgroups.html        (CDR tabs hidden)
#   - gui/templates/fullwidth_layout.html      (CDR sidebar entry hidden)
#
# After patching the source, mirrors to /etc/dsiprouter/gui (the runtime path
# the dsiprouter service actually loads) when present.
#
# Env overrides:
#   DSIP_SRC_DIR   default /opt/dsiprouter
#   DSIP_RUN_DIR   default /etc/dsiprouter/gui
#   NO_RESTART=1   skip the dsiprouter restart at the end

set -euo pipefail

SRC_DIR="${DSIP_SRC_DIR:-/opt/dsiprouter}"
RUN_DIR="${DSIP_RUN_DIR:-/etc/dsiprouter/gui}"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${SRC_DIR}/.local_api_patch.bak/${TS}"

log()  { printf '[local_api_patch] %s\n' "$*"; }
warn() { printf '[local_api_patch] WARN: %s\n' "$*" >&2; }
die()  { printf '[local_api_patch] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$SRC_DIR" ]]                  || die "source dir not found: $SRC_DIR"
[[ -f "$SRC_DIR/dsiprouter.sh" ]]    || die "wrong source dir? $SRC_DIR/dsiprouter.sh missing"
[[ -f "$SRC_DIR/gui/dsiprouter.py" ]]|| die "wrong source dir? gui/dsiprouter.py missing"

mkdir -p "$BACKUP_DIR"
log "backups → $BACKUP_DIR"

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    local rel="${f#$SRC_DIR/}"
    local dst="$BACKUP_DIR/${rel//\//__}"
    cp -p "$f" "$dst"
}

# ----------------------------------------------------------------------------
# 1. gui/modules/local_api/__init__.py + routes.py
# ----------------------------------------------------------------------------
install_local_api() {
    local gui_dir="$1"
    local mod_dir="$gui_dir/modules/local_api"
    # Versioned marker so subsequent runs pick up new routes (allowed-prefixes, etc).
    if [[ -f "$mod_dir/routes.py" ]] \
       && grep -q "LOCAL_API_PATCH:routes_v2" "$mod_dir/routes.py" 2>/dev/null; then
        log "local_api/: already installed (v2) in $gui_dir"
        return
    fi
    log "local_api/: installing v2 in $gui_dir"
    mkdir -p "$mod_dir"
    : > "$mod_dir/__init__.py"
    cat > "$mod_dir/routes.py" <<'PYEOF'
"""
Local API blueprint — token-authenticated REST endpoints that reuse the open-source
carrier/endpoint helper functions without going through the Core license check.

Mounted at /api/local/v1/...

Auth: Bearer <DSIP_API_TOKEN>  (same token used by dSIPRouter's main API)
      OR an active GUI session (session-cookie auth) so the GUI can call these
      routes without exposing the bearer token in client-side code.

# LOCAL_API_PATCH:routes_v2
"""

import re
import sys
from functools import wraps

from flask import Blueprint, jsonify, request, session
from sqlalchemy import cast, Integer, text
from werkzeug import exceptions as http_exceptions

if sys.path[0] != '/etc/dsiprouter/gui':
    sys.path.insert(0, '/etc/dsiprouter/gui')

import settings
from database import (
    startSession, DummySession, GatewayGroups, Gateways, Address, UAC,
    DsipGwgroup2LB, Dispatcher, OutboundRoutes, InboundMapping, dSIPLCR,
)
from shared import strFieldsToDict
from util.security import APIToken
from util.ipc import STATE_SHMEM_NAME, getSharedMemoryDict
from modules.api.carriergroups.functions import (
    addUpdateCarrierGroups, addUpdateCarriers,
)
from modules.api import api_routes as _api_routes
from modules.api.kamailio.functions import reloadKamailio, sendJsonRpcCmd
from shared import dictToStrFields


local_api = Blueprint('local_api', __name__, url_prefix='/api/local/v1')


def token_required(func):
    """Auth: Bearer token OR an active dSIPRouter GUI session.

    The session branch lets the GUI call these routes via its existing cookie
    without exposing DSIP_API_TOKEN in client-side JS. Blueprint is csrf.exempt
    so session-based POST/PUT/DELETE works without a CSRF token.
    """
    @wraps(func)
    def wrapper(*args, **kwargs):
        if APIToken(request).isValid():
            return func(*args, **kwargs)
        if session.get('logged_in'):
            return func(*args, **kwargs)
        return jsonify({
            'error': 'http',
            'msg': 'Unauthorized — invalid or missing Bearer token, no active session',
        }), 401
    return wrapper


def _ok(data=None, msg='', kamreload=False, status=200):
    return jsonify({
        'error': '',
        'msg': msg,
        'kamreload': kamreload,
        'data': data if data is not None else [],
    }), status


def _err(msg, status=400):
    return jsonify({
        'error': 'http',
        'msg': msg,
        'kamreload': False,
        'data': [],
    }), status


def _serialize_carrier_group(row):
    fields = strFieldsToDict(row.description) if row.description else {}
    gwlist = [int(x) for x in (row.gwlist or '').split(',') if x]
    return {
        'gwgroupid': row.id,
        'name': fields.get('name', ''),
        'type': fields.get('type', ''),
        'gwlist': gwlist,
        'auth': {
            'r_username': row.r_username or '',
            'auth_username': row.auth_username or '',
            'auth_domain': row.r_domain or '',
            'auth_proxy': row.auth_proxy or '',
        } if getattr(row, 'r_username', None) else None,
        'lb_enabled': int(row.lb_enabled) if row.lb_enabled is not None else 0,
    }


# ---------------------------------------------------------------------------
# Carrier groups
# ---------------------------------------------------------------------------

@local_api.route('/carriergroups', methods=['GET'])
@local_api.route('/carriergroups/<int:gwgroupid>', methods=['GET'])
@token_required
def list_carrier_groups(gwgroupid=None):
    db = DummySession()
    try:
        db = startSession()
        q = db.query(
            GatewayGroups.id,
            GatewayGroups.description,
            GatewayGroups.gwlist,
            UAC.r_username,
            UAC.auth_username,
            UAC.r_domain,
            UAC.auth_proxy,
            cast(DsipGwgroup2LB.enabled, Integer).label('lb_enabled'),
        ).outerjoin(
            UAC, GatewayGroups.id == UAC.l_uuid,
        ).outerjoin(
            DsipGwgroup2LB, GatewayGroups.id == DsipGwgroup2LB.gwgroupid,
        ).filter(
            GatewayGroups.description.regexp_match(GatewayGroups.FILTER.CARRIER.value),
        )
        if gwgroupid is not None:
            row = q.filter(GatewayGroups.id == gwgroupid).first()
            if row is None:
                return _err('Carrier group not found', status=404)
            return _ok(data=[_serialize_carrier_group(row)])
        rows = q.all()
        return _ok(data=[_serialize_carrier_group(r) for r in rows])
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/carriergroups', methods=['POST'])
@token_required
def create_carrier_group():
    payload = request.get_json(silent=True) or {}
    name = payload.get('name', '').strip()
    if not name:
        return _err("Field 'name' is required")

    cg_data = {
        'gwgroupid': '',
        'name': name,
        'lb_enabled': int(payload.get('lb_enabled', 0)),
    }
    auth = payload.get('auth') or {}
    if auth:
        cg_data['authtype'] = auth.get('type', 'ip')
        cg_data['r_username'] = auth.get('r_username', '')
        cg_data['auth_username'] = auth.get('auth_username', '')
        cg_data['auth_password'] = auth.get('auth_password', '')
        cg_data['auth_domain'] = auth.get('auth_domain', '')
        cg_data['auth_proxy'] = auth.get('auth_proxy', '')

    try:
        gwgroupid = addUpdateCarrierGroups(cg_data)
    except http_exceptions.HTTPException as ex:
        return _err(ex.description, status=ex.code or 400)
    except Exception as ex:
        return _err(str(ex), status=500)

    created_endpoints = []
    for ep in payload.get('endpoints') or []:
        ep_data = {
            'gwgroupid': str(gwgroupid),
            'name': ep.get('name') or name,
            'ip_addr': ep.get('host') or ep.get('ip_addr', ''),
            'strip': str(ep.get('strip', '')),
            'prefix': ep.get('prefix', ''),
            'rweight': ep.get('rweight', 1),
        }
        if ep.get('port'):
            ep_data['ip_addr'] = '{}:{}'.format(ep_data['ip_addr'], ep['port'])
        try:
            addUpdateCarriers(ep_data)
            created_endpoints.append(ep_data['ip_addr'])
        except Exception as ex:
            return _err('Carrier group {} created but endpoint failed: {}'.format(gwgroupid, ex), status=207)

    return _ok(
        data=[{'gwgroupid': gwgroupid, 'endpoints': created_endpoints}],
        msg='Carrier group created',
        kamreload=True,
        status=201,
    )


@local_api.route('/carriergroups/<int:gwgroupid>', methods=['DELETE'])
@token_required
def delete_carrier_group(gwgroupid):
    db = DummySession()
    try:
        db = startSession()
        gw = db.query(GatewayGroups).filter(GatewayGroups.id == gwgroupid).first()
        if gw is None:
            return _err('Carrier group not found', status=404)

        gwids = [int(x) for x in (gw.gwlist or '').split(',') if x]
        if gwids:
            db.query(Gateways).filter(Gateways.gwid.in_(gwids)).delete(synchronize_session=False)
            db.query(Address).filter(Address.id.in_(
                db.query(Address.id).filter(Address.tag.contains('gwgroup:{}'.format(gwgroupid)))
            )).delete(synchronize_session=False)
            db.query(Dispatcher).filter(Dispatcher.setid == gwgroupid).delete(synchronize_session=False)
        db.query(UAC).filter(UAC.l_uuid == gwgroupid).delete(synchronize_session=False)
        db.query(DsipGwgroup2LB).filter(DsipGwgroup2LB.gwgroupid == gwgroupid).delete(synchronize_session=False)
        db.query(OutboundRoutes).filter(OutboundRoutes.gwlist == str(gwgroupid)).delete(synchronize_session=False)
        db.query(GatewayGroups).filter(GatewayGroups.id == gwgroupid).delete(synchronize_session=False)
        db.commit()

        getSharedMemoryDict(STATE_SHMEM_NAME)['kam_reload_required'] = True
        return _ok(msg='Carrier group {} deleted'.format(gwgroupid), kamreload=True)
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Carriers (endpoints) inside a carrier group
# ---------------------------------------------------------------------------

@local_api.route('/carriergroups/<int:gwgroupid>/carriers', methods=['POST'])
@token_required
def add_carrier_to_group(gwgroupid):
    payload = request.get_json(silent=True) or {}
    host = payload.get('host') or payload.get('ip_addr')
    if not host:
        return _err("Field 'host' is required")
    name = payload.get('name')
    if not name:
        return _err("Field 'name' is required")

    addr = '{}:{}'.format(host, payload['port']) if payload.get('port') else host
    ep_data = {
        'gwgroupid': str(gwgroupid),
        'name': name,
        'ip_addr': addr,
        'strip': str(payload.get('strip', '')),
        'prefix': payload.get('prefix', ''),
        'rweight': payload.get('rweight', 1),
    }
    try:
        addUpdateCarriers(ep_data)
    except http_exceptions.HTTPException as ex:
        return _err(ex.description, status=ex.code or 400)
    except Exception as ex:
        return _err(str(ex), status=500)
    return _ok(msg='Carrier added', kamreload=True, status=201)


@local_api.route('/carriergroups/<int:gwgroupid>/carriers', methods=['GET'])
@token_required
def list_carriers_of_group(gwgroupid):
    db = DummySession()
    try:
        db = startSession()
        gw = db.query(GatewayGroups).filter(GatewayGroups.id == gwgroupid).first()
        if gw is None:
            return _err('Carrier group not found', status=404)
        gwids = [int(x) for x in (gw.gwlist or '').split(',') if x]
        if not gwids:
            return _ok(data=[])
        rows = db.query(Gateways).filter(Gateways.gwid.in_(gwids)).all()
        out = []
        for r in rows:
            fields = strFieldsToDict(r.description) if r.description else {}
            out.append({
                'gwid': r.gwid,
                'name': fields.get('name', ''),
                'address': r.address,
                'strip': r.strip,
                'prefix': r.pri_prefix,
            })
        return _ok(data=out)
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/carriergroups/<int:gwgroupid>/carriers/<int:gwid>', methods=['DELETE'])
@token_required
def delete_carrier_from_group(gwgroupid, gwid):
    db = DummySession()
    try:
        db = startSession()
        gw_group = db.query(GatewayGroups).filter(GatewayGroups.id == gwgroupid).first()
        if gw_group is None:
            return _err('Carrier group not found', status=404)
        gwids = [x for x in (gw_group.gwlist or '').split(',') if x]
        if str(gwid) not in gwids:
            return _err('Carrier {} not in group {}'.format(gwid, gwgroupid), status=404)

        # remove gateway, its address, and its dispatcher entry
        gw_row = db.query(Gateways).filter(Gateways.gwid == gwid).first()
        if gw_row is not None:
            gw_fields = strFieldsToDict(gw_row.description) if gw_row.description else {}
            addr_id = gw_fields.get('addr_id')
            if addr_id:
                try:
                    db.query(Address).filter(Address.id == int(addr_id)).delete(synchronize_session=False)
                except (TypeError, ValueError):
                    pass
        db.query(Gateways).filter(Gateways.gwid == gwid).delete(synchronize_session=False)
        db.query(Dispatcher).filter(
            Dispatcher.description.regexp_match(r'(^|;)gwid={}($|;)'.format(gwid))
        ).delete(synchronize_session=False)

        gwids.remove(str(gwid))
        gw_group.gwlist = ','.join(gwids)
        db.commit()

        getSharedMemoryDict(STATE_SHMEM_NAME)['kam_reload_required'] = True
        return _ok(msg='Carrier {} removed from group {}'.format(gwid, gwgroupid), kamreload=True)
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Endpoint groups (PBXs)
# ---------------------------------------------------------------------------

# Underlying business logic from the official API, unwrapped to skip the
# @api_security license gate. Same JSON shape as POST /api/v1/endpointgroups.
_addEndpointGroups = _api_routes.addEndpointGroups.__wrapped__
_updateEndpointGroups = _api_routes.updateEndpointGroups.__wrapped__
_deleteEndpointGroup = _api_routes.deleteEndpointGroup.__wrapped__
_getEndpointGroup = _api_routes.getEndpointGroup.__wrapped__
_listEndpointGroups = _api_routes.listEndpointGroups.__wrapped__


@local_api.route('/endpointgroups', methods=['POST'])
@token_required
def create_endpoint_group():
    payload = request.get_json(silent=True) or {}
    return _addEndpointGroups(data=payload)


@local_api.route('/endpointgroups', methods=['GET'])
@token_required
def list_endpoint_groups():
    return _listEndpointGroups()


@local_api.route('/endpointgroups/<int:gwgroupid>', methods=['GET'])
@token_required
def get_endpoint_group(gwgroupid):
    return _getEndpointGroup(gwgroupid)


@local_api.route('/endpointgroups/<int:gwgroupid>', methods=['PUT'])
@token_required
def update_endpoint_group(gwgroupid):
    payload = request.get_json(silent=True) or {}
    return _updateEndpointGroups(gwgroupid, data=payload)


@local_api.route('/endpointgroups/<int:gwgroupid>', methods=['DELETE'])
@token_required
def delete_endpoint_group(gwgroupid):
    return _deleteEndpointGroup(gwgroupid)


# ---------------------------------------------------------------------------
# Outbound rules (dr_rules)
# ---------------------------------------------------------------------------

# Default outbound drouting groupid used by dSIPRouter
_DEFAULT_OUTBOUND_GROUPID = '8000'


def _format_gwlist(gwgroupid=None, gwids=None, raw=None):
    """Build the dr_rules.gwlist value.
    - raw: pass-through string (for advanced usage)
    - gwgroupid: int → '#<id>'  (target a whole carrier group)
    - gwids: list[int] → CSV of gateway ids
    """
    if raw is not None:
        return str(raw)
    if gwgroupid is not None:
        return '#{}'.format(int(gwgroupid))
    if gwids:
        return ','.join(str(int(x)) for x in gwids)
    return ''


def _serialize_rule(row):
    desc = strFieldsToDict(row.description) if row.description else {}
    return {
        'ruleid': row.ruleid,
        'groupid': row.groupid,
        'prefix': row.prefix,
        'timerec': row.timerec,
        'priority': row.priority,
        'routeid': row.routeid,
        'gwlist': row.gwlist,
        'name': desc.get('name', ''),
        'description': row.description,
    }


@local_api.route('/outboundrules', methods=['GET'])
@token_required
def list_outbound_rules():
    db = DummySession()
    try:
        db = startSession()
        rows = db.query(OutboundRoutes).order_by(
            OutboundRoutes.priority.desc(), OutboundRoutes.ruleid.asc()
        ).all()
        return _ok(data=[_serialize_rule(r) for r in rows])
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/outboundrules/<int:ruleid>', methods=['GET'])
@token_required
def get_outbound_rule(ruleid):
    db = DummySession()
    try:
        db = startSession()
        row = db.query(OutboundRoutes).filter(OutboundRoutes.ruleid == ruleid).first()
        if row is None:
            return _err('Rule not found', status=404)
        return _ok(data=[_serialize_rule(row)])
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/outboundrules', methods=['POST'])
@token_required
def create_outbound_rule():
    payload = request.get_json(silent=True) or {}
    name = payload.get('name', '').strip()
    if not name:
        return _err("Field 'name' is required")

    gwlist = _format_gwlist(
        gwgroupid=payload.get('gwgroupid'),
        gwids=payload.get('gwids'),
        raw=payload.get('gwlist'),
    )
    if not gwlist:
        return _err("One of 'gwgroupid', 'gwids' or 'gwlist' is required")

    groupid = str(payload.get('groupid', _DEFAULT_OUTBOUND_GROUPID))
    prefix = payload.get('prefix', '') or ''
    timerec = payload.get('timerec', '') or ''
    routeid = payload.get('routeid', '') or ''
    try:
        priority = int(payload.get('priority', 0))
    except (TypeError, ValueError):
        return _err("Field 'priority' must be an integer")

    description = dictToStrFields({'name': name})

    db = DummySession()
    try:
        db = startSession()
        rule = OutboundRoutes(
            groupid=groupid, prefix=prefix, timerec=timerec, priority=priority,
            routeid=routeid, gwlist=gwlist, description=description,
        )
        db.add(rule)
        db.flush()
        new_id = rule.ruleid
        db.commit()
        try:
            reloadKamailio()
        except Exception:
            pass
        return _ok(
            data=[{'ruleid': new_id, 'groupid': groupid, 'gwlist': gwlist, 'name': name}],
            msg='Outbound rule created',
            kamreload=True, status=201,
        )
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/outboundrules/<int:ruleid>', methods=['PUT'])
@token_required
def update_outbound_rule(ruleid):
    payload = request.get_json(silent=True) or {}

    db = DummySession()
    try:
        db = startSession()
        rule = db.query(OutboundRoutes).filter(OutboundRoutes.ruleid == ruleid).first()
        if rule is None:
            return _err('Rule not found', status=404)

        if 'groupid' in payload:
            rule.groupid = str(payload['groupid'])
        if 'prefix' in payload:
            rule.prefix = payload['prefix'] or ''
        if 'timerec' in payload:
            rule.timerec = payload['timerec'] or ''
        if 'priority' in payload:
            try:
                rule.priority = int(payload['priority'])
            except (TypeError, ValueError):
                return _err("Field 'priority' must be an integer")
        if 'routeid' in payload:
            rule.routeid = payload['routeid'] or ''
        new_gwlist = _format_gwlist(
            gwgroupid=payload.get('gwgroupid'),
            gwids=payload.get('gwids'),
            raw=payload.get('gwlist'),
        )
        if new_gwlist:
            rule.gwlist = new_gwlist
        if 'name' in payload:
            desc = strFieldsToDict(rule.description) if rule.description else {}
            desc['name'] = payload['name']
            rule.description = dictToStrFields(desc)

        db.commit()
        try:
            reloadKamailio()
        except Exception:
            pass
        return _ok(data=[_serialize_rule(rule)], msg='Outbound rule updated', kamreload=True)
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/outboundrules/<int:ruleid>', methods=['DELETE'])
@token_required
def delete_outbound_rule(ruleid):
    db = DummySession()
    try:
        db = startSession()
        n = db.query(OutboundRoutes).filter(OutboundRoutes.ruleid == ruleid).delete(
            synchronize_session=False,
        )
        if n == 0:
            return _err('Rule not found', status=404)
        db.commit()
        try:
            reloadKamailio()
        except Exception:
            pass
        return _ok(msg='Rule {} deleted'.format(ruleid), kamreload=True)
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Inbound mapping (DIDs → PBX endpoint group)
# ---------------------------------------------------------------------------
#
# Stored in dr_rules with groupid = FLT_INBOUND (9000).
# - prefix = the DID to match
# - gwlist = "#<gwgroupid>" pointing to the destination PBX endpoint group
#
# Hard-forward / fail-forward features (dsip_hardfwd / dsip_failfwd) are not
# exposed here. Use the GUI for those advanced cases.

_FLT_INBOUND = '9000'


@local_api.route('/inboundmapping', methods=['GET'])
@token_required
def list_inbound_mappings():
    db = DummySession()
    try:
        db = startSession()
        rows = db.query(OutboundRoutes).filter(
            OutboundRoutes.groupid == _FLT_INBOUND
        ).order_by(OutboundRoutes.priority.desc(), OutboundRoutes.ruleid.asc()).all()
        return _ok(data=[_serialize_rule(r) for r in rows])
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/inboundmapping/<int:ruleid>', methods=['GET'])
@token_required
def get_inbound_mapping(ruleid):
    db = DummySession()
    try:
        db = startSession()
        row = db.query(OutboundRoutes).filter(
            OutboundRoutes.ruleid == ruleid,
            OutboundRoutes.groupid == _FLT_INBOUND,
        ).first()
        if row is None:
            return _err('Inbound mapping not found', status=404)
        return _ok(data=[_serialize_rule(row)])
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/inboundmapping', methods=['POST'])
@token_required
def create_inbound_mapping():
    payload = request.get_json(silent=True) or {}
    name = payload.get('name', '').strip()
    did = payload.get('did', payload.get('prefix', ''))
    gwgroupid = payload.get('gwgroupid')
    if not name:
        return _err("Field 'name' is required")
    if gwgroupid is None:
        return _err("Field 'gwgroupid' (target PBX endpoint group) is required")
    try:
        gwgroupid = int(gwgroupid)
    except (TypeError, ValueError):
        return _err("Field 'gwgroupid' must be an integer")

    db = DummySession()
    try:
        db = startSession()
        # sanity: gwgroupid must reference an existing endpoint group
        if db.query(GatewayGroups).filter(GatewayGroups.id == gwgroupid).first() is None:
            return _err('gwgroupid {} does not exist'.format(gwgroupid))

        rule = InboundMapping(
            groupid=_FLT_INBOUND,
            prefix=did or '',
            gwlist='#{}'.format(gwgroupid),
            description=dictToStrFields({'name': name}),
        )
        db.add(rule)
        db.flush()
        new_id = rule.ruleid
        db.commit()
        try:
            reloadKamailio()
        except Exception:
            pass
        return _ok(
            data=[{'ruleid': new_id, 'did': did, 'gwgroupid': gwgroupid, 'name': name}],
            msg='Inbound mapping created', kamreload=True, status=201,
        )
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/inboundmapping/<int:ruleid>', methods=['PUT'])
@token_required
def update_inbound_mapping(ruleid):
    payload = request.get_json(silent=True) or {}

    db = DummySession()
    try:
        db = startSession()
        rule = db.query(OutboundRoutes).filter(
            OutboundRoutes.ruleid == ruleid,
            OutboundRoutes.groupid == _FLT_INBOUND,
        ).first()
        if rule is None:
            return _err('Inbound mapping not found', status=404)

        if 'did' in payload or 'prefix' in payload:
            rule.prefix = payload.get('did', payload.get('prefix', '')) or ''
        if 'gwgroupid' in payload:
            try:
                gid = int(payload['gwgroupid'])
            except (TypeError, ValueError):
                return _err("Field 'gwgroupid' must be an integer")
            if db.query(GatewayGroups).filter(GatewayGroups.id == gid).first() is None:
                return _err('gwgroupid {} does not exist'.format(gid))
            rule.gwlist = '#{}'.format(gid)
        if 'name' in payload:
            desc = strFieldsToDict(rule.description) if rule.description else {}
            desc['name'] = payload['name']
            rule.description = dictToStrFields(desc)

        db.commit()
        try:
            reloadKamailio()
        except Exception:
            pass
        return _ok(data=[_serialize_rule(rule)], msg='Inbound mapping updated', kamreload=True)
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/inboundmapping/<int:ruleid>', methods=['DELETE'])
@token_required
def delete_inbound_mapping(ruleid):
    db = DummySession()
    try:
        db = startSession()
        n = db.query(OutboundRoutes).filter(
            OutboundRoutes.ruleid == ruleid,
            OutboundRoutes.groupid == _FLT_INBOUND,
        ).delete(synchronize_session=False)
        if n == 0:
            return _err('Inbound mapping not found', status=404)
        db.commit()
        try:
            reloadKamailio()
        except Exception:
            pass
        return _ok(msg='Inbound mapping {} deleted'.format(ruleid), kamreload=True)
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Outbound mapping / LCR (per-source carrier selection by prefix)
# ---------------------------------------------------------------------------
#
# Stored in dsip_lcr. The table is loaded as a kamailio htable named
# 'tofromprefix' in route[NEXTHOP]. For each outbound INVITE Kamailio builds
# the lookup key as:    "<from_user_prefix>-<to_user_prefix>"
# and runs longest-prefix match against dsip_lcr.pattern. If matched,
# $avp(carrier_groupid) is set to the matched dr_groupid, which then drives
# do_routing() against the dr_rules with that groupid.
#
# So an LCR row says: "calls FROM <from_prefix> TO <to_prefix> should use
# routing group <dr_groupid>" — typically a dr_groupid backed by a specific
# carrier group.

def _serialize_lcr(row):
    return {
        'pattern': row.pattern,
        'from_prefix': row.from_prefix,
        'dr_groupid': row.dr_groupid,
        'cost': float(row.cost) if row.cost is not None else 0.0,
    }


@local_api.route('/outboundmapping', methods=['GET'])
@token_required
def list_outbound_mappings():
    db = DummySession()
    try:
        db = startSession()
        rows = db.query(dSIPLCR).all()
        return _ok(data=[_serialize_lcr(r) for r in rows])
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/outboundmapping/<path:pattern>', methods=['GET'])
@token_required
def get_outbound_mapping(pattern):
    db = DummySession()
    try:
        db = startSession()
        row = db.query(dSIPLCR).filter(dSIPLCR.pattern == pattern).first()
        if row is None:
            return _err('Outbound mapping not found', status=404)
        return _ok(data=[_serialize_lcr(row)])
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/outboundmapping', methods=['POST'])
@token_required
def create_outbound_mapping():
    """
    Body:
      {
        "from_prefix": "+51",         # required
        "to_prefix":   "+1",          # optional (defaults to "")
        "pattern":     "+51-+1",      # optional, auto-built if missing
        "dr_groupid":  8001,          # required (target dr_rules groupid)
        "cost":        0.00           # optional, lower = preferred
      }
    """
    payload = request.get_json(silent=True) or {}
    from_prefix = payload.get('from_prefix', '')
    to_prefix = payload.get('to_prefix', '')
    pattern = payload.get('pattern')
    dr_groupid = payload.get('dr_groupid')
    cost = payload.get('cost', 0.0)

    if dr_groupid is None:
        return _err("Field 'dr_groupid' is required")
    if pattern is None:
        if not from_prefix and not to_prefix:
            return _err("Provide either 'pattern' or at least one of 'from_prefix'/'to_prefix'")
        pattern = '{}-{}'.format(from_prefix, to_prefix)

    db = DummySession()
    try:
        db = startSession()
        if db.query(dSIPLCR).filter(dSIPLCR.pattern == pattern).first() is not None:
            return _err("Pattern '{}' already exists, use PUT to update".format(pattern), status=409)

        row = dSIPLCR(
            pattern=pattern,
            from_prefix=from_prefix,
            dr_groupid=str(dr_groupid),
            cost=float(cost),
        )
        db.add(row)
        db.commit()
        try:
            reloadKamailio()
        except Exception:
            pass
        return _ok(data=[_serialize_lcr(row)], msg='Outbound mapping created',
                   kamreload=True, status=201)
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/outboundmapping/<path:pattern>', methods=['PUT'])
@token_required
def update_outbound_mapping(pattern):
    payload = request.get_json(silent=True) or {}

    db = DummySession()
    try:
        db = startSession()
        row = db.query(dSIPLCR).filter(dSIPLCR.pattern == pattern).first()
        if row is None:
            return _err('Outbound mapping not found', status=404)

        if 'from_prefix' in payload:
            row.from_prefix = payload['from_prefix'] or ''
        if 'dr_groupid' in payload:
            row.dr_groupid = str(payload['dr_groupid'])
        if 'cost' in payload:
            try:
                row.cost = float(payload['cost'])
            except (TypeError, ValueError):
                return _err("Field 'cost' must be numeric")

        db.commit()
        try:
            reloadKamailio()
        except Exception:
            pass
        return _ok(data=[_serialize_lcr(row)], msg='Outbound mapping updated', kamreload=True)
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/outboundmapping/<path:pattern>', methods=['DELETE'])
@token_required
def delete_outbound_mapping(pattern):
    db = DummySession()
    try:
        db = startSession()
        n = db.query(dSIPLCR).filter(dSIPLCR.pattern == pattern).delete(synchronize_session=False)
        if n == 0:
            return _err('Outbound mapping not found', status=404)
        db.commit()
        try:
            reloadKamailio()
        except Exception:
            pass
        return _ok(msg="Outbound mapping '{}' deleted".format(pattern), kamreload=True)
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Endpoint allowed destination prefixes (per-PBX outbound prefix ACL)
# ---------------------------------------------------------------------------
#
# Stored in dsip_endpoint_allowed_prefixes (one row per (gwgroupid, prefix)).
# A view dsip_endpoint_allowed_prefixes_h flattens that to one comma-fenced
# row per gwgroupid, which kamailio loads as the htable 'endpoint_prefixes'.
# The kamailio.cfg ACL block runs O(1) substring checks against that string,
# blocking outbound INVITEs whose rU prefix isn't on the allow-list.
#
# Feature is opt-in: a gwgroup with no rows in this table is unrestricted.

_PREFIX_RE = re.compile(r'^\d{3,5}$')


def _reload_endpoint_prefixes_htable():
    """Tell kamailio to reload just the endpoint_prefixes htable. Cheap (~ms)
    and DMQ-replicates to peers automatically."""
    sendJsonRpcCmd('127.0.0.1', 'htable.reload', ['endpoint_prefixes'])


@local_api.route('/endpointgroups/<int:gwgroupid>/allowed-prefixes', methods=['GET'])
@token_required
def get_allowed_prefixes(gwgroupid):
    db = DummySession()
    try:
        db = startSession()
        rows = db.execute(
            text("SELECT prefix FROM dsip_endpoint_allowed_prefixes "
                 "WHERE gwgroupid = :g ORDER BY prefix"),
            {'g': gwgroupid},
        ).fetchall()
        prefixes = [r[0] for r in rows]
        return _ok(data=[{'gwgroupid': gwgroupid, 'prefixes': prefixes}])
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/endpointgroups/<int:gwgroupid>/allowed-prefixes', methods=['PUT'])
@token_required
def set_allowed_prefixes(gwgroupid):
    """Replace the full allowed-prefix set for one gwgroup.

    Body: {"prefixes": ["301", "30245", "445"]}
    Empty list disables the ACL for this gwgroup (htable lookup returns null,
    kamailio falls through to allow). Each prefix must match ^\\d{3,5}$.
    """
    payload = request.get_json(silent=True) or {}
    prefixes = payload.get('prefixes')
    if prefixes is None or not isinstance(prefixes, list):
        return _err("Field 'prefixes' (list of strings) is required")

    cleaned = []
    seen = set()
    for p in prefixes:
        if not isinstance(p, (str, int)):
            return _err("Each prefix must be a string of 3-5 digits")
        ps = str(p).strip()
        if not _PREFIX_RE.match(ps):
            return _err("Invalid prefix '{}': must match ^\\d{{3,5}}$".format(ps))
        if ps not in seen:
            seen.add(ps)
            cleaned.append(ps)

    db = DummySession()
    try:
        db = startSession()
        if db.query(GatewayGroups).filter(GatewayGroups.id == gwgroupid).first() is None:
            return _err('Endpoint group {} not found'.format(gwgroupid), status=404)

        db.execute(
            text("DELETE FROM dsip_endpoint_allowed_prefixes WHERE gwgroupid = :g"),
            {'g': gwgroupid},
        )
        if cleaned:
            db.execute(
                text("INSERT INTO dsip_endpoint_allowed_prefixes (gwgroupid, prefix) "
                     "VALUES (:g, :p)"),
                [{'g': gwgroupid, 'p': p} for p in cleaned],
            )
        db.commit()

        try:
            _reload_endpoint_prefixes_htable()
            kamreload = True
        except Exception:
            # SQL committed; signal a deferred reload through the GUI banner
            getSharedMemoryDict(STATE_SHMEM_NAME)['kam_reload_required'] = True
            kamreload = True

        return _ok(
            data=[{'gwgroupid': gwgroupid, 'prefixes': cleaned}],
            msg='Allowed prefixes updated ({} entries)'.format(len(cleaned)),
            kamreload=kamreload,
        )
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/endpointgroups/<int:gwgroupid>/allowed-prefixes', methods=['DELETE'])
@token_required
def clear_allowed_prefixes(gwgroupid):
    """Remove all allowed-prefix rows for one gwgroup (disables the ACL)."""
    db = DummySession()
    try:
        db = startSession()
        n = db.execute(
            text("DELETE FROM dsip_endpoint_allowed_prefixes WHERE gwgroupid = :g"),
            {'g': gwgroupid},
        ).rowcount
        db.commit()

        try:
            _reload_endpoint_prefixes_htable()
            kamreload = True
        except Exception:
            getSharedMemoryDict(STATE_SHMEM_NAME)['kam_reload_required'] = True
            kamreload = True

        return _ok(
            msg='Cleared {} allowed-prefix row(s) for gwgroup {}'.format(n, gwgroupid),
            kamreload=kamreload,
        )
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Kamailio reload (manual trigger)
# ---------------------------------------------------------------------------

@local_api.route('/reload', methods=['POST'])
@token_required
def reload_kamailio():
    try:
        reloadKamailio()
        return _ok(msg='Kamailio reloaded', kamreload=True)
    except Exception as ex:
        return _err(str(ex), status=500)


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@local_api.route('/ping', methods=['GET'])
@token_required
def ping():
    return _ok(msg='pong')
PYEOF
}

install_local_api "$SRC_DIR/gui"

# ----------------------------------------------------------------------------
# 2. gui/dsiprouter.py — register the local_api blueprint
# ----------------------------------------------------------------------------
patch_dsiprouter_py() {
    local f="$SRC_DIR/gui/dsiprouter.py"
    if grep -q "from modules.local_api.routes import local_api" "$f"; then
        log "dsiprouter.py: already patched"
        return
    fi
    backup_file "$f"
    log "dsiprouter.py: registering local_api blueprint"
    python3 - "$f" <<'PYEOF'
import sys, re

p = sys.argv[1]
src = open(p).read()

# 1) import — after 'from modules.api.auth.routes import user'
if 'from modules.local_api.routes import local_api' not in src:
    src = re.sub(
        r'(from modules\.api\.auth\.routes import user\n)',
        r'\1from modules.local_api.routes import local_api\n',
        src, count=1,
    )

# 2) register_blueprint — after 'app.register_blueprint(license_manager)'
if 'app.register_blueprint(local_api)' not in src:
    src = re.sub(
        r'(app\.register_blueprint\(license_manager\)\n)',
        r'\1app.register_blueprint(local_api)\n',
        src, count=1,
    )

# 3) csrf.exempt — after 'csrf.exempt(license_manager)'
if 'csrf.exempt(local_api)' not in src:
    src = re.sub(
        r'(csrf\.exempt\(license_manager\)\n)',
        r'\1csrf.exempt(local_api)\n',
        src, count=1,
    )

open(p, 'w').write(src)
PYEOF
    grep -q "from modules.local_api.routes import local_api" "$f" \
        || die "dsiprouter.py: registration failed (anchors not found)"
    grep -q "app.register_blueprint(local_api)" "$f" \
        || die "dsiprouter.py: register_blueprint anchor not found"
    grep -q "csrf.exempt(local_api)" "$f" \
        || die "dsiprouter.py: csrf.exempt anchor not found"
}

patch_dsiprouter_py

# ----------------------------------------------------------------------------
# 3. dsiprouter.sh — -iip / -eip flags
# ----------------------------------------------------------------------------
patch_dsiprouter_sh() {
    local f="$SRC_DIR/dsiprouter.sh"
    if grep -q 'FORCE_INTERNAL_IP_ADDR' "$f"; then
        log "dsiprouter.sh: already patched"
        return
    fi
    backup_file "$f"
    log "dsiprouter.sh: adding -iip/-eip support"
    python3 - "$f" <<'PYEOF'
import sys, re

p = sys.argv[1]
src = open(p).read()
orig = src

# --- Block A: preProcessNetworkMode option parser ---------------------------
# Anchor: the `-homer ...` case ends with `;;` and is the last case before the
# inner esac. We append our two cases right after that case's `;;`.
blockA = '''                -iip|--internal-ip=*)
                    if echo "$1" | grep -q '=' 2>/dev/null; then
                        FORCE_INTERNAL_IP_ADDR=$(echo "$1" | cut -d '=' -f 2)
                        shift
                    else
                        shift
                        FORCE_INTERNAL_IP_ADDR="$1"
                        shift
                    fi
                    export FORCE_INTERNAL_IP_ADDR
                    ;;
                -eip|--external-ip=*)
                    if echo "$1" | grep -q '=' 2>/dev/null; then
                        FORCE_EXTERNAL_IP_ADDR=$(echo "$1" | cut -d '=' -f 2)
                        shift
                    else
                        shift
                        FORCE_EXTERNAL_IP_ADDR="$1"
                        shift
                    fi
                    export FORCE_EXTERNAL_IP_ADDR
                    ;;
'''
# Insert before the inner esac closing the preProcessNetworkMode loop.
# The function preProcessNetworkMode contains a `case "$1" in ... esac` inside
# `while [[ $# -gt 0 ]]; do ... done`. We anchor on that exact `esac` followed
# by `done` and the closing `fi` and function `}`.
patA = re.compile(
    r'(\n)(            esac\n        done\n    fi\n\n    # network settings determined by mode\n)',
)
m = patA.search(src)
if not m:
    sys.stderr.write("dsiprouter.sh: anchor for Block A (preProcessNetworkMode) not found\n")
    sys.exit(2)
src = src[:m.start(2)] + blockA + src[m.start(2):]

# --- Block B: setDynamicScriptSettings — apply forced IPs -------------------
blockB = '''
    # explicit IP overrides (-iip / -eip) win over any detection mode
    # NOTE: the host must actually carry the address you pass with -iip; pass -eip
    # for a public IP reached via 1:1 NAT (advertise mode) or also bound to the host
    # (use -netm 2 for true dual-bind on both interfaces)
    if [[ -n "$FORCE_INTERNAL_IP_ADDR" ]]; then
        export INTERNAL_IP_ADDR="$FORCE_INTERNAL_IP_ADDR"
        # default LAN CIDR to /24 derived from the forced address if not already set
        [[ -z "$INTERNAL_IP_NET" ]] && export INTERNAL_IP_NET="${FORCE_INTERNAL_IP_ADDR%.*}.0/24"
    fi
    if [[ -n "$FORCE_EXTERNAL_IP_ADDR" ]]; then
        export EXTERNAL_IP_ADDR="$FORCE_EXTERNAL_IP_ADDR"
        export UAC_REG_ADDR="$FORCE_EXTERNAL_IP_ADDR"
    fi

'''
# Anchor: just before the `# if the public ip address is not the same` block.
patB = re.compile(
    r'(\n)(    # if the public ip address is not the same as the internal address then enable serverside NAT\n)',
)
m = patB.search(src)
if not m:
    sys.stderr.write("dsiprouter.sh: anchor for Block B (setDynamicScriptSettings) not found\n")
    sys.exit(2)
src = src[:m.start(2)] + blockB.lstrip('\n') + src[m.start(2):]

# --- Block C: usageOptions printf ------------------------------------------
old_printf = (
    '    printf "%-30s %s\\n%-30s %s\\n%-30s %s\\n%-30s %s\\n%-30s %s\\n" \\\n'
    '        "install" "[-debug|-all|--all|-kam|--kamailio|-dsip|--dsiprouter|-rtp|--rtpengine|-dns|--dnsmasq" \\\n'
    '        " " "-dmz <pub iface>,<priv iface>|--dmz=<pub iface>,<priv iface>|-netm <mode>|--network-mode=<mode>|-homer <homerhost[:heplifyport]>|" \\\n'
    '        " " "-db <[user[:pass]@]dbhost[:port][/dbname]>|--database=<[user[:pass]@]dbhost[:port][/dbname]>|-dsipcid <num>|--dsip-clusterid=<num>|" \\\n'
)
new_printf = (
    '    printf "%-30s %s\\n%-30s %s\\n%-30s %s\\n%-30s %s\\n%-30s %s\\n%-30s %s\\n" \\\n'
    '        "install" "[-debug|-all|--all|-kam|--kamailio|-dsip|--dsiprouter|-rtp|--rtpengine|-dns|--dnsmasq" \\\n'
    '        " " "-dmz <pub iface>,<priv iface>|--dmz=<pub iface>,<priv iface>|-netm <mode>|--network-mode=<mode>|-homer <homerhost[:heplifyport]>|" \\\n'
    '        " " "-iip <internal/lan ip>|--internal-ip=<internal/lan ip>|-eip <external/wan ip>|--external-ip=<external/wan ip>|" \\\n'
    '        " " "-db <[user[:pass]@]dbhost[:port][/dbname]>|--database=<[user[:pass]@]dbhost[:port][/dbname]>|-dsipcid <num>|--dsip-clusterid=<num>|" \\\n'
)
if old_printf not in src:
    sys.stderr.write("dsiprouter.sh: anchor for Block C (usageOptions printf) not found\n")
    sys.exit(2)
src = src.replace(old_printf, new_printf, 1)

# --- Block D: processCMD — eat already-consumed -iip/-eip args --------------
blockD = '''                    # already consumed by preProcessNetworkMode, just eat the args here
                    -iip|--internal-ip=*|-eip|--external-ip=*)
                        if echo "$1" | grep -q '=' 2>/dev/null; then
                            shift
                        else
                            shift
                            shift
                        fi
                        ;;
'''
# Anchor: insert before the `-db|--database=*)` case inside processCMD's
# install branch.
patD = re.compile(r'(\n)(                    -db\|--database=\*\)\n)')
m = patD.search(src)
if not m:
    sys.stderr.write("dsiprouter.sh: anchor for Block D (processCMD) not found\n")
    sys.exit(2)
src = src[:m.start(2)] + blockD + src[m.start(2):]

if src == orig:
    sys.stderr.write("dsiprouter.sh: nothing changed (unexpected)\n")
    sys.exit(2)

open(p, 'w').write(src)
PYEOF
    grep -q 'FORCE_INTERNAL_IP_ADDR' "$f" \
        || die "dsiprouter.sh: patch failed verification"
}

patch_dsiprouter_sh

# ----------------------------------------------------------------------------
# 4. gui/templates/endpointgroups.html — hide CDR tabs (Jinja comments)
# ----------------------------------------------------------------------------
# Two `<li>` toggle entries (#cdr, #cdr2) and two `<div id="cdr"/cdr2"...>`
# panes need to be hidden. We use Jinja `{# ... #}` (not HTML `<!-- -->`) so
# nested comments inside the CDR div don't break parsing.
patch_endpointgroups_html() {
    local f="$SRC_DIR/gui/templates/endpointgroups.html"
    [[ -f "$f" ]] || { warn "endpointgroups.html not found, skipping"; return; }
    if head -1 "$f" | grep -q 'LOCAL_API_PATCH:cdr_tabs'; then
        log "endpointgroups.html: already patched"
        return
    fi
    backup_file "$f"
    log "endpointgroups.html: hiding CDR tabs"
    python3 - "$f" <<'PYEOF'
import sys, re

p = sys.argv[1]
src = open(p).read()

# Marker
if not src.lstrip().startswith('{# LOCAL_API_PATCH:cdr_tabs #}'):
    src = '{# LOCAL_API_PATCH:cdr_tabs #}\n' + src

# Wrap the two `<li>` CDR toggle entries.
li_pat = re.compile(
    r'(\s*<li role="presentation">\s*\n'
    r'\s*<a href="#cdr2?" name="cdr-toggle" data-toggle="tab">CDR</a>\s*\n'
    r'\s*</li>)',
    re.MULTILINE,
)
def li_wrap(m):
    block = m.group(1)
    if '{# LOCAL_API_PATCH-li-cdr #}' in block:
        return block
    return '\n          {# LOCAL_API_PATCH-li-cdr #}\n          {#' + block + '\n          #}'
src = li_pat.sub(li_wrap, src)

# Wrap the two `<div id="cdr"/cdr2">` panes.  Their closer is
# `</div> <!-- end of cdr  tab -->` (note the literal double-space).
div_pat = re.compile(
    r'(<div id="cdr2?" class="tab-pane fade in" name="cdr-toggle">[\s\S]*?</div>\s*<!-- end of cdr\s+tab -->)',
)
def div_wrap(m):
    block = m.group(1)
    if '{# LOCAL_API_PATCH-div-cdr #}' in block:
        return block
    return '{# LOCAL_API_PATCH-div-cdr #}\n        {#\n' + block + '\n        #}'
src = div_pat.sub(div_wrap, src)

open(p, 'w').write(src)
PYEOF
}

patch_endpointgroups_html

# ----------------------------------------------------------------------------
# 5. gui/templates/fullwidth_layout.html — hide CDR sidebar entry
# ----------------------------------------------------------------------------
patch_fullwidth_layout() {
    local f="$SRC_DIR/gui/templates/fullwidth_layout.html"
    [[ -f "$f" ]] || { warn "fullwidth_layout.html not found, skipping"; return; }
    if grep -q 'LOCAL_API_PATCH:cdr_menu' "$f"; then
        log "fullwidth_layout.html: already patched"
        return
    fi
    backup_file "$f"
    log "fullwidth_layout.html: hiding CDR sidebar entry"
    python3 - "$f" <<'PYEOF'
import sys, re

p = sys.argv[1]
src = open(p).read()

# The CDR sidebar entry is the <li class="nav-header"> block that links to
# /cdrs. Match the exact 7-line shape of a nav-header so we don't span across
# adjacent menu entries (Outbound Routes, Number Enrichment, … all share the
# fa-file-image-o icon).
pat = re.compile(
    r'(\n)(\s*<li class="nav-header">\s*\n'
    r'\s*<div class="link">\s*\n'
    r'\s*<i class="fa[^"]*"></i>\s*\n'
    r'\s*<a class="navlink" href="/cdrs">Call Detail Records</a>\s*\n'
    r'\s*<i class="fa fa-chevron-down"></i>\s*\n'
    r'\s*</div>\s*\n'
    r'\s*</li>\n)',
)
m = pat.search(src)
if m is None:
    sys.stderr.write("fullwidth_layout.html: CDR sidebar anchor not found\n")
    sys.exit(2)

block = m.group(2)
wrapped = (
    '          {# LOCAL_API_PATCH:cdr_menu — Call Detail Records hidden #}\n'
    '          {#\n' + block + '          #}\n\n'
)
src = src[:m.start(2)] + wrapped + src[m.end(2):]
open(p, 'w').write(src)
PYEOF
}

patch_fullwidth_layout

# ----------------------------------------------------------------------------
# 6. Endpoint allowed-prefixes ACL — schema (table + view)
# ----------------------------------------------------------------------------
# Idempotent: CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE VIEW. We run this
# through the dSIPRouter venv python so we reuse the GUI's DB session/config —
# no need to source ROOT_DB_* env vars or shell out to mysql.
apply_prefix_acl_schema() {
    local venv_py="/opt/dsiprouter/venv/bin/python3"
    if [[ ! -x "$venv_py" ]]; then
        warn "venv python not found at $venv_py — skipping prefix ACL schema"
        warn "                                       (re-run after dsiprouter is installed)"
        return
    fi
    log "prefix ACL schema: applying to kam DB (idempotent)"
    "$venv_py" - <<'PYEOF'
import os, sys
# Same path setup as gui/dsiprouter.py: settings.py is shipped under /etc,
# but the rest of the code (database.py, shared.py, ...) lives under /opt.
os.chdir('/opt/dsiprouter/gui')
sys.path.insert(0, '/opt/dsiprouter/gui')
sys.path.insert(0, '/etc/dsiprouter/gui')
from sqlalchemy import text
from database import startSession, DummySession

DDL = [
    """CREATE TABLE IF NOT EXISTS dsip_endpoint_allowed_prefixes (
        gwgroupid INT UNSIGNED NOT NULL,
        prefix    VARCHAR(8)   NOT NULL,
        PRIMARY KEY (gwgroupid, prefix),
        KEY idx_gwgroupid (gwgroupid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8""",

    # View shape mirrors dsip_call_settings_h: htable expects key column first
    # ('gwgroupid'), value column second ('prefixes'). The leading/trailing
    # commas turn each entry into ',NNN,' so kamailio can do exact-substring
    # match without worrying about partial collisions (e.g. '301' vs '3012').
    """DROP VIEW IF EXISTS dsip_endpoint_allowed_prefixes_h""",
    """CREATE VIEW dsip_endpoint_allowed_prefixes_h AS
        SELECT
          CAST(gwgroupid AS char) AS gwgroupid,
          CONCAT(',', GROUP_CONCAT(prefix ORDER BY prefix SEPARATOR ','), ',') AS prefixes
        FROM dsip_endpoint_allowed_prefixes
        GROUP BY gwgroupid""",
]

db = DummySession()
try:
    db = startSession()
    for stmt in DDL:
        db.execute(text(stmt))
    db.commit()
    print('[prefix_acl] schema OK')
except Exception as ex:
    db.rollback()
    sys.stderr.write('[prefix_acl] schema FAILED: %s\n' % ex)
    sys.exit(2)
finally:
    db.close()
PYEOF
}

apply_prefix_acl_schema

# ----------------------------------------------------------------------------
# 7. kamailio.cfg — add endpoint_prefixes htable + outbound prefix ACL check
# ----------------------------------------------------------------------------
# Patches BOTH:
#   - source-of-truth: $SRC_DIR/kamailio/configs/kamailio.cfg
#   - runtime:         /etc/dsiprouter/kamailio/kamailio.cfg
# so the change survives upgrades and takes effect immediately.
#
# Marker:  # LOCAL_API_PATCH:prefix_acl
# Two insertions per file:
#   A) htable definition near the other dsip-managed htables
#   B) ACL check inside route[SET_CALLSRC_INFO], after src_gwgroupid resolution
patch_kamailio_cfg_file() {
    local f="$1"
    [[ -f "$f" ]] || { warn "kamailio cfg not found: $f"; return; }
    if grep -q 'LOCAL_API_PATCH:prefix_acl' "$f"; then
        log "kamailio.cfg: already patched ($f)"
        return
    fi
    backup_file "$f"
    log "kamailio.cfg: patching $f"
    python3 - "$f" <<'PYEOF'
import sys, re

p = sys.argv[1]
src = open(p).read()
orig = src

# --- Block A: htable definition --------------------------------------------
# Anchor on the prefix_to_route htable — it's a stable, dsip-managed line
# that's always present. We append our endpoint_prefixes line right after it.
htable_anchor = re.compile(
    r'(modparam\("htable", "htable", "prefix_to_route=>[^\n]*\n)'
)
htable_line = (
    '# LOCAL_API_PATCH:prefix_acl — outbound destination prefix ACL per gwgroup\n'
    '# Loaded from view dsip_endpoint_allowed_prefixes_h (one row per gwgroupid).\n'
    '# Value is a comma-fenced string ",p1,p2,p3," for O(1) substring checks.\n'
    'modparam("htable", "htable", "endpoint_prefixes=>size=8;autoexpire=0;'
    'dmqreplicate=DMQ_REPLICATE_ENABLED;dbtable=dsip_endpoint_allowed_prefixes_h;'
    'cols=\'gwgroupid,prefixes\';colnull=\'\';")\n'
)
m = htable_anchor.search(src)
if m is None:
    sys.stderr.write("kamailio.cfg: prefix_to_route htable anchor not found\n")
    sys.exit(2)
src = src[:m.end(1)] + htable_line + src[m.end(1):]

# --- Block B: ACL check in route[SET_CALLSRC_INFO] --------------------------
# Insert after the WITH_CALL_SETTINGS block (which sets call limits/timeout
# from the same gwgroupid) and before the hardfwd/failfwd reset. The call
# graph at this point: src_gwgroupid is resolved, dlg vars are set, and we're
# still in route[SET_CALLSRC_INFO] which runs once per fresh INVITE.
acl_check = (
    '\n'
    '\t# LOCAL_API_PATCH:prefix_acl — outbound destination prefix ACL\n'
    '\t# Opt-in per endpoint group: if the gwgroup has no rows in\n'
    '\t# dsip_endpoint_allowed_prefixes the htable lookup returns $null and\n'
    '\t# the call is allowed. With rows, only RURI users whose 3/4/5-digit\n'
    '\t# prefix appears in the allow-list pass.\n'
    '\tif (is_method("INVITE") && $dlg_var(src_gwgroupid) != $null && '
    'strlen($dlg_var(src_gwgroupid)) > 0) {\n'
    '\t\t$var(allowed_prefixes) = $sht(endpoint_prefixes=>$dlg_var(src_gwgroupid));\n'
    '\t\tif ($var(allowed_prefixes) != $null && strlen($var(allowed_prefixes)) > 0) {\n'
    '\t\t\t$var(p3) = $(rU{s.substr,0,3});\n'
    '\t\t\t$var(p4) = $(rU{s.substr,0,4});\n'
    '\t\t\t$var(p5) = $(rU{s.substr,0,5});\n'
    '\t\t\tif (!($var(allowed_prefixes) =~ ",$var(p3),") &&\n'
    '\t\t\t    !($var(allowed_prefixes) =~ ",$var(p4),") &&\n'
    '\t\t\t    !($var(allowed_prefixes) =~ ",$var(p5),")) {\n'
    '\t\t\t\txlog("L_INFO","[$ci] endpoint_prefixes ACL '
    'block: gwgroup=$dlg_var(src_gwgroupid) rU=$rU\\n");\n'
    '\t\t\t\tsend_reply("403","Forbidden destination prefix");\n'
    '\t\t\t\texit;\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '\t}\n'
)
# Anchor on the line that resets hardfwdinfo/failfwdinfo at the tail of
# route[SET_CALLSRC_INFO]. It's a stable, low-churn anchor right after the
# WITH_CALL_SETTINGS #!endif.
acl_anchor = re.compile(
    r'(\n)(\t# set call forwarding info to null by default\n'
    r'\t\$avp\(hardfwdinfo\) = \$null;\n)'
)
m = acl_anchor.search(src)
if m is None:
    sys.stderr.write("kamailio.cfg: SET_CALLSRC_INFO ACL anchor not found\n")
    sys.exit(2)
src = src[:m.end(1)] + acl_check + src[m.start(2):]

if src == orig:
    sys.stderr.write("kamailio.cfg: nothing changed (unexpected)\n")
    sys.exit(2)

open(p, 'w').write(src)
PYEOF
    grep -q 'LOCAL_API_PATCH:prefix_acl' "$f" \
        || die "kamailio.cfg: patch failed verification ($f)"
}

patch_kamailio_cfg() {
    patch_kamailio_cfg_file "$SRC_DIR/kamailio/configs/kamailio.cfg"
    # The runtime cfg is the file kamailio actually loads; symlinked from
    # /etc/kamailio/kamailio.cfg. dsiprouter installs the source cfg here on
    # install/upgrade and then runs setKamailioConfigSubst against it.
    patch_kamailio_cfg_file "/etc/dsiprouter/kamailio/kamailio.cfg"
}

patch_kamailio_cfg

# ----------------------------------------------------------------------------
# 8. endpointgroups.html — Allowed Destination Prefixes textarea + JS
# ----------------------------------------------------------------------------
# Adds a textarea inside the existing "Call Settings" tab (both the add and
# edit modals) and an inline <script> at the bottom of the template that
# loads / saves the prefix list against /api/local/v1 (session-authenticated).
# Does NOT touch endpointgroups.js or the Python handler — those stay vanilla
# upstream so future merges are clean.
patch_endpointgroups_prefix_ui() {
    local f="$SRC_DIR/gui/templates/endpointgroups.html"
    [[ -f "$f" ]] || { warn "endpointgroups.html not found, skipping prefix UI"; return; }
    if grep -q 'LOCAL_API_PATCH:prefix_acl_ui' "$f"; then
        log "endpointgroups.html: prefix UI already patched"
        return
    fi
    backup_file "$f"
    log "endpointgroups.html: injecting allowed-prefixes UI"
    python3 - "$f" <<'PYEOF'
import sys, re

p = sys.argv[1]
src = open(p).read()
orig = src

# Marker (separate from cdr_tabs — both can coexist)
if 'LOCAL_API_PATCH:prefix_acl_ui' not in src:
    # we'll place a marker comment near the script block we add at EOF
    pass

textarea_block_add = (
    '          {# LOCAL_API_PATCH:prefix_acl_ui — Allowed Destination Prefixes (add) #}\n'
    '          <div class="form-group">\n'
    '            <label for="allowed_prefixes_add" style="font-weight:normal">\n'
    '              Allowed Destination Prefixes\n'
    '              <small class="text-muted">(3–5 digits, one per line or comma-separated; '
    'leave blank to allow any)</small>\n'
    '            </label>\n'
    '            <textarea id="allowed_prefixes_add" class="allowed_prefixes form-control" '
    'name="allowed_prefixes" rows="4" placeholder="301&#10;30245&#10;445"></textarea>\n'
    '          </div>\n'
)
textarea_block_edit = textarea_block_add.replace(
    'allowed_prefixes_add', 'allowed_prefixes_edit'
).replace('Allowed Destination Prefixes (add)', 'Allowed Destination Prefixes (edit)')

# Insert right before `</div> <!-- end of call settings tab -->` in BOTH panes
# (add modal `#call_settings`, edit modal `#call_settings2`). The two closers
# look identical, so we have to anchor on the surrounding div id.
def insert_into_pane(src, pane_id, block):
    # match: <div id="<pane>" ... up to next `</div> <!-- end of call settings tab -->`
    pat = re.compile(
        r'(<div id="' + re.escape(pane_id) + r'"[^>]*>[\s\S]*?)'
        r'(</div>\s*<!-- end of call settings tab -->)',
        re.MULTILINE,
    )
    m = pat.search(src)
    if m is None:
        sys.stderr.write("endpointgroups.html: pane anchor #%s not found\n" % pane_id)
        sys.exit(2)
    if 'LOCAL_API_PATCH:prefix_acl_ui' in m.group(1):
        return src  # already injected
    return src[:m.end(1)] + block + '        ' + src[m.start(2):]

# Naming convention in this template: panes WITHOUT the "2" suffix belong to
# the EDIT modal (#edit), panes WITH "2" belong to the ADD modal (#add).
src = insert_into_pane(src, 'call_settings',  textarea_block_edit)
src = insert_into_pane(src, 'call_settings2', textarea_block_add)

# JS block: appended at end of file. Wires up:
#  - on edit-modal show: GET /api/local/v1/endpointgroups/<id>/allowed-prefixes
#  - on successful POST /api/v1/endpointgroups: PUT prefixes for the new id
#  - on successful PUT  /api/v1/endpointgroups/<id>: PUT prefixes for that id
js_marker = '/* LOCAL_API_PATCH:prefix_acl_ui */'
js_block = '''
<script type="application/javascript">
{js_marker}
(function() {{
  if (window.__localApiPrefixAclWired) return;
  window.__localApiPrefixAclWired = true;

  function localApiBase() {{
    // API_BASE_URL is "<scheme>://<host>:<port>/api/v1/" — swap to /api/local/v1/
    if (typeof API_BASE_URL !== "string") return null;
    return API_BASE_URL.replace(/\\/api\\/v1\\/?$/, "/api/local/v1/");
  }}

  function parsePrefixes(raw) {{
    if (!raw) return [];
    return raw.split(/[\\s,;]+/).map(function(x) {{ return x.trim(); }})
              .filter(function(x) {{ return x.length > 0; }});
  }}

  function renderPrefixes(arr) {{
    return (arr || []).join('\\n');
  }}

  function loadPrefixesFor(gwgroupid, $textarea) {{
    var base = localApiBase();
    if (!base || !gwgroupid) return;
    $.ajax({{
      type: "GET",
      url: base + "endpointgroups/" + gwgroupid + "/allowed-prefixes",
      dataType: "json",
      success: function(resp) {{
        var p = (resp && resp.data && resp.data[0] && resp.data[0].prefixes) || [];
        $textarea.val(renderPrefixes(p));
      }},
      error: function(xhr) {{
        // Most likely cause: feature not yet enabled (table missing) — leave blank.
        if (window.console) console.warn("allowed-prefixes load failed", xhr.status);
      }}
    }});
  }}

  function savePrefixesFor(gwgroupid, prefixes, cb) {{
    var base = localApiBase();
    if (!base || !gwgroupid) {{ if (cb) cb(); return; }}
    $.ajax({{
      type: "PUT",
      url: base + "endpointgroups/" + gwgroupid + "/allowed-prefixes",
      dataType: "json",
      contentType: "application/json; charset=utf-8",
      data: JSON.stringify({{ prefixes: prefixes }}),
      success: function() {{ if (cb) cb(); }},
      error: function(xhr) {{
        if (window.console) console.error("allowed-prefixes save failed", xhr.status, xhr.responseText);
        if (cb) cb();
      }}
    }});
  }}

  // Edit-modal show: pull current prefixes for the group being edited.
  $(document).on('show.bs.modal', '#edit', function() {{
    var $modal = $(this);
    // gwgroupid is set by displayEndpointGroup before the modal fully shows;
    // give it a tick so the hidden field is populated.
    setTimeout(function() {{
      var id = $modal.find('.gwgroupid').val();
      var $ta = $modal.find('#allowed_prefixes_edit');
      $ta.val('');
      loadPrefixesFor(id, $ta);
    }}, 50);
  }});

  // Add-modal hidden: clear the textarea (clearEndpointGroupModal doesn't know about it).
  $(document).on('hidden.bs.modal', '#add', function() {{
    $(this).find('#allowed_prefixes_add').val('');
  }});

  // After upstream save (POST or PUT against /api/v1/endpointgroups), push our prefixes.
  $(document).ajaxSuccess(function(event, xhr, opts) {{
    if (!opts || !opts.url) return;
    var url = opts.url;
    var m = url.match(/\\/api\\/v1\\/endpointgroups(?:\\/(\\d+))?(?:\\?|$)/);
    if (!m) return;
    var method = (opts.type || 'GET').toUpperCase();
    if (method !== 'POST' && method !== 'PUT') return;

    var gwgroupid = m[1];
    var $ta;
    if (method === 'POST') {{
      // gwgroupid is in the response payload
      try {{
        var resp = (typeof xhr.responseJSON !== 'undefined')
          ? xhr.responseJSON
          : JSON.parse(xhr.responseText || '{{}}');
        gwgroupid = (resp && resp.data && resp.data[0] && resp.data[0].gwgroupid) || null;
      }} catch(e) {{ gwgroupid = null; }}
      $ta = $('#allowed_prefixes_add');
    }} else {{
      $ta = $('#allowed_prefixes_edit');
    }}
    if (!gwgroupid) return;

    var prefixes = parsePrefixes($ta.val());
    // Validate: digits-only, 3–5 chars
    var bad = prefixes.filter(function(p) {{ return !/^\\d{{3,5}}$/.test(p); }});
    if (bad.length > 0) {{
      alert("Invalid prefix(es) — must be 3–5 digits each: " + bad.join(', '));
      return;
    }}
    savePrefixesFor(gwgroupid, prefixes, function() {{
      if (typeof reloadKamRequired === 'function') reloadKamRequired(true);
    }});
  }});
}})();
</script>
'''.format(js_marker=js_marker)

if js_marker not in src:
    # Inject inside the dedicated `{% block custom_js %}...{% endblock %}` so we
    # land at the bottom of the page's JS, not in the page <title> block. Match
    # the open and the matching close as a unit.
    custom_js_pat = re.compile(
        r'(\{%\s*block\s+custom_js\s*%\}\n)([\s\S]*?)(\n?\{%\s*endblock\s*%\})'
    )
    cm = custom_js_pat.search(src)
    if cm is None:
        # Fallback: append to file (template doesn't have custom_js block)
        sys.stderr.write("endpointgroups.html: custom_js block not found, appending JS at EOF\n")
        src = src + js_block
    else:
        existing_body = cm.group(2)
        new_body = existing_body + js_block
        src = src[:cm.start(2)] + new_body + src[cm.end(2):]

open(p, 'w').write(src)
PYEOF
    grep -q 'LOCAL_API_PATCH:prefix_acl_ui' "$f" \
        || die "endpointgroups.html: prefix UI patch failed verification"
}

patch_endpointgroups_prefix_ui

# ============================================================================
# 8b. Outbound Prefix Manipulation (per-(gwgroup, prefix) RURI strip + prepend)
#
#  Marker: LOCAL_API_PATCH:outbound_prefix_rules{,_ui}
#  Files touched (idempotent):
#    - DB:                   dsip_endpoint_outbound_prefix + view _h
#    - kamailio.cfg:         htable modparam + manipulation block in
#                            route[SET_CALLSRC_INFO] (before prefix ACL)
#    - routes.py:            GET/PUT/DELETE /endpointgroups/<id>/outbound-prefix-rules
#    - endpointgroups.html:  3-column table UI in Call Settings tab + JS
# ============================================================================

# ---------- 8b.1 Schema -----------------------------------------------------
apply_outbound_prefix_schema() {
    local venv_py="/opt/dsiprouter/venv/bin/python3"
    if [[ ! -x "$venv_py" ]]; then
        warn "venv python not found at $venv_py — skipping outbound_prefix schema"
        return
    fi
    log "outbound_prefix schema: applying to kam DB (idempotent)"
    "$venv_py" - <<'PYEOF'
import os, sys
os.chdir('/opt/dsiprouter/gui')
sys.path.insert(0, '/opt/dsiprouter/gui')
sys.path.insert(0, '/etc/dsiprouter/gui')
from sqlalchemy import text
from database import startSession, DummySession

DDL = [
    """CREATE TABLE IF NOT EXISTS dsip_endpoint_outbound_prefix (
        id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
        gwgroupid   INT UNSIGNED NOT NULL,
        prefix      VARCHAR(8)   NOT NULL,
        strip       INT          NOT NULL DEFAULT 0,
        pri_prefix  VARCHAR(32)  NOT NULL DEFAULT '',
        PRIMARY KEY (id),
        UNIQUE KEY uq_gwgroup_prefix (gwgroupid, prefix)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8""",

    """DROP VIEW IF EXISTS dsip_endpoint_outbound_prefix_h""",
    """CREATE VIEW dsip_endpoint_outbound_prefix_h AS
        SELECT CONCAT(gwgroupid, ':', prefix) AS k,
               CONCAT(strip, ',', pri_prefix)  AS v
        FROM dsip_endpoint_outbound_prefix""",
]

db = DummySession()
try:
    db = startSession()
    for stmt in DDL:
        db.execute(text(stmt))
    db.commit()
    print('[outbound_prefix] schema OK')
except Exception as ex:
    db.rollback()
    sys.stderr.write('[outbound_prefix] schema FAILED: %s\n' % ex)
    sys.exit(2)
finally:
    db.close()
PYEOF
}

apply_outbound_prefix_schema

# ---------- 8b.2 kamailio.cfg ----------------------------------------------
patch_kamailio_cfg_outbound_prefix_file() {
    local f="$1"
    [[ -f "$f" ]] || { warn "kamailio cfg not found: $f"; return; }
    if grep -q 'LOCAL_API_PATCH:outbound_prefix_rules' "$f"; then
        log "kamailio.cfg: outbound_prefix already patched ($f)"
        return
    fi
    backup_file "$f"
    log "kamailio.cfg: patching outbound_prefix into $f"
    python3 - "$f" <<'PYEOF'
import sys, re

p = sys.argv[1]
src = open(p).read()
orig = src

# --- Block A: htable definition (anchor on the prefix_acl htable) -----------
htable_anchor = re.compile(
    r'(modparam\("htable", "htable", "endpoint_prefixes=>[^\n]*\n)'
)
htable_line = (
    '# LOCAL_API_PATCH:outbound_prefix_rules — per-(gwgroup, prefix) RURI manipulation\n'
    '# Loaded from view dsip_endpoint_outbound_prefix_h. Key = "gwgroupid:prefix",\n'
    '# value = "strip,pri_prefix". Cfg matches the longest dialed-prefix (1..8 digits)\n'
    '# and applies strip + pri_prefix to $rU before drouting runs.\n'
    'modparam("htable", "htable", "outbound_prefix=>size=8;autoexpire=0;'
    'dmqreplicate=DMQ_REPLICATE_ENABLED;dbtable=dsip_endpoint_outbound_prefix_h;'
    'cols=\'k,v\';colnull=\'\';")\n'
)
m = htable_anchor.search(src)
if m is None:
    sys.stderr.write("kamailio.cfg: endpoint_prefixes htable anchor not found\n")
    sys.exit(2)
src = src[:m.end(1)] + htable_line + src[m.end(1):]

# --- Block B: manipulation block in SET_CALLSRC_INFO -----------------------
# Anchor: the prefix_acl block we already added. Insert manipulation BEFORE it
# so the ACL sees the post-strip rU.
manip_block = (
    '\t# LOCAL_API_PATCH:outbound_prefix_rules — per-(gwgroup, prefix) RURI manipulation\n'
    '\t# Opt-in per endpoint group. For src_gwgroupid X, look up keys\n'
    '\t#   X:p8, X:p7, …, X:p1\n'
    '\t# in htable outbound_prefix (longest match wins). Value format "<strip>,<prepend>".\n'
    '\t# Substring lengths and strip counts are unrolled because Kamailio\'s\n'
    '\t# s.substr transformation requires literal integer arguments.\n'
    '\tif (is_method("INVITE") && $dlg_var(src_gwgroupid) != $null && '
    'strlen($dlg_var(src_gwgroupid)) > 0) {\n'
    '\t\t$var(_gw) = $dlg_var(src_gwgroupid);\n'
    '\t\t$var(_rUlen) = $(rU{s.len});\n'
    '\t\t$var(_prule) = "";\n'
    '\t\t$var(_p) = "";\n'
)
# unrolled length checks 8 → 1
for n in (8, 7, 6, 5, 4, 3, 2, 1):
    cond = '$var(_rUlen) >= %d' % n if n == 8 else (
        'strlen($var(_prule)) == 0 && $var(_rUlen) >= %d' % n
    )
    manip_block += (
        '\t\tif (' + cond + ') {\n'
        '\t\t\t$var(_p) = $(rU{s.substr,0,' + str(n) + '});\n'
        '\t\t\t$var(_pkey) = $var(_gw) + ":" + $var(_p);\n'
        '\t\t\t$var(_prule) = $sht(outbound_prefix=>$var(_pkey));\n'
        '\t\t\tif (strlen($var(_prule)) < 2) { $var(_prule) = ""; }\n'
        '\t\t}\n'
    )
manip_block += (
    '\t\tif (strlen($var(_prule)) > 1) {\n'
    '\t\t\t$var(_strip) = (int)$(var(_prule){s.select,0,,});\n'
    '\t\t\t$var(_pre)   = $(var(_prule){s.select,1,,});\n'
)
# unrolled strip 1 → 8
for n in range(1, 9):
    branch = 'if' if n == 1 else 'else if'
    manip_block += (
        '\t\t\t' + branch + ' ($var(_strip) == ' + str(n) + ') '
        '{ $rU = $(rU{s.substr,' + str(n) + ',0}); }\n'
    )
manip_block += (
    '\t\t\tif (strlen($var(_pre)) > 0) {\n'
    '\t\t\t\t$rU = $var(_pre) + $rU;\n'
    '\t\t\t}\n'
    '\t\t\txlog("L_INFO","[$ci] outbound_prefix manip: '
    'gwgroup=$var(_gw) match=$var(_p) strip=$var(_strip) prepend=$var(_pre) → rU=$rU\\n");\n'
    '\t\t}\n'
    '\t}\n'
    '\n'
)

acl_anchor = re.compile(
    r'(\n)(\t# LOCAL_API_PATCH:prefix_acl — outbound destination prefix ACL\n)'
)
m = acl_anchor.search(src)
if m is None:
    sys.stderr.write("kamailio.cfg: prefix_acl anchor not found (apply prefix_acl first)\n")
    sys.exit(2)
src = src[:m.end(1)] + manip_block + src[m.start(2):]

if src == orig:
    sys.stderr.write("kamailio.cfg: outbound_prefix nothing changed (unexpected)\n")
    sys.exit(2)

open(p, 'w').write(src)
PYEOF
    grep -q 'LOCAL_API_PATCH:outbound_prefix_rules' "$f" \
        || die "kamailio.cfg: outbound_prefix patch failed verification ($f)"
}

patch_kamailio_cfg_outbound_prefix() {
    patch_kamailio_cfg_outbound_prefix_file "$SRC_DIR/kamailio/configs/kamailio.cfg"
    patch_kamailio_cfg_outbound_prefix_file "/etc/dsiprouter/kamailio/kamailio.cfg"
}

patch_kamailio_cfg_outbound_prefix

# ---------- 8b.3 routes.py — REST API ---------------------------------------
patch_local_api_outbound_prefix_routes() {
    local f="$SRC_DIR/gui/modules/local_api/routes.py"
    [[ -f "$f" ]] || { warn "local_api/routes.py not found"; return; }
    if grep -q 'LOCAL_API_PATCH:outbound_prefix_rules' "$f"; then
        log "routes.py: outbound_prefix already patched"
        return
    fi
    backup_file "$f"
    log "routes.py: injecting outbound_prefix_rules routes"
    python3 - "$f" <<'PYEOF'
import sys, re

p = sys.argv[1]
src = open(p).read()

block = '''# ---------------------------------------------------------------------------
# LOCAL_API_PATCH:outbound_prefix_rules
# Per-(gwgroup, dialed-prefix) outbound RURI manipulation. Each rule has:
#   prefix       — 1..8 digit dialed-prefix to match
#   strip        — number of leading digits to remove from RURI before forward
#   pri_prefix   — optional string to prepend to the (possibly stripped) RURI
#
# Stored in dsip_endpoint_outbound_prefix. View dsip_endpoint_outbound_prefix_h
# is loaded into the kamailio htable 'outbound_prefix' with key
# "<gwgroupid>:<prefix>" → "<strip>,<pri_prefix>".
# Feature is opt-in: a gwgroup with no rows passes through unchanged.
# ---------------------------------------------------------------------------

_OUTBOUND_PREFIX_RE  = re.compile(r'^\\d{1,8}$')
_OUTBOUND_PREPEND_RE = re.compile(r'^[\\w+#*\\-]{0,32}$')


def _reload_outbound_prefix_htable():
    """Tell kamailio to reload just the outbound_prefix htable. ~ms cost."""
    sendJsonRpcCmd('127.0.0.1', 'htable.reload', ['outbound_prefix'])


def _validate_outbound_rule(rule):
    """Returns (cleaned_dict, error_str). One must be None."""
    if not isinstance(rule, dict):
        return None, "rule must be an object"
    prefix = str(rule.get('prefix', '')).strip()
    if not _OUTBOUND_PREFIX_RE.match(prefix):
        return None, "invalid prefix '{}': must match ^\\\\d{{1,8}}$".format(prefix)
    try:
        strip = int(rule.get('strip', 0) or 0)
    except (TypeError, ValueError):
        return None, "strip must be an integer"
    if strip < 0 or strip > 8:
        return None, "strip out of range (0..8): {}".format(strip)
    pri_prefix = str(rule.get('pri_prefix', '') or '').strip()
    if not _OUTBOUND_PREPEND_RE.match(pri_prefix):
        return None, "invalid pri_prefix '{}': allowed [A-Za-z0-9_+#*-], up to 32 chars".format(pri_prefix)
    return {'prefix': prefix, 'strip': strip, 'pri_prefix': pri_prefix}, None


@local_api.route('/endpointgroups/<int:gwgroupid>/outbound-prefix-rules', methods=['GET'])
@token_required
def get_outbound_prefix_rules(gwgroupid):
    db = DummySession()
    try:
        db = startSession()
        rows = db.execute(
            text("SELECT prefix, strip, pri_prefix "
                 "FROM dsip_endpoint_outbound_prefix "
                 "WHERE gwgroupid = :g ORDER BY CHAR_LENGTH(prefix) DESC, prefix"),
            {'g': gwgroupid},
        ).fetchall()
        rules = [
            {'prefix': r[0], 'strip': int(r[1]), 'pri_prefix': r[2] or ''}
            for r in rows
        ]
        return _ok(data=[{'gwgroupid': gwgroupid, 'rules': rules}])
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/endpointgroups/<int:gwgroupid>/outbound-prefix-rules', methods=['PUT'])
@token_required
def set_outbound_prefix_rules(gwgroupid):
    """Replace the full outbound-prefix rule set for one gwgroup.

    Body: {"rules": [{"prefix":"6661","strip":4,"pri_prefix":"+51"}, ...]}
    Empty list disables the feature for this gwgroup.
    """
    payload = request.get_json(silent=True) or {}
    rules = payload.get('rules')
    if rules is None or not isinstance(rules, list):
        return _err("Field 'rules' (list of objects) is required")

    cleaned = []
    seen = set()
    for rule in rules:
        c, err = _validate_outbound_rule(rule)
        if err:
            return _err(err)
        if c['prefix'] in seen:
            return _err("duplicate prefix '{}'".format(c['prefix']))
        seen.add(c['prefix'])
        cleaned.append(c)

    db = DummySession()
    try:
        db = startSession()
        if db.query(GatewayGroups).filter(GatewayGroups.id == gwgroupid).first() is None:
            return _err('Endpoint group {} not found'.format(gwgroupid), status=404)

        db.execute(
            text("DELETE FROM dsip_endpoint_outbound_prefix WHERE gwgroupid = :g"),
            {'g': gwgroupid},
        )
        if cleaned:
            db.execute(
                text("INSERT INTO dsip_endpoint_outbound_prefix "
                     "(gwgroupid, prefix, strip, pri_prefix) "
                     "VALUES (:g, :p, :s, :pp)"),
                [
                    {'g': gwgroupid, 'p': r['prefix'],
                     's': r['strip'], 'pp': r['pri_prefix']}
                    for r in cleaned
                ],
            )
        db.commit()

        try:
            _reload_outbound_prefix_htable()
            kamreload = True
        except Exception:
            getSharedMemoryDict(STATE_SHMEM_NAME)['kam_reload_required'] = True
            kamreload = True

        return _ok(
            data=[{'gwgroupid': gwgroupid, 'rules': cleaned}],
            msg='Outbound prefix rules updated ({} rule(s))'.format(len(cleaned)),
            kamreload=kamreload,
        )
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


@local_api.route('/endpointgroups/<int:gwgroupid>/outbound-prefix-rules', methods=['DELETE'])
@token_required
def clear_outbound_prefix_rules(gwgroupid):
    """Remove all outbound-prefix rules for one gwgroup (disables feature)."""
    db = DummySession()
    try:
        db = startSession()
        n = db.execute(
            text("DELETE FROM dsip_endpoint_outbound_prefix WHERE gwgroupid = :g"),
            {'g': gwgroupid},
        ).rowcount
        db.commit()

        try:
            _reload_outbound_prefix_htable()
            kamreload = True
        except Exception:
            getSharedMemoryDict(STATE_SHMEM_NAME)['kam_reload_required'] = True
            kamreload = True

        return _ok(
            msg='Cleared {} outbound-prefix rule(s) for gwgroup {}'.format(n, gwgroupid),
            kamreload=kamreload,
        )
    except Exception as ex:
        db.rollback()
        return _err(str(ex), status=500)
    finally:
        db.close()


'''
# Anchor: the manual reload block at the tail of routes.py.
anchor = re.compile(
    r'(# -+\n# Kamailio reload \(manual trigger\)\n# -+\n)'
)
m = anchor.search(src)
if m is None:
    sys.stderr.write("routes.py: reload anchor not found\n")
    sys.exit(2)
src = src[:m.start(1)] + block + src[m.start(1):]

open(p, 'w').write(src)
PYEOF
    grep -q 'LOCAL_API_PATCH:outbound_prefix_rules' "$f" \
        || die "routes.py: outbound_prefix patch failed verification"
}

patch_local_api_outbound_prefix_routes

# ---------- 8b.4 endpointgroups.html — UI table + JS ------------------------
patch_endpointgroups_outbound_prefix_ui() {
    local f="$SRC_DIR/gui/templates/endpointgroups.html"
    [[ -f "$f" ]] || { warn "endpointgroups.html not found"; return; }
    if grep -q 'LOCAL_API_PATCH:outbound_prefix_rules_ui' "$f"; then
        log "endpointgroups.html: outbound_prefix UI already patched"
        return
    fi
    backup_file "$f"
    log "endpointgroups.html: injecting outbound_prefix UI"
    python3 - "$f" <<'PYEOF'
import sys, re

p = sys.argv[1]
src = open(p).read()
orig = src

def table_block(suffix):
    return (
        '          {# LOCAL_API_PATCH:outbound_prefix_rules_ui — Outbound Prefix Manipulation (' + suffix + ') #}\n'
        '          <div class="form-group">\n'
        '            <label style="font-weight:normal">\n'
        '              Outbound Prefix Manipulation\n'
        '              <small class="text-muted">\n'
        '                Per dialed-prefix strip + prepend on the way out\n'
        '                (1–8 digit prefix; longest match wins)\n'
        '              </small>\n'
        '            </label>\n'
        '            <table id="outbound_prefix_rules_' + suffix + '" class="outbound_prefix_rules table table-condensed" style="margin-bottom: 6px;">\n'
        '              <thead>\n'
        '                <tr>\n'
        '                  <th style="width: 30%">Prefix</th>\n'
        '                  <th style="width: 18%">Strip</th>\n'
        '                  <th style="width: 38%">Prepend</th>\n'
        '                  <th style="width: 14%"></th>\n'
        '                </tr>\n'
        '              </thead>\n'
        '              <tbody></tbody>\n'
        '            </table>\n'
        '            <button type="button" class="btn btn-default btn-xs outbound_prefix_add_row" data-target="#outbound_prefix_rules_' + suffix + '">\n'
        '              <span class="glyphicon glyphicon-plus"></span> Add rule\n'
        '            </button>\n'
        '          </div>\n'
    )

def insert_after_prefix_acl(src, allowed_prefix_id, ui_block):
    """Insert outbound block right after the </div> that closes the
    'Allowed Destination Prefixes' form-group with the given textarea id."""
    pat = re.compile(
        r'(<textarea id="' + re.escape(allowed_prefix_id) + r'"[^>]*></textarea>\s*\n\s*</div>\n)',
        re.MULTILINE,
    )
    m = pat.search(src)
    if m is None:
        sys.stderr.write("endpointgroups.html: allowed_prefixes anchor #%s not found\n" % allowed_prefix_id)
        sys.exit(2)
    return src[:m.end(1)] + ui_block + src[m.end(1):]

src = insert_after_prefix_acl(src, 'allowed_prefixes_edit', table_block('edit'))
src = insert_after_prefix_acl(src, 'allowed_prefixes_add',  table_block('add'))

# JS block — append at end (right before the existing closing </script>?
# the file ends with `})();\n</script>\n\n{% endblock %}\n` for the prefix_acl_ui IIFE)
js_block = '\n/* LOCAL_API_PATCH:outbound_prefix_rules_ui */\n(function() {\n  if (typeof $ === "undefined") return;\n  if (window.__localApiOutboundPrefixWired) return;\n  window.__localApiOutboundPrefixWired = true;\n\n  function localApiBase() {\n    if (typeof API_BASE_URL !== "string") return null;\n    return API_BASE_URL.replace(/\\/api\\/v1\\/?$/, "/api/local/v1/");\n  }\n\n  function htmlEscape(s) {\n    return String(s == null ? "" : s)\n      .replace(/&/g, "&amp;").replace(/</g, "&lt;")\n      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");\n  }\n\n  function rowHTML(rule) {\n    var p  = htmlEscape(rule && rule.prefix     != null ? rule.prefix     : "");\n    var s  = htmlEscape(rule && rule.strip      != null ? rule.strip      : 0);\n    var pp = htmlEscape(rule && rule.pri_prefix != null ? rule.pri_prefix : "");\n    return ""\n      + "<tr>"\n      +   "<td><input class=\\"form-control input-sm op_prefix\\" type=\\"text\\" maxlength=\\"8\\" value=\\"" + p + "\\" placeholder=\\"6661\\"></td>"\n      +   "<td><input class=\\"form-control input-sm op_strip\\"  type=\\"number\\" min=\\"0\\" max=\\"8\\" value=\\"" + s + "\\"></td>"\n      +   "<td><input class=\\"form-control input-sm op_pre\\"    type=\\"text\\" maxlength=\\"32\\" value=\\"" + pp + "\\" placeholder=\\"+51\\"></td>"\n      +   "<td><button type=\\"button\\" class=\\"btn btn-danger btn-xs op_remove_row\\"><span class=\\"glyphicon glyphicon-trash\\"></span></button></td>"\n      + "</tr>";\n  }\n\n  function renderRulesInto($table, rules) {\n    var $tb = $table.find("tbody");\n    $tb.empty();\n    (rules || []).forEach(function(r) { $tb.append(rowHTML(r)); });\n  }\n\n  function readRulesFrom($table) {\n    var rules = [];\n    $table.find("tbody tr").each(function() {\n      var $r = $(this);\n      var prefix = ($r.find(".op_prefix").val() || "").trim();\n      if (!prefix) return;\n      var strip  = parseInt($r.find(".op_strip").val(), 10) || 0;\n      var pre    = ($r.find(".op_pre").val() || "").trim();\n      rules.push({ prefix: prefix, strip: strip, pri_prefix: pre });\n    });\n    return rules;\n  }\n\n  function validateRules(rules) {\n    var seen = {};\n    for (var i = 0; i < rules.length; i++) {\n      var r = rules[i];\n      if (!/^\\d{1,8}$/.test(r.prefix)) {\n        return "Invalid prefix \\u0027" + r.prefix + "\\u0027: must be 1\\u20138 digits";\n      }\n      if (!Number.isInteger(r.strip) || r.strip < 0 || r.strip > 8) {\n        return "Invalid strip for prefix " + r.prefix + ": must be 0..8";\n      }\n      if (r.pri_prefix && !/^[\\w+#*\\-]{0,32}$/.test(r.pri_prefix)) {\n        return "Invalid prepend \\u0027" + r.pri_prefix + "\\u0027 for prefix " + r.prefix;\n      }\n      if (seen[r.prefix]) { return "Duplicate prefix: " + r.prefix; }\n      seen[r.prefix] = true;\n    }\n    return null;\n  }\n\n  function loadRulesFor(gwgroupid, $table) {\n    var base = localApiBase();\n    if (!base || !gwgroupid) return;\n    $.ajax({\n      type: "GET",\n      url: base + "endpointgroups/" + gwgroupid + "/outbound-prefix-rules",\n      dataType: "json",\n      success: function(resp) {\n        var rules = (resp && resp.data && resp.data[0] && resp.data[0].rules) || [];\n        renderRulesInto($table, rules);\n      },\n      error: function(xhr) {\n        if (window.console) console.warn("outbound-prefix-rules load failed", xhr.status);\n        renderRulesInto($table, []);\n      }\n    });\n  }\n\n  function saveRulesFor(gwgroupid, rules, cb) {\n    var base = localApiBase();\n    if (!base || !gwgroupid) { if (cb) cb(); return; }\n    $.ajax({\n      type: "PUT",\n      url: base + "endpointgroups/" + gwgroupid + "/outbound-prefix-rules",\n      dataType: "json",\n      contentType: "application/json; charset=utf-8",\n      data: JSON.stringify({ rules: rules }),\n      success: function() { if (cb) cb(); },\n      error: function(xhr) {\n        if (window.console) console.error("outbound-prefix-rules save failed", xhr.status, xhr.responseText);\n        if (cb) cb();\n      }\n    });\n  }\n\n  $(document).on("click", ".outbound_prefix_add_row", function() {\n    var sel = $(this).data("target");\n    var $table = $(sel);\n    if (!$table.length) return;\n    $table.find("tbody").append(rowHTML({prefix: "", strip: 0, pri_prefix: ""}));\n  });\n\n  $(document).on("click", ".op_remove_row", function() {\n    $(this).closest("tr").remove();\n  });\n\n  $(document).on("show.bs.modal", "#edit", function() {\n    var $modal = $(this);\n    setTimeout(function() {\n      var id = $modal.find(".gwgroupid").val();\n      var $table = $modal.find("#outbound_prefix_rules_edit");\n      renderRulesInto($table, []);\n      loadRulesFor(id, $table);\n    }, 50);\n  });\n\n  $(document).on("hidden.bs.modal", "#add", function() {\n    renderRulesInto($(this).find("#outbound_prefix_rules_add"), []);\n  });\n\n  $(document).ajaxSuccess(function(event, xhr, opts) {\n    if (!opts || !opts.url) return;\n    var m = opts.url.match(/\\/api\\/v1\\/endpointgroups(?:\\/(\\d+))?(?:\\?|$)/);\n    if (!m) return;\n    var method = (opts.type || "GET").toUpperCase();\n    if (method !== "POST" && method !== "PUT") return;\n\n    var gwgroupid = m[1];\n    var $table;\n    if (method === "POST") {\n      try {\n        var resp = (typeof xhr.responseJSON !== "undefined") ? xhr.responseJSON : JSON.parse(xhr.responseText || "{}");\n        gwgroupid = (resp && resp.data && resp.data[0] && resp.data[0].gwgroupid) || null;\n      } catch(e) { gwgroupid = null; }\n      $table = $("#outbound_prefix_rules_add");\n    } else {\n      $table = $("#outbound_prefix_rules_edit");\n    }\n    if (!gwgroupid || !$table.length) return;\n\n    var rules = readRulesFrom($table);\n    var err = validateRules(rules);\n    if (err) { alert("Outbound Prefix Manipulation: " + err); return; }\n    saveRulesFor(gwgroupid, rules, function() {\n      if (typeof reloadKamRequired === "function") reloadKamRequired(true);\n    });\n  });\n})();\n'

# Append before {% endblock %} that follows the prefix_acl_ui IIFE
endblock = re.compile(r'(</script>\n\n\{% endblock %\}\n?)$')
m = endblock.search(src)
if m is None:
    # fallback: append before the last endblock
    endblock = re.compile(r'(\{% endblock %\}\n?)$')
    m = endblock.search(src)
    if m is None:
        sys.stderr.write("endpointgroups.html: closing endblock not found\n")
        sys.exit(2)
    src = src[:m.start(1)] + '<script>\n' + js_block + '\n</script>\n\n' + src[m.start(1):]
else:
    # Insert JS inside the existing trailing <script> block (between previous IIFE and </script>)
    # Find the last </script> before the final {% endblock %}.
    last_script_close = src.rfind('</script>\n\n{% endblock %}')
    if last_script_close == -1:
        sys.stderr.write("endpointgroups.html: trailing </script> anchor not found\n")
        sys.exit(2)
    src = src[:last_script_close] + js_block + src[last_script_close:]

open(p, 'w').write(src)
PYEOF
    grep -q 'LOCAL_API_PATCH:outbound_prefix_rules_ui' "$f" \
        || die "endpointgroups.html: outbound_prefix UI patch failed verification"
}

patch_endpointgroups_outbound_prefix_ui

# ============================================================================
# 8c. Fix rtpengine kernel-forwarding: dst_media_tp instead of src_media_tp.
#
#  In dSIPRouter's kamailio.cfg the route[RTPENGINEOFFER] / route[RTPENGINEANSWER]
#  blocks build the rtpengine reflags by concatenating the SDP transport. They
#  use $dlg_var(src_media_tp), but earlier in SET_DST_MEDIA the cfg only sets
#  $var(src_media_tp) (function-scoped) via sdp_transport(), which writes a
#  numeric transport code — not the "RTP/AVP" string. The numeric value (often
#  "0") leaks into the rtpengine flag string, rtpengine logs:
#       "Unknown flag encountered: '0'"
#  …and kernel-forwarding never engages (Targets stays 0 in /proc/rtpengine/).
#
#  $dlg_var(dst_media_tp) holds the correct string ("RTP/AVP" etc.) — for an
#  SBC use-case offer/answer transport are the same, so swapping is safe.
#
#  Marker: # LOCAL_API_PATCH:rtpengine_kernel_fix
# ============================================================================
patch_kamailio_cfg_rtpe_kernel_file() {
    local f="$1"
    [[ -f "$f" ]] || { warn "kamailio cfg not found: $f"; return; }
    if grep -q 'LOCAL_API_PATCH:rtpengine_kernel_fix' "$f"; then
        log "kamailio.cfg: rtpengine kernel-fix already patched ($f)"
        return
    fi
    backup_file "$f"
    log "kamailio.cfg: patching rtpengine kernel-fix into $f"
    python3 - "$f" <<'PYEOF'
import sys, re

p = sys.argv[1]
src = open(p).read()
orig = src

# Replace dlg_var(src_media_tp) with dlg_var(dst_media_tp) ONLY in the
# RHS of `+` concatenations that build the rtpengine reflags string.
# The single assignment line `$dlg_var(src_media_tp) = $var(src_media_tp);`
# in SET_DST_MEDIA is preserved — other code may rely on that variable.
new_src = re.sub(
    r'(\+\s*)\$dlg_var\(src_media_tp\)',
    r'\1$dlg_var(dst_media_tp)',
    src,
)
if new_src == src:
    sys.stderr.write("kamailio.cfg: no '+ $dlg_var(src_media_tp)' concatenations found; cfg may have changed upstream\n")
    sys.exit(2)

# Add a marker block at the top of the cfg so subsequent runs detect this fix
marker = (
    '# LOCAL_API_PATCH:rtpengine_kernel_fix — replaced "+ $dlg_var(src_media_tp)"\n'
    '#   with "+ $dlg_var(dst_media_tp)" in route[RTPENGINEOFFER] / route[RTPENGINEANSWER]\n'
    '#   so the rtpengine reflags string contains the correct transport ("RTP/AVP")\n'
    '#   instead of the numeric code from sdp_transport(). Required for kernel-fwd\n'
    '#   to engage (xt_RTPENGINE Targets > 0).\n'
)
if 'LOCAL_API_PATCH:rtpengine_kernel_fix' not in new_src:
    new_src = marker + new_src

open(p, 'w').write(new_src)
PYEOF
    grep -q 'LOCAL_API_PATCH:rtpengine_kernel_fix' "$f" \
        || die "kamailio.cfg: rtpengine kernel-fix patch failed verification ($f)"
}

patch_kamailio_cfg_rtpe_kernel() {
    patch_kamailio_cfg_rtpe_kernel_file "$SRC_DIR/kamailio/configs/kamailio.cfg"
    patch_kamailio_cfg_rtpe_kernel_file "/etc/dsiprouter/kamailio/kamailio.cfg"
}

patch_kamailio_cfg_rtpe_kernel

# ----------------------------------------------------------------------------
# 9. Mirror to runtime gui dir (the path dsiprouter.service actually loads)
# ----------------------------------------------------------------------------
mirror_runtime() {
    if [[ ! -d "$RUN_DIR" ]]; then
        log "runtime $RUN_DIR not present — skipping mirror"
        return
    fi
    log "mirroring patched files → $RUN_DIR"
    # -D creates parent dirs as needed (some installs only ship settings.py here)
    install -D -m 0644 "$SRC_DIR/gui/modules/local_api/__init__.py" "$RUN_DIR/modules/local_api/__init__.py"
    install -D -m 0644 "$SRC_DIR/gui/modules/local_api/routes.py"   "$RUN_DIR/modules/local_api/routes.py"
    install -D -m 0644 "$SRC_DIR/gui/dsiprouter.py"                 "$RUN_DIR/dsiprouter.py"
    # Templates: Flask resolves them relative to the app dir (/opt/dsiprouter/gui/templates),
    # so mirroring under $RUN_DIR is just a safety net for non-standard installs.
    install -D -m 0644 "$SRC_DIR/gui/templates/endpointgroups.html"  "$RUN_DIR/templates/endpointgroups.html"
    install -D -m 0644 "$SRC_DIR/gui/templates/fullwidth_layout.html" "$RUN_DIR/templates/fullwidth_layout.html"
    # Drop stale bytecode so the new routes load cleanly
    find "$RUN_DIR" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
}

mirror_runtime

# ----------------------------------------------------------------------------
# 10. Restart
# ----------------------------------------------------------------------------
if [[ "${NO_RESTART:-0}" = "1" ]]; then
    log "DONE — NO_RESTART=1 set, not restarting dsiprouter"
    log "         restart manually:  systemctl restart dsiprouter"
    exit 0
fi

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files dsiprouter.service >/dev/null 2>&1; then
    log "restarting dsiprouter.service"
    systemctl restart dsiprouter || warn "dsiprouter restart failed — check 'journalctl -u dsiprouter -n 100'"
else
    log "systemctl/dsiprouter.service not available — skipping restart"
fi

log "DONE — backups in $BACKUP_DIR"
