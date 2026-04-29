import sys

if sys.path[0] != '/etc/dsiprouter/gui':
    sys.path.insert(0, '/etc/dsiprouter/gui')

from flask import Blueprint, jsonify, request
from sqlalchemy import func
from database import (
    startSession,
    DummySession,
    CallerIdMaskGroups,
    CallerIdMasks,
    CallerIdMaskAssignments,
)
from shared import debugEndpoint, getRequestData, StatusCodes
from modules.api.api_functions import api_security, showApiError, createApiResponse
from modules.api.calleridmasks.functions import (
    MAX_NUMBERS_PER_GROUP,
    parseNumberList,
    reloadCallerIdMaskHtables,
    reindexGroupNumbers,
    serializeAssignment,
    serializeGroup,
    getGroupCounts,
    validatePrefix,
)
import settings

calleridmasks = Blueprint('calleridmasks', '__name__')

# Reload arguments — split so a numbers-only mutation doesn't pay the
# cost of reloading the assignments table and vice versa.
_RELOAD_NUMBERS = ('caller_id_masks',)
_RELOAD_ASSIGNMENTS = ('caller_id_assignments',)
_RELOAD_BOTH = ('caller_id_masks', 'caller_id_assignments')


# ---------------------------------------------------------------------------
# Mask groups
# ---------------------------------------------------------------------------

@calleridmasks.route('/api/v1/calleridmasks/groups', methods=['GET'])
@api_security
def listMaskGroups():
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        db = startSession()

        groups = db.query(CallerIdMaskGroups).order_by(CallerIdMaskGroups.id.asc()).all()
        counts = getGroupCounts(db, [g.id for g in groups])
        data = [serializeGroup(g, counts.get(g.id, 0)) for g in groups]
        return createApiResponse(msg='Mask groups found', data=data)
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


@calleridmasks.route('/api/v1/calleridmasks/groups', methods=['POST'])
@api_security
def createMaskGroup():
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        data = getRequestData() or {}
        name = (data.get('name') or '').strip()
        if not name:
            raise ValueError('name is required')
        description = (data.get('description') or '').strip()

        db = startSession()
        existing = db.query(CallerIdMaskGroups).filter(CallerIdMaskGroups.name == name).first()
        if existing is not None:
            raise ValueError(f'mask group named {name!r} already exists')

        group = CallerIdMaskGroups(name=name, description=description)
        db.add(group)
        db.commit()

        return createApiResponse(
            msg='Mask group created',
            data=[serializeGroup(group, 0)],
            status_code=StatusCodes.HTTP_CREATED,
        )
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


@calleridmasks.route('/api/v1/calleridmasks/groups/<int:gid>', methods=['GET'])
@api_security
def getMaskGroup(gid):
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        db = startSession()
        group = db.query(CallerIdMaskGroups).filter(CallerIdMaskGroups.id == gid).first()
        if group is None:
            return showApiError(KeyError(f'mask group {gid} not found'))
        count = db.query(func.count(CallerIdMasks.id)).filter(
            CallerIdMasks.mask_group_id == gid
        ).scalar() or 0
        return createApiResponse(msg='Mask group found', data=[serializeGroup(group, count)])
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


@calleridmasks.route('/api/v1/calleridmasks/groups/<int:gid>', methods=['PATCH', 'PUT'])
@api_security
def updateMaskGroup(gid):
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        data = getRequestData() or {}
        db = startSession()
        group = db.query(CallerIdMaskGroups).filter(CallerIdMaskGroups.id == gid).first()
        if group is None:
            return showApiError(KeyError(f'mask group {gid} not found'))

        if 'name' in data:
            new_name = (data['name'] or '').strip()
            if not new_name:
                raise ValueError('name cannot be empty')
            if new_name != group.name:
                clash = db.query(CallerIdMaskGroups).filter(
                    CallerIdMaskGroups.name == new_name,
                    CallerIdMaskGroups.id != gid,
                ).first()
                if clash is not None:
                    raise ValueError(f'mask group named {new_name!r} already exists')
                group.name = new_name
        if 'description' in data:
            group.description = (data['description'] or '').strip()

        db.commit()
        return createApiResponse(msg='Mask group updated', data=[serializeGroup(group)])
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


@calleridmasks.route('/api/v1/calleridmasks/groups/<int:gid>', methods=['DELETE'])
@api_security
def deleteMaskGroup(gid):
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        db = startSession()
        group = db.query(CallerIdMaskGroups).filter(CallerIdMaskGroups.id == gid).first()
        if group is None:
            return showApiError(KeyError(f'mask group {gid} not found'))

        # ON DELETE CASCADE on the FKs takes care of numbers and
        # assignments rows; we still reload both htables since both views
        # change when a group goes away.
        db.delete(group)
        db.commit()

        try:
            reloadCallerIdMaskHtables(_RELOAD_BOTH)
        except Exception as reload_ex:
            return createApiResponse(
                msg=f'Mask group deleted but htable reload failed: {reload_ex}',
                kamreload=True,
            )

        return createApiResponse(msg='Mask group deleted')
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Numbers in a mask group
# ---------------------------------------------------------------------------

@calleridmasks.route('/api/v1/calleridmasks/groups/<int:gid>/numbers', methods=['GET'])
@api_security
def listMaskNumbers(gid):
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        # Pagination — required because a single group can hold up to 20k
        # numbers and the GUI must not load them all in one shot.
        try:
            page = max(int(request.args.get('page', '1')), 1)
            per_page = min(max(int(request.args.get('per_page', '100')), 1), 1000)
        except (TypeError, ValueError):
            raise ValueError('invalid pagination parameters')
        search = (request.args.get('q') or '').strip()

        db = startSession()
        if db.query(CallerIdMaskGroups).filter(CallerIdMaskGroups.id == gid).first() is None:
            return showApiError(KeyError(f'mask group {gid} not found'))

        q = db.query(CallerIdMasks).filter(CallerIdMasks.mask_group_id == gid)
        if search:
            q = q.filter(CallerIdMasks.number.like(f'%{search}%'))
        total = q.count()
        rows = q.order_by(CallerIdMasks.idx.asc()).offset((page - 1) * per_page).limit(per_page).all()

        # createApiResponse silently drops **kwargs (the shared helper
        # only serializes its fixed fields), so for the paginated list
        # we go around it and assemble the JSON ourselves to surface
        # page/per_page/total to the client.
        return jsonify({
            'error': '',
            'msg': 'Numbers found',
            'data': [{
                'id': r.id,
                'mask_group_id': r.mask_group_id,
                'number': r.number,
                'idx': r.idx,
            } for r in rows],
            'page': page,
            'per_page': per_page,
            'total': total,
        }), StatusCodes.HTTP_OK
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


@calleridmasks.route('/api/v1/calleridmasks/groups/<int:gid>/numbers/bulk', methods=['POST'])
@api_security
def bulkAddMaskNumbers(gid):
    """
    Add many numbers in one shot. Accepts either:

    * JSON: ``{"numbers": ["+15551234567", ...], "mode": "append"|"replace"}``
    * Form/multipart: ``numbers`` field (newline / comma / semicolon
      separated) plus optional ``mode``.

    ``mode=replace`` wipes the group's existing numbers first; the
    default ``append`` adds while skipping duplicates already in the DB.
    """
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        data = getRequestData() or {}
        raw = data.get('numbers')
        # multipart form lists arrive as ['value'] from getRequestData
        if isinstance(raw, list) and len(raw) == 1 and isinstance(raw[0], str) and ('\n' in raw[0] or ',' in raw[0] or ';' in raw[0]):
            raw = raw[0]
        if raw is None:
            raise ValueError('numbers field is required')
        mode = (data.get('mode') or 'append')
        if isinstance(mode, list):
            mode = mode[0] if mode else 'append'
        if mode not in ('append', 'replace'):
            raise ValueError('mode must be "append" or "replace"')

        numbers, invalid_lines = parseNumberList(raw)
        if not numbers:
            raise ValueError('no valid numbers provided')

        db = startSession()
        group = db.query(CallerIdMaskGroups).filter(CallerIdMaskGroups.id == gid).first()
        if group is None:
            return showApiError(KeyError(f'mask group {gid} not found'))

        if mode == 'replace':
            db.query(CallerIdMasks).filter(CallerIdMasks.mask_group_id == gid).delete(synchronize_session=False)
            db.flush()
            existing_numbers = set()
            existing_count = 0
            next_idx = 0
        else:
            existing_rows = db.query(CallerIdMasks.number).filter(
                CallerIdMasks.mask_group_id == gid
            ).all()
            existing_numbers = {r[0] for r in existing_rows}
            existing_count = len(existing_numbers)
            next_idx = db.query(func.coalesce(func.max(CallerIdMasks.idx), -1)).filter(
                CallerIdMasks.mask_group_id == gid
            ).scalar()
            next_idx = (next_idx if next_idx is not None else -1) + 1

        # Filter out duplicates of what's already stored. We do not error
        # on duplicates — that would force the UI to clean a 20k paste by
        # hand — we just report how many landed.
        to_insert = [n for n in numbers if n not in existing_numbers]

        if existing_count + len(to_insert) > MAX_NUMBERS_PER_GROUP:
            raise ValueError(
                f'group would exceed maximum of {MAX_NUMBERS_PER_GROUP} numbers '
                f'(currently {existing_count}, attempting to add {len(to_insert)})'
            )

        rows = []
        for offset, n in enumerate(to_insert):
            rows.append({
                'mask_group_id': gid,
                'number': n,
                'idx': next_idx + offset,
            })
        if rows:
            db.bulk_insert_mappings(CallerIdMasks, rows)
        db.commit()

        try:
            reloadCallerIdMaskHtables(_RELOAD_NUMBERS)
        except Exception as reload_ex:
            return createApiResponse(
                msg=f'{len(rows)} numbers added but htable reload failed: {reload_ex}',
                kamreload=True,
                data=[{'added': len(rows), 'skipped': len(numbers) - len(rows)}],
            )

        return createApiResponse(
            msg='Numbers added',
            data=[{
                'added': len(rows),
                # Two distinct skip categories: "invalid" lines that
                # didn't parse as a number, and "duplicate" entries
                # already in the group (or repeated within the paste).
                'skipped_invalid': invalid_lines,
                'skipped_duplicate': len(numbers) - len(rows),
                'total_in_group': existing_count + len(rows),
            }],
        )
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


@calleridmasks.route('/api/v1/calleridmasks/groups/<int:gid>/numbers/<int:nid>', methods=['DELETE'])
@api_security
def deleteMaskNumber(gid, nid):
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        db = startSession()
        row = db.query(CallerIdMasks).filter(
            CallerIdMasks.id == nid, CallerIdMasks.mask_group_id == gid
        ).first()
        if row is None:
            return showApiError(KeyError(f'number {nid} not found in group {gid}'))
        db.delete(row)
        db.flush()
        # Re-pack idx so the htable lookup keys stay 0..N-1 contiguous.
        reindexGroupNumbers(db, gid)
        db.commit()

        try:
            reloadCallerIdMaskHtables(_RELOAD_NUMBERS)
        except Exception as reload_ex:
            return createApiResponse(
                msg=f'Number deleted but htable reload failed: {reload_ex}',
                kamreload=True,
            )
        return createApiResponse(msg='Number deleted')
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


@calleridmasks.route('/api/v1/calleridmasks/groups/<int:gid>/numbers/clear', methods=['POST', 'DELETE'])
@api_security
def clearMaskNumbers(gid):
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        db = startSession()
        if db.query(CallerIdMaskGroups).filter(CallerIdMaskGroups.id == gid).first() is None:
            return showApiError(KeyError(f'mask group {gid} not found'))
        deleted = db.query(CallerIdMasks).filter(
            CallerIdMasks.mask_group_id == gid
        ).delete(synchronize_session=False)
        db.commit()

        try:
            reloadCallerIdMaskHtables(_RELOAD_NUMBERS)
        except Exception as reload_ex:
            return createApiResponse(
                msg=f'{deleted} numbers cleared but htable reload failed: {reload_ex}',
                kamreload=True,
                data=[{'deleted': deleted}],
            )
        return createApiResponse(msg='Numbers cleared', data=[{'deleted': deleted}])
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Assignments (binding mask groups to scopes)
# ---------------------------------------------------------------------------

@calleridmasks.route('/api/v1/calleridmasks/assignments', methods=['GET'])
@api_security
def listAssignments():
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        db = startSession()
        q = db.query(CallerIdMaskAssignments)
        gwgroupid = request.args.get('gwgroupid')
        gwid = request.args.get('gwid')
        if gwgroupid is not None:
            q = q.filter(CallerIdMaskAssignments.gwgroupid == int(gwgroupid))
        if gwid is not None:
            q = q.filter(CallerIdMaskAssignments.gwid == int(gwid))
        rows = q.order_by(CallerIdMaskAssignments.id.asc()).all()
        return createApiResponse(msg='Assignments found', data=[serializeAssignment(a) for a in rows])
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


@calleridmasks.route('/api/v1/calleridmasks/assignments', methods=['POST'])
@api_security
def createAssignment():
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        data = getRequestData() or {}
        atype = (data.get('assignment_type') or '').strip()
        mask_group_id = data.get('mask_group_id')
        gwgroupid = data.get('gwgroupid')
        gwid = data.get('gwid')
        prefix = data.get('prefix')
        enabled = 1 if data.get('enabled', True) else 0

        if mask_group_id in (None, ''):
            raise ValueError('mask_group_id is required')
        try:
            mask_group_id = int(mask_group_id)
        except (TypeError, ValueError):
            raise ValueError('mask_group_id must be an integer')

        # Validate per scope. Each level uses a different subset of the
        # columns; the partial unique index in the DB enforces no
        # duplicates within a single (type, gwgroupid, gwid, prefix) tuple.
        if atype == CallerIdMaskAssignments.TYPE_ENDPOINTGROUP:
            if not gwgroupid:
                raise ValueError('gwgroupid is required for endpointgroup-level assignment')
            gwgroupid = int(gwgroupid)
            gwid = None
            prefix = None
        elif atype == CallerIdMaskAssignments.TYPE_ENDPOINT:
            if not gwid:
                raise ValueError('gwid is required for endpoint-level assignment')
            gwid = int(gwid)
            gwgroupid = int(gwgroupid) if gwgroupid else None
            prefix = None
        elif atype == CallerIdMaskAssignments.TYPE_PREFIX:
            if not gwid:
                raise ValueError('gwid is required for prefix-level assignment')
            if not prefix:
                raise ValueError('prefix is required for prefix-level assignment')
            gwid = int(gwid)
            gwgroupid = int(gwgroupid) if gwgroupid else None
            prefix = validatePrefix(prefix)
        else:
            raise ValueError(
                f'assignment_type must be one of '
                f'{CallerIdMaskAssignments.TYPE_ENDPOINTGROUP!r}, '
                f'{CallerIdMaskAssignments.TYPE_ENDPOINT!r}, '
                f'{CallerIdMaskAssignments.TYPE_PREFIX!r}'
            )

        db = startSession()
        if db.query(CallerIdMaskGroups).filter(CallerIdMaskGroups.id == mask_group_id).first() is None:
            raise ValueError(f'mask group {mask_group_id} does not exist')

        # Pre-empt the unique-key violation with a friendlier error.
        clash = db.query(CallerIdMaskAssignments).filter(
            CallerIdMaskAssignments.assignment_type == atype,
            CallerIdMaskAssignments.gwgroupid.is_(None) if gwgroupid is None else CallerIdMaskAssignments.gwgroupid == gwgroupid,
            CallerIdMaskAssignments.gwid.is_(None) if gwid is None else CallerIdMaskAssignments.gwid == gwid,
            CallerIdMaskAssignments.prefix.is_(None) if prefix is None else CallerIdMaskAssignments.prefix == prefix,
        ).first()
        if clash is not None:
            raise ValueError(f'an assignment already exists for this scope (id={clash.id})')

        a = CallerIdMaskAssignments(
            mask_group_id=mask_group_id,
            assignment_type=atype,
            gwgroupid=gwgroupid,
            gwid=gwid,
            prefix=prefix,
            enabled=enabled,
        )
        db.add(a)
        db.commit()

        try:
            reloadCallerIdMaskHtables(_RELOAD_ASSIGNMENTS)
        except Exception as reload_ex:
            return createApiResponse(
                msg=f'Assignment created but htable reload failed: {reload_ex}',
                kamreload=True,
                data=[serializeAssignment(a)],
                status_code=StatusCodes.HTTP_CREATED,
            )

        return createApiResponse(
            msg='Assignment created',
            data=[serializeAssignment(a)],
            status_code=StatusCodes.HTTP_CREATED,
        )
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


@calleridmasks.route('/api/v1/calleridmasks/assignments/<int:aid>', methods=['PATCH', 'PUT'])
@api_security
def updateAssignment(aid):
    """
    Limited update: only ``enabled`` and ``mask_group_id`` are mutable.
    Changing the scope (type/gwgroupid/gwid/prefix) means deleting and
    recreating to keep the unique index honest.
    """
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        data = getRequestData() or {}
        db = startSession()
        a = db.query(CallerIdMaskAssignments).filter(CallerIdMaskAssignments.id == aid).first()
        if a is None:
            return showApiError(KeyError(f'assignment {aid} not found'))

        if 'mask_group_id' in data:
            mgid = int(data['mask_group_id'])
            if db.query(CallerIdMaskGroups).filter(CallerIdMaskGroups.id == mgid).first() is None:
                raise ValueError(f'mask group {mgid} does not exist')
            a.mask_group_id = mgid
        if 'enabled' in data:
            a.enabled = 1 if data['enabled'] else 0

        db.commit()

        try:
            reloadCallerIdMaskHtables(_RELOAD_ASSIGNMENTS)
        except Exception as reload_ex:
            return createApiResponse(
                msg=f'Assignment updated but htable reload failed: {reload_ex}',
                kamreload=True,
                data=[serializeAssignment(a)],
            )
        return createApiResponse(msg='Assignment updated', data=[serializeAssignment(a)])
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()


@calleridmasks.route('/api/v1/calleridmasks/assignments/<int:aid>', methods=['DELETE'])
@api_security
def deleteAssignment(aid):
    db = DummySession()
    try:
        if settings.DEBUG:
            debugEndpoint()
        db = startSession()
        a = db.query(CallerIdMaskAssignments).filter(CallerIdMaskAssignments.id == aid).first()
        if a is None:
            return showApiError(KeyError(f'assignment {aid} not found'))
        db.delete(a)
        db.commit()

        try:
            reloadCallerIdMaskHtables(_RELOAD_ASSIGNMENTS)
        except Exception as reload_ex:
            return createApiResponse(
                msg=f'Assignment deleted but htable reload failed: {reload_ex}',
                kamreload=True,
            )
        return createApiResponse(msg='Assignment deleted')
    except Exception as ex:
        db.rollback()
        return showApiError(ex)
    finally:
        db.close()
