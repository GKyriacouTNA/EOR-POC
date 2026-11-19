import datetime
import json
import os
import re
import sys
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "vendor"))
import pg8000.native
from dateutil.relativedelta import relativedelta

ENTITY_FIELDS = {
    "department": ["department_code", "name"],
    "series": ["department_id", "series_code", "name"],
    "record": ["series_id", "record_reference"],
    "version": [
        "record_id",
        "version_code",
        "default_title_code",
        "default_description_code",
        "default_path_code",
    ],
    "version_title": [
        "version_id",
        "title_code",
        "title_text",
        "language_code",
        "variant_code",
    ],
    "version_description": [
        "version_id",
        "description_code",
        "description_text",
        "language_code",
        "variant_code",
    ],
    "version_path": ["version_id", "path_code", "path_value", "path_type"],
    "representation": ["version_id", "representation_code", "representation_type"],
    "file": ["representation_id", "consignment_id","file_name", "relative_path"],
    "consignment": [
        "consignment_reference",
        "received_at",
        "source_organisation",
        "notes",
    ],
    "sensitivity": [
        "version_id",
        "version_title_id",
        "version_description_id",
        "version_path_id",
        "sensitivity_type",
        "sensitivity_type_code",
        "sensitivity_status",
        "sensitivity_start",
        "sensitivity_period",
        "sensitivity_rule",
        "sensitivity_end",
        "investigation_date",
        "investigation_outcome",
        "schedule_reference",
        "archivist_note",
    ],
}
DURATION_RE = re.compile(
    r"^P(?=\d)(?:(?P<years>\d+)Y)?(?:(?P<months>\d+)M)?(?:(?P<weeks>\d+)W)?(?:(?P<days>\d+)D)?$"
)


def parse_date(value, field):
    if value is None:
        return None
    if isinstance(value, datetime.datetime):
        return value.date()
    if isinstance(value, datetime.date):
        return value
    try:
        return datetime.date.fromisoformat(str(value))
    except Exception:
        raise ValueError(f"invalid date for {field}")


def parse_iso_duration(period):
    m = DURATION_RE.match(str(period or ""))
    if not m:
        raise ValueError("invalid sensitivity_period")
    parts = {k: int(v) for k, v in m.groupdict().items() if v is not None}
    if not parts:
        raise ValueError("invalid sensitivity_period")
    return relativedelta(**parts)


def compute_sensitivity_end(start, period, rule):
    start = parse_date(start, "sensitivity_start")
    if start is None:
        raise ValueError("sensitivity_start required for automatic sensitivity_end")
    base = start + parse_iso_duration(period)
    if rule == "EXACT_PERIOD":
        return base
    if rule == "JAN_AFTER_PERIOD":
        if base.month == 1 and base.day == 1:
            return datetime.date(base.year + 1, 1, 1)
        return datetime.date(base.year + 1, 1, 1)
    raise ValueError("unsupported sensitivity_rule")


def resolve_sensitivity_end(e, old):
    changes = e.get("changes", {})
    rule = changes.get("sensitivity_rule", old[9] if old else None)
    if "sensitivity_end" in changes:
        if rule != "MANUAL":
            raise ValueError(
                "sensitivity_end may only be supplied when sensitivity_rule is MANUAL"
            )
        return parse_date(changes.get("sensitivity_end"), "sensitivity_end"), True
    if old and old[9] == "MANUAL" and rule == "MANUAL":
        return old[10], False
    if rule == "MANUAL":
        raise ValueError(
            "sensitivity_end must be explicitly provided when sensitivity_rule is MANUAL"
        )
    start = changes.get("sensitivity_start", old[7] if old else None)
    period = changes.get("sensitivity_period", old[8] if old else None)
    return compute_sensitivity_end(start, period, rule), False


def audit(c, e, entity, at):
    c.run(
        "INSERT INTO archive.metadata_change_event (metadata_change_event_id,source_event_id,entity_type,entity_id,entity_key,change_type,outcome,processing_status,changes,raw_change_payload,changed_at,processed_at,changed_by_id,changed_by_name,change_reason,source_system) VALUES (:id,:eid,:t,:entity,CAST(:key AS jsonb),:ct,:out,'processed',CAST(:ch AS jsonb),CAST(:raw AS jsonb),:at,clock_timestamp(),:by,:name,:why,:source)",
        id=str(uuid.uuid4()),
        eid=e["event_id"],
        t=e["entity_type"],
        entity=entity,
        key=json.dumps(e["entity_key"]),
        ct=e.get("change_type", "U"),
        out="inserted" if e.get("change_type") == "I" else "updated",
        ch=json.dumps(e.get("changes", {})),
        raw=json.dumps(e),
        at=at,
        by=e["changed_by"]["id"],
        name=e["changed_by"].get("name"),
        why=e["reason"],
        source=e["source"],
    )


def insert_entity(c, e, typ, eid, at, by, name, why):
    fields = ENTITY_FIELDS.get(typ)
    if not fields:
        raise ValueError("unsupported entity_type")
    i = e["entity_key"][typ + "_id"]
    ch = e.get("changes", {})
    row = [ch.get(f) for f in fields]
    if typ == "sensitivity":
        old = None
        end, _ = resolve_sensitivity_end(e, old)
        row[10] = end
    cols = [typ + "_id"] + fields + ["updated_at"]
    ph = [":" + c_ for c_ in cols]
    params = dict(zip(cols, [i] + row + [at]))
    c.run(
        f"INSERT INTO archive.{typ} ({','.join(cols)}) VALUES ({','.join(ph)})", **params
    )
    hcols = ["history_id", typ + "_id"] + fields + [
        "valid_from",
        "valid_to",
        "is_current",
        "changed_at",
        "changed_by_id",
        "changed_by_name",
        "change_reason",
        "source_event_id",
    ]
    hph = [":" + c_ for c_ in hcols]
    hparams = dict(
        zip(
            hcols,
            [str(uuid.uuid4()), i] + row + [at, None, True, at, by, name, why, eid],
        )
    )
    c.run(
        f"INSERT INTO history.{typ} ({','.join(hcols)}) VALUES ({','.join(hph)})",
        **hparams,
    )
    audit(c, e, i, at)
    c.run("COMMIT")
    result = {"outcome": "inserted", "entity_type": typ, "entity_id": i}
    print(json.dumps(result))
    return result


def apply_event(e):
    eid = str(uuid.UUID(e["event_id"]))
    typ = e["entity_type"]
    c = pg8000.native.Connection(
        host=os.environ["DB_HOST"],
        port=int(os.environ["DB_PORT"]),
        database=os.environ["DB_NAME"],
        user=os.environ["DB_USERNAME"],
        password=os.environ["DB_PASSWORD"],
    )
    try:
        c.run("BEGIN")
        if c.run(
            "SELECT 1 FROM archive.metadata_change_event WHERE source_event_id=:e",
            e=eid,
        ):
            c.run("COMMIT")
            return {"outcome": "duplicate"}
        # The database, not the caller, defines the effective change time. One
        # timestamp is reused for the current-row update, SCD history, and audit.
        at = c.run("SELECT clock_timestamp()")[0][0]
        by = e["changed_by"]["id"]
        name = e["changed_by"].get("name")
        why = e["reason"]
        if e.get("change_type") == "I":
            return insert_entity(c, e, typ, eid, at, by, name, why)

        if typ == "version":
            i = e["entity_key"]["version_id"]
            old = c.run(
                "SELECT record_id,version_code,default_title_code,default_description_code,default_path_code FROM archive.version WHERE version_id=:i FOR UPDATE",
                i=i,
            )[0]
            c.run(
                "UPDATE archive.version SET default_title_code=COALESCE(:t,default_title_code),default_description_code=COALESCE(:d,default_description_code),default_path_code=COALESCE(:p,default_path_code),updated_at=:at WHERE version_id=:i",
                t=e["changes"].get("default_title_code"),
                d=e["changes"].get("default_description_code"),
                p=e["changes"].get("default_path_code"),
                at=at,
                i=i,
            )
            c.run(
                "UPDATE history.version SET is_current=false,valid_to=:at WHERE version_id=:i AND is_current",
                at=at,
                i=i,
            )
            c.run(
                "INSERT INTO history.version VALUES (:row,:i,:r,:n,:t,:d,:p,:at,NULL,true,:at,:by,:name,:why,:e)",
                row=str(uuid.uuid4()),
                i=i,
                r=old[0],
                n=old[1],
                t=e["changes"].get("default_title_code", old[2]),
                d=e["changes"].get("default_description_code", old[3]),
                p=e["changes"].get("default_path_code", old[4]),
                at=at,
                by=by,
                name=name,
                why=why,
                e=eid,
            )
        elif typ == "version_title":
            i = e["entity_key"]["version_title_id"]
            old = c.run(
                "SELECT version_id,title_code,title_text,language_code,variant_code FROM archive.version_title WHERE version_title_id=:i FOR UPDATE",
                i=i,
            )[0]
            text = e["changes"].get("title_text", old[2])
            c.run(
                "UPDATE archive.version_title SET title_text=:x,updated_at=:at WHERE version_title_id=:i",
                x=text,
                at=at,
                i=i,
            )
            c.run(
                "UPDATE history.version_title SET is_current=false,valid_to=:at WHERE version_title_id=:i AND is_current",
                at=at,
                i=i,
            )
            c.run(
                "INSERT INTO history.version_title VALUES (:row,:i,:v,:code,:text,:lang,:variant,:at,NULL,true,:at,:by,:name,:why,:e)",
                row=str(uuid.uuid4()),
                i=i,
                v=old[0],
                code=old[1],
                text=text,
                lang=old[3],
                variant=old[4],
                at=at,
                by=by,
                name=name,
                why=why,
                e=eid,
            )
        elif typ == "sensitivity":
            i = e["entity_key"]["sensitivity_id"]
            old = c.run(
                "SELECT version_id,version_title_id,version_description_id,version_path_id,sensitivity_type,sensitivity_type_code,sensitivity_status,sensitivity_start,sensitivity_period,sensitivity_rule,sensitivity_end,investigation_date,investigation_outcome,schedule_reference,archivist_note FROM archive.sensitivity WHERE sensitivity_id=:i FOR UPDATE",
                i=i,
            )[0]
            changes = e.get("changes", {})
            end, _ = resolve_sensitivity_end(e, old)
            new = {
                "version_id": changes.get("version_id", old[0]),
                "version_title_id": changes.get("version_title_id", old[1]),
                "version_description_id": changes.get("version_description_id", old[2]),
                "version_path_id": changes.get("version_path_id", old[3]),
                "sensitivity_type": changes.get("sensitivity_type", old[4]),
                "sensitivity_type_code": changes.get("sensitivity_type_code", old[5]),
                "sensitivity_status": changes.get("sensitivity_status", old[6]),
                "sensitivity_start": parse_date(
                    changes.get("sensitivity_start", old[7]), "sensitivity_start"
                ),
                "sensitivity_period": changes.get("sensitivity_period", old[8]),
                "sensitivity_rule": changes.get("sensitivity_rule", old[9]),
                "sensitivity_end": end,
                "investigation_date": parse_date(
                    changes.get("investigation_date", old[11]), "investigation_date"
                ),
                "investigation_outcome": changes.get("investigation_outcome", old[12]),
                "schedule_reference": changes.get("schedule_reference", old[13]),
                "archivist_note": changes.get("archivist_note", old[14]),
            }
            c.run(
                "UPDATE archive.sensitivity SET version_id=:version_id,version_title_id=:version_title_id,version_description_id=:version_description_id,version_path_id=:version_path_id,sensitivity_type=:sensitivity_type,sensitivity_type_code=:sensitivity_type_code,sensitivity_status=:sensitivity_status,sensitivity_start=:sensitivity_start,sensitivity_period=:sensitivity_period,sensitivity_rule=:sensitivity_rule,sensitivity_end=:sensitivity_end,investigation_date=:investigation_date,investigation_outcome=:investigation_outcome,schedule_reference=:schedule_reference,archivist_note=:archivist_note,updated_at=:at WHERE sensitivity_id=:i",
                at=at,
                i=i,
                **new,
            )
            c.run(
                "UPDATE history.sensitivity SET is_current=false,valid_to=:at WHERE sensitivity_id=:i AND is_current",
                at=at,
                i=i,
            )
            c.run(
                "INSERT INTO history.sensitivity VALUES (:row,:i,:version_id,:version_title_id,:version_description_id,:version_path_id,:sensitivity_type,:sensitivity_type_code,:sensitivity_status,:sensitivity_start,:sensitivity_period,:sensitivity_rule,:sensitivity_end,:investigation_date,:investigation_outcome,:schedule_reference,:archivist_note,:at,NULL,true,:at,:by,:name,:why,:e)",
                row=str(uuid.uuid4()),
                i=i,
                at=at,
                by=by,
                name=name,
                why=why,
                e=eid,
                **new,
            )
        else:
            raise ValueError("unsupported entity_type")
        audit(c, e, i, at)
        c.run("COMMIT")
        result = {"outcome": "updated", "entity_type": typ, "entity_id": i}
        print(json.dumps(result))
        return result
    finally:
        c.close()


def handler(event, context):
    if "Records" not in event:
        return apply_event(event)
    failures = []
    for r in event["Records"]:
        try:
            apply_event(json.loads(r["body"]))
        except Exception as x:
            print(str(x))
            failures.append({"itemIdentifier": r["messageId"]})
    return {"batchItemFailures": failures}
