#!/usr/bin/env python3
"""从便单 Python 参考实现生成黄金用例，供 Swift 单测逐项核对。

用法（在 BiandanMac 目录）:
    python3 Tools/gen_golden.py [path/to/biandan-mcp-preview-*-python.zip]

默认读取仓库 releases/ 下的 Python 发布包，输出到
Tests/BiandanMacTests/Fixtures/golden.json。
"""

import base64
from datetime import date
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlencode
import zipfile

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ZIP = ROOT.parent / "releases" / "biandan-mcp-preview-0.4.2-python.zip"
OUT = ROOT / "Tests" / "BiandanMacTests" / "Fixtures" / "golden.json"


def load_reference(zip_path):
    folder = tempfile.mkdtemp(prefix="biandan_py_")
    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(folder)
    module = next(Path(folder).rglob("biandan_recurrence.py"))
    if sys.version_info < (3, 10):
        # 参考实现用到 int.bit_count()（3.10+）。在临时副本里换成等价的 bin(x).count("1")。
        import re
        pattern = re.compile(r"\(((?:[^()]|\([^()]*\))*)\)\.bit_count\(\)")
        for source in module.parent.glob("*.py"):
            text = source.read_text(encoding="utf-8")
            patched = pattern.sub(r'bin(\1).count("1")', text)
            if patched != text:
                source.write_text(patched, encoding="utf-8")
    sys.path.insert(0, str(module.parent))
    import biandan_recurrence
    import biandan_tools
    return biandan_recurrence, biandan_tools


REC_CASES = [
    dict(name="weekly_mon_wed", start="2026-11-23", end="2026-12-31", rule={"mode": "custom", "unit": "week", "dates": ["1", "3"]}),
    dict(name="weekly_mon_wed_ws1", start="2026-11-23", end="2026-12-31", rule={"mode": "custom", "unit": "week", "dates": ["1", "3"]}, week_start=1),
    dict(name="weekly_sun_sat_ws1_from_sunday", start="2026-11-22", end="2026-12-20", rule={"mode": "custom", "unit": "week", "dates": ["0", "6"]}, week_start=1),
    dict(name="biweekly_fri", start="2026-11-01", end="2027-02-28", rule={"mode": "custom", "unit": "week", "interval": 2, "dates": ["5"]}),
    dict(name="every_2_days", start="2026-11-20", end="2026-12-20", rule={"mode": "custom", "unit": "day", "interval": 2}),
    dict(name="monthly_1_15_end", start="2026-01-01", end="2026-12-31", rule={"mode": "custom", "unit": "month", "dates": ["1", "15", "32"]}),
    dict(name="monthly_31_30_overflow", start="2026-01-01", end="2026-07-31", rule={"mode": "custom", "unit": "month", "dates": ["31", "30"]}),
    dict(name="quarterly_10", start="2026-02-10", end="2027-12-31", rule={"mode": "custom", "unit": "month", "interval": 3, "dates": ["10"]}),
    dict(name="yearly_leap", start="2024-01-01", end="2032-12-31", rule={"mode": "custom", "unit": "year", "interval": 2, "dates": ["02-29", "12-25"]}),
    dict(name="lunar_month", start="2026-01-01", end="2026-12-31", rule={"mode": "custom", "unit": "lunar_month", "dates": ["1", "15", "30"]}),
    dict(name="lunar_month_interval2", start="2025-06-01", end="2026-12-31", rule={"mode": "custom", "unit": "lunar_month", "interval": 2, "dates": ["1"]}),
    dict(name="lunar_year", start="2024-01-01", end="2030-12-31", rule={"mode": "custom", "unit": "lunar_year", "dates": ["01-01", "08-15"]}),
    dict(name="workdays_makeup", start="2026-09-15", end="2026-10-15", rule={"mode": "workdays"}, china_makeup=True),
    dict(name="workdays_plain", start="2026-09-15", end="2026-10-15", rule={"mode": "workdays"}),
    dict(name="days_off_makeup", start="2026-09-15", end="2026-10-15", rule={"mode": "days_off"}, china_makeup=True),
    dict(name="custom_week_filter_workdays", start="2026-09-28", end="2026-10-12",
         rule={"mode": "custom", "unit": "week", "dates": ["0", "1", "2", "3", "4", "5", "6"], "day_filter": "workdays"}, china_makeup=True),
    dict(name="daily_duration3", start="2026-11-20", end="2026-12-05", rule={"mode": "daily", "duration_days": 3}),
    dict(name="ebbinghaus", start="2026-11-01", end="2027-03-01", rule={"mode": "ebbinghaus"}),
    dict(name="weekly_period_ws0", start="2026-11-04", end="2026-12-31", rule={"mode": "weekly_period"}),
    dict(name="weekly_period_ws1", start="2026-11-04", end="2026-12-31", rule={"mode": "weekly_period"}, week_start=1),
    dict(name="monthly_period", start="2026-11-15", end="2027-03-01", rule={"mode": "monthly_period"}),
    dict(name="yearly_period", start="2026-06-01", end="2029-01-01", rule={"mode": "yearly_period"}),
    dict(name="from_date", start="2026-11-01", end="2026-11-30", rule={"mode": "daily"}, from_date="2026-11-25"),
    dict(name="from_date_allow_empty", start="2026-11-01", end="2026-11-10", rule={"mode": "daily"}, from_date="2026-12-01", allow_empty=True),
    dict(name="err_empty", start="2026-11-01", end="2026-11-10", rule={"mode": "daily"}, from_date="2026-12-01"),
    dict(name="err_makeup_2027", start="2027-01-01", end="2027-02-01", rule={"mode": "workdays"}, china_makeup=True),
    dict(name="err_too_many", start="2020-01-01", end="2026-12-31", rule={"mode": "daily"}),
    dict(name="err_end_before_start", start="2026-11-01", end="2026-11-05", rule={"mode": "daily"}, vs="10:00:00", ve="09:00:00"),
    dict(name="err_range", start="1890-01-01", end="1890-02-01", rule={"mode": "daily"}),
    dict(name="raw_unknown_mode", start="2026-11-20", end="2026-11-26",
         raw={"loopSet": 9, "loopUnit": 0, "loopBaseNumber": 1, "loopDate": "", "duration": 1}),
    dict(name="raw_unknown_unit", start="2026-11-20", end="2026-12-05",
         raw={"loopSet": 1, "loopUnit": 7, "loopBaseNumber": 3, "loopDate": "", "duration": 2}),
    dict(name="raw_zero_fields", start="2026-11-20", end="2026-11-24",
         raw={"loopSet": 4, "loopUnit": 0, "loopBaseNumber": 0, "loopDate": "", "duration": 0}),
]

RULE_CASES = [
    {"mode": "custom", "unit": "week", "dates": ["3", "1"]},
    {"mode": "custom", "unit": "month", "dates": ["15", "1", "32"], "interval": 2},
    {"mode": "custom", "unit": "day", "interval": 3, "duration_days": 2},
    {"mode": "custom", "unit": "week", "dates": ["1"], "day_filter": "workdays"},
    {"mode": "custom", "unit": "lunar_year", "dates": ["08-15", "01-01"]},
    {"mode": "workdays"},
    {"mode": "daily", "duration_days": 5},
    {"mode": "weekly_period"},
    {"mode": "daily", "interval": 2},
    {"mode": "custom", "unit": "week"},
    {"mode": "custom", "unit": "day", "dates": ["1"]},
    {"mode": "custom", "unit": "week", "dates": ["7"]},
    {"mode": "custom", "unit": "week", "dates": ["01"]},
    {"mode": "custom", "unit": "year", "dates": ["02-30"]},
    {"mode": "custom", "unit": "year", "dates": ["2-3"]},
    {"mode": "custom", "unit": "lunar_year", "dates": ["13-01"]},
    {"mode": "custom", "unit": "day", "interval": 0},
    {"mode": "daily", "duration_days": 367},
    {"mode": "hourly"},
]

CONTENT_RAWS = [
    "出门前确认", "", '["出门前确认","带钥匙","带证件"]',
    json.dumps([json.dumps(["备注", ["file-id-1", "file-id-2"]]), "子任务1"]),
    "[]", "[1,2]", "null", '["x", 1]', '{"a":1}',
    json.dumps([json.dumps(["n", [1]]), "s"]),
    json.dumps(['["only"]', "s"]),
    json.dumps(["123"]),
    '["a\\"b","c/d"]',
    "not json [",
    json.dumps([json.dumps(["n", []]), "s"]),
]

ENCODE_CASES = [
    ("出门前确认", ["带钥匙", "带证件"], []),
    ("", [], []),
    ("备注", ["a"], ["file-1"]),
    ('含"引号"和/斜杠', [], ["f"]),
    ("中文 emoji 😀", ["子任务"], []),
]

PROGRESS_CASES = [
    (1, 0, 0), (1, 1, 1), (3, 2, 0), (300, 100, 0), (700, 500, 0), (700, 700, 1),
    (300, -1, 0), (0, 0, 0), (99, 99, 1), (500, 400, 0), (1500, 1100, 0),
]

OCCURRENCE_ID_CASES = [
    ("1800000000000001", "2030-06-03"), ("1", "2026-11-20"),
    ("1763600000000000", "2027-01-01"), ("456", "detached"),
]

FORM_CASES = [[
    ("scope", "openid profile"),
    ("redirect_uri", "https://www.biandangroup.com/#/biandan_online"),
    ("state", "biandan-local-v1.Ab_-x~9"),
    ("x", "中文&=+?/"),
]]

PKCE_VERIFIERS = ["dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", "a", "x" * 64]


def js_compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def main():
    zip_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_ZIP
    rec, tools = load_reference(zip_path)
    out = {"source": zip_path.name}

    out["occurrence_ids"] = [{"task_id": t, "start": d, "id": rec.occurrence_id(t, d)} for t, d in OCCURRENCE_ID_CASES]

    out["content_decode"] = []
    for raw in CONTENT_RAWS:
        remark, subtasks, files = tools.decode_content(raw)
        out["content_decode"].append({"raw": raw, "remark": remark, "subtasks": subtasks, "attachments": files})

    out["content_encode"] = []
    for remark, subtasks, files in ENCODE_CASES:
        first = js_compact([remark, files]) if files else remark
        out["content_encode"].append({
            "remark": remark, "subtasks": subtasks, "attachments": files,
            "python": tools.encode_content(remark, subtasks, files),
            "js": js_compact([first, *subtasks]),
        })

    out["rules"] = []
    for rule in RULE_CASES:
        try:
            out["rules"].append({"rule": rule, "encoded": rec.encode_rule(rule)})
        except ValueError as error:
            out["rules"].append({"rule": rule, "error": str(error)})

    out["recurrence"] = []
    for case in REC_CASES:
        encoded = rec.encode_rule(case["rule"]) if "rule" in case else case["raw"]
        row = {"startTime": case["start"], "endTime": case["end"],
               "validStartTime": case.get("vs", "09:00:00"), "validEndTime": case.get("ve", "10:00:00"), **encoded}
        entry = {"name": case["name"], "row": row, "week_start": case.get("week_start", 0),
                 "china_makeup": case.get("china_makeup", False), "from_date": case.get("from_date"),
                 "allow_empty": case.get("allow_empty", False)}
        try:
            entry["windows"] = rec.recurrence_windows(
                row, week_start=entry["week_start"], china_makeup=entry["china_makeup"],
                from_date=date.fromisoformat(entry["from_date"]) if entry["from_date"] else None,
                allow_empty=entry["allow_empty"],
            )
        except ValueError as error:
            entry["error"] = str(error)
        out["recurrence"].append(entry)

    out["progress"] = []
    for unit, count, finish in PROGRESS_CASES:
        occurrence = {"attributes": {"id2": 1, "id1": 1, "startTime": "2026-11-20", "endTime": "2026-11-20",
                                     "completedCount": count, "isFinish": finish,
                                     "recentFinishedTime": "2026-11-20 10:00:00"}}
        view = tools.occurrence_view(occurrence, {"attributes": {"unitTimeNumber": unit}})
        out["progress"].append({"unitTimeNumber": unit, "completedCount": count, "isFinish": finish,
                                "completed_count": view["completed_count"], "target_count": view["target_count"],
                                "completed_subtask_indices": view["completed_subtask_indices"],
                                "status": view["status"]})

    out["form"] = [{"pairs": [list(pair) for pair in pairs], "encoded": urlencode(pairs)} for pairs in FORM_CASES]
    out["pkce"] = [{"verifier": v, "challenge": base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest())
                    .decode().rstrip("=")} for v in PKCE_VERIFIERS]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    windows = sum(len(item.get("windows", [])) for item in out["recurrence"])
    errors = sum("error" in item for item in out["recurrence"])
    print(f"wrote {OUT} · recurrence cases {len(out['recurrence'])} (windows {windows}, errors {errors}) · "
          f"rules {len(out['rules'])} · content {len(out['content_decode'])}+{len(out['content_encode'])} · "
          f"progress {len(out['progress'])}")


if __name__ == "__main__":
    main()
