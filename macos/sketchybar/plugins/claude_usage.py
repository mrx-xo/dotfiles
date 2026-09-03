#!/usr/bin/env python3
"""Parse Claude plan usage into the compact SketchyBar label."""

import json
import sys


SEVERITY_RANK = {"normal": 0, "warning": 1, "critical": 2}


def _percent(value):
    if value is None:
        return None
    return int(round(float(value)))


def _display_name(limit):
    scope = limit.get("scope") or {}
    for key in ("model", "surface"):
        scoped = scope.get(key) or {}
        name = scoped.get("display_name")
        if name:
            return name
    return ""


def _legacy_percent(response, key):
    window = response.get(key) or {}
    return _percent(window.get("utilization"))


def _severity_from_percent(percent):
    if percent >= 90:
        return "critical"
    if percent >= 70:
        return "warning"
    return "normal"


def parse_usage(response):
    current = None
    weekly = None
    fable = None
    severities = []

    for limit in response.get("limits") or []:
        percent = _percent(limit.get("percent"))
        if percent is None:
            continue

        kind = limit.get("kind")
        if kind == "session":
            current = percent
            severities.append(limit.get("severity") or "normal")
        elif kind == "weekly_all":
            weekly = percent
            severities.append(limit.get("severity") or "normal")
        elif (
            limit.get("group") == "weekly"
            and "fable" in _display_name(limit).lower()
        ):
            fable = percent
            severities.append(limit.get("severity") or "normal")

    if current is None:
        current = _legacy_percent(response, "five_hour")
    if weekly is None:
        weekly = _legacy_percent(response, "seven_day")
    if current is None or weekly is None:
        raise ValueError("Claude response has no session or weekly usage")

    segments = ["{}%".format(current), "{}%".format(weekly)]
    if fable is not None:
        primary_label = " · ".join(segments)
        fable_label = "{}% |".format(fable)
    else:
        primary_label = " · ".join(segments) + " |"
        fable_label = None

    severity = max(
        severities or ["normal"],
        key=lambda value: SEVERITY_RANK.get(value, 0),
    )
    return primary_label, fable_label, severity


def parse_history(history):
    samples = history.get("samples") or []
    usable = [
        sample
        for sample in samples
        if _percent((sample.get("u") or {}).get("fh")) is not None
        and _percent((sample.get("u") or {}).get("sd")) is not None
    ]
    if not usable:
        raise ValueError("Claude Desktop history has no complete usage sample")

    latest = max(usable, key=lambda sample: sample.get("t") or 0)
    usage = latest["u"]
    current = _percent(usage["fh"])
    weekly = _percent(usage["sd"])
    severity = _severity_from_percent(max(current, weekly))
    return "{}% · {}% |".format(current, weekly), None, severity


def main():
    try:
        data = json.load(sys.stdin)
        if len(sys.argv) > 1 and sys.argv[1] == "--history":
            primary_label, fable_label, severity = parse_history(data)
        else:
            primary_label, fable_label, severity = parse_usage(data)
    except (TypeError, ValueError, json.JSONDecodeError):
        return 1
    print("{}\t{}\t{}".format(primary_label, fable_label or "-", severity))
    return 0


if __name__ == "__main__":
    sys.exit(main())
