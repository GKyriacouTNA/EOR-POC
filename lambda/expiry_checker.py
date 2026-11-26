import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "vendor"))
import pg8000.native

from handler import ID_NAMESPACE, apply_event, db_connection, expand_events


def build_expiry_event(row, event_group_id):
    sensitivity_id, sensitivity_end = row[0], row[1]
    if isinstance(sensitivity_end, datetime.datetime):
        sensitivity_end = sensitivity_end.date()
    end_str = sensitivity_end.isoformat() if hasattr(sensitivity_end, "isoformat") else str(sensitivity_end)
    return {
        "entity_type": "sensitivity",
        "entity_key": {"sensitivity_id": str(sensitivity_id)},
        "change_type": "U",
        "changes": {"sensitivity_status": "expired"},
        "changed_by": {"id": "system.expiry_checker", "name": "Expiry Checker"},
        "reason": f"Sensitivity end {end_str} passed; status changed to expired",
        "source": "expiry-checker",
        "event_group_id": event_group_id,
    }


def handler(event, context=None):
    request_id = getattr(context, "aws_request_id", None) or str(uuid.uuid4())
    event_group_id = str(uuid.uuid5(ID_NAMESPACE, f"expiry-check:{request_id}:{datetime.date.today().isoformat()}"))
    c = db_connection()
    try:
        rows = c.run(
            "SELECT sensitivity_id, sensitivity_end FROM archive.sensitivity "
            "WHERE sensitivity_status='active' AND sensitivity_end IS NOT NULL "
            "AND sensitivity_end < current_date ORDER BY sensitivity_end, sensitivity_id"
        )
        summary = {"event_group_id": event_group_id, "candidates": len(rows), "applied": 0, "duplicates": 0, "failed": 0, "results": []}
        for row in rows:
            raw = build_expiry_event(row, event_group_id)
            end = row[1].isoformat() if hasattr(row[1], "isoformat") else str(row[1])
            e = expand_events(raw, event_group_id=event_group_id, base_id=f"expiry:{row[0]}:{end}")[0]
            e["source_event_id"] = str(uuid.uuid5(ID_NAMESPACE, f"expiry-review:{row[0]}:{end}"))
            try:
                result = apply_event(e, c=c, managed=True)
                outcome = result.get("outcome", "unknown")
                if outcome == "duplicate":
                    summary["duplicates"] += 1
                else:
                    summary["applied"] += 1
                summary["results"].append(result)
            except Exception as x:
                try:
                    c.run("ROLLBACK")
                except Exception:
                    pass
                summary["failed"] += 1
                summary["results"].append(
                    {
                        "outcome": "failed",
                        "event_group_id": event_group_id,
                        "source_event_id": e.get("source_event_id"),
                        "entity_key": e.get("entity_key"),
                        "error": str(x),
                    }
                )
        print(json.dumps({k: v for k, v in summary.items() if k != "results"}))
        return summary
    finally:
        c.close()
