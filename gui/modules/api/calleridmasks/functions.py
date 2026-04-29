import sys

if sys.path[0] != '/etc/dsiprouter/gui':
    sys.path.insert(0, '/etc/dsiprouter/gui')

import re
from sqlalchemy import func, select
from database import (
    CallerIdMaskGroups,
    CallerIdMasks,
    CallerIdMaskAssignments,
)
from modules.api.kamailio.functions import sendJsonRpcCmd

# Hard limit of numbers per mask group. Enforced both on bulk ingest and
# on individual inserts. Matches the product requirement (up to 20k per
# customer); the htable size= modparam was chosen with this in mind.
MAX_NUMBERS_PER_GROUP = 20000

# Maximum prefix length used by the Kamailio CALLER_ID_MASK route when
# walking $rU from longest to shortest. Keep in sync with kamailio.cfg.
MAX_PREFIX_LEN = 8

# Loose validators. We accept E.164-ish numbers (digits, optional leading
# +, plus the SIP-allowed *, # for short codes) — same characters
# Kamailio's $fU happily holds. If you need stricter validation switch to
# phonenumbers.parse() here.
_NUMBER_RE = re.compile(r'^(?=.*[0-9])\+?[0-9*#]{1,32}$')
_PREFIX_RE = re.compile(r'^[0-9*#+]{1,32}$')


def reloadCallerIdMaskHtables(tables=('caller_id_masks', 'caller_id_assignments')):
    """
    Trigger a Kamailio htable.reload for the caller-id htables. Called
    after any mutation so changes go live without a full Kamailio reload.
    Failures here are surfaced to the caller — the GUI shows a banner
    asking the operator to reload manually if Kamailio is unreachable.
    """
    for tbl in tables:
        sendJsonRpcCmd('127.0.0.1', 'htable.reload', [tbl])


def reindexGroupNumbers(db, mask_group_id):
    """
    Reassign dense 0..N-1 ``idx`` values to all numbers in a group.
    Kamailio reads the htable as ``<gid>:<idx>`` and uses ``$RANDOM mod
    count`` to pick one, so the index space must be contiguous after any
    delete. Sorting by ``id`` keeps insertion order stable.
    """
    rows = db.query(CallerIdMasks).filter(
        CallerIdMasks.mask_group_id == mask_group_id
    ).order_by(CallerIdMasks.id.asc()).all()
    for new_idx, row in enumerate(rows):
        if row.idx != new_idx:
            row.idx = new_idx
    return len(rows)


def validateNumber(number):
    if not isinstance(number, str):
        raise ValueError(f'caller-id number must be a string, got {type(number).__name__}')
    n = number.strip()
    if not _NUMBER_RE.match(n):
        raise ValueError(f'invalid caller-id number: {number!r}')
    return n


def validatePrefix(prefix):
    if not isinstance(prefix, str):
        raise ValueError('prefix must be a string')
    p = prefix.strip()
    if not _PREFIX_RE.match(p):
        raise ValueError(f'invalid prefix: {prefix!r}')
    if len(p) > MAX_PREFIX_LEN:
        # The Kamailio route only walks up to MAX_PREFIX_LEN digits; longer
        # prefixes would silently never match, so reject them up front.
        raise ValueError(
            f'prefix too long ({len(p)} > {MAX_PREFIX_LEN}); '
            f'longer prefixes will not be matched by the Kamailio route'
        )
    return p


def parseNumberList(payload):
    """
    Accept the various shapes the bulk-import endpoint may receive:

    * JSON list of strings: ``["+15551234567", ...]``
    * Newline / comma / semicolon separated string (textarea or CSV paste)

    Returns ``(valid_unique, invalid_count)`` — invalid lines are skipped
    rather than raising, because a 20k paste with one stray line should
    not require the operator to clean it by hand. The route surfaces the
    skipped count back to the UI.
    """
    if isinstance(payload, list):
        raw = payload
    elif isinstance(payload, str):
        raw = re.split(r'[\s,;]+', payload)
    else:
        raise ValueError('numbers must be a list or a separated string')

    seen = set()
    out = []
    invalid = 0
    for item in raw:
        if item is None:
            continue
        s = str(item).strip()
        if s == '':
            continue
        if not _NUMBER_RE.match(s):
            invalid += 1
            continue
        if s in seen:
            continue
        seen.add(s)
        out.append(s)
    return out, invalid


def serializeGroup(group, count=None):
    return {
        'id': group.id,
        'name': group.name,
        'description': group.description or '',
        'count': count,
        'created_at': group.created_at.isoformat() if group.created_at else None,
    }


def serializeAssignment(a):
    return {
        'id': a.id,
        'mask_group_id': a.mask_group_id,
        'assignment_type': a.assignment_type,
        'gwgroupid': a.gwgroupid,
        'gwid': a.gwid,
        'prefix': a.prefix,
        'enabled': bool(a.enabled),
    }


def getGroupCounts(db, group_ids=None):
    """
    Return ``{group_id: count}`` for the requested groups (or all groups
    when ``group_ids`` is None). Done in a single GROUP BY query so the
    listing endpoint stays O(1) regardless of group count.
    """
    q = db.query(
        CallerIdMasks.mask_group_id,
        func.count(CallerIdMasks.id),
    ).group_by(CallerIdMasks.mask_group_id)
    if group_ids is not None:
        if not group_ids:
            return {}
        q = q.filter(CallerIdMasks.mask_group_id.in_(group_ids))
    return {gid: cnt for gid, cnt in q.all()}
