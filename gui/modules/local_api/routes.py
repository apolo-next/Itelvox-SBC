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

_OUTBOUND_PREFIX_RE  = re.compile(r'^\d{1,8}$')
_OUTBOUND_PREPEND_RE = re.compile(r'^[\w+#*\-]{0,32}$')


def _reload_outbound_prefix_htable():
    """Tell kamailio to reload just the outbound_prefix htable. ~ms cost."""
    sendJsonRpcCmd('127.0.0.1', 'htable.reload', ['outbound_prefix'])


def _validate_outbound_rule(rule):
    """Returns (cleaned_dict, error_str). One must be None."""
    if not isinstance(rule, dict):
        return None, "rule must be an object"
    prefix = str(rule.get('prefix', '')).strip()
    if not _OUTBOUND_PREFIX_RE.match(prefix):
        return None, "invalid prefix '{}': must match ^\\d{{1,8}}$".format(prefix)
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
