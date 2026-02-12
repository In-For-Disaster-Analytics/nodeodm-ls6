#!/usr/bin/env python3
import argparse
import csv
import datetime as dt
import os
import re
import sys
from bisect import bisect_left
from typing import List, Tuple

LOG_HEADER_RE = re.compile(r"^===== ODM Task Output \((?P<uuid>[^)]+)\) @ (?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")
LOG_END_RE = re.compile(r"^===== End Task Output =====")

KEYWORDS = [
    "stage", "opensfm", "odm", "split", "merge", "orthophoto", "dem", "dsm", "dtm",
    "mesh", "texturing", "depth", "georefer", "entwine", "potree", "pdal", "tiles",
    "gdal", "cogeo", "filter", "reconstruct", "align", "mvs", "smvs", "mve",
]

TIME_FMT = "%Y-%m-%d %H:%M:%S"


def parse_nodeodm_events(log_path: str) -> List[Tuple[dt.datetime, str]]:
    events: List[Tuple[dt.datetime, str]] = []
    if not os.path.isfile(log_path):
        return events

    current_ts = None
    in_block = False

    with open(log_path, "r", errors="ignore") as f:
        for line in f:
            line = line.rstrip("\n")
            header = LOG_HEADER_RE.match(line)
            if header:
                ts = header.group("ts")
                try:
                    current_ts = dt.datetime.strptime(ts, TIME_FMT)
                except Exception:
                    current_ts = None
                in_block = True
                continue

            if in_block and LOG_END_RE.match(line):
                in_block = False
                current_ts = None
                continue

            if in_block and current_ts is not None:
                low = line.lower()
                if any(k in low for k in KEYWORDS):
                    events.append((current_ts, line.strip()))
    return events


def parse_time_from_line(line: str):
    line = line.strip()
    if not line:
        return None

    # Try YYYY-MM-DD HH:MM:SS
    if len(line) >= 19 and line[4] == "-" and line[7] == "-":
        ts = line[:19]
        try:
            return dt.datetime.strptime(ts, TIME_FMT)
        except Exception:
            pass

    # Try epoch seconds in first column
    m = re.match(r"^(?P<sec>\d{9,})(\.\d+)?", line)
    if m:
        sec = float(m.group("sec"))
        try:
            return dt.datetime.fromtimestamp(sec)
        except Exception:
            return None

    return None


def parse_remora_series(remora_dir: str):
    series = {}
    if not os.path.isdir(remora_dir):
        return series

    candidate_files = []
    for root, _, files in os.walk(remora_dir):
        for name in files:
            lname = name.lower()
            if any(k in lname for k in ("cpu", "mem", "memory", "io", "disk", "net", "load")):
                candidate_files.append(os.path.join(root, name))

    for path in candidate_files:
        key = os.path.basename(path).lower()
        samples = []
        with open(path, "r", errors="ignore") as f:
            for line in f:
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                ts = parse_time_from_line(line)
                if ts is None:
                    continue
                parts = line.split()
                # Store numeric columns after the timestamp column if present
                values = []
                # If timestamp is at start, remove it from parts
                if len(parts) > 0 and (parts[0].isdigit() or re.match(r"\d{4}-\d{2}-\d{2}", parts[0])):
                    parts = parts[1:]
                    if parts and re.match(r"\d{2}:\d{2}:\d{2}", parts[0]):
                        parts = parts[1:]
                for p in parts:
                    try:
                        values.append(float(p))
                    except Exception:
                        pass
                samples.append((ts, values, line.strip()))
        if samples:
            series[key] = samples

    return series


def nearest_sample(samples, t: dt.datetime):
    times = [s[0] for s in samples]
    idx = bisect_left(times, t)
    if idx == 0:
        return samples[0]
    if idx >= len(times):
        return samples[-1]
    before = samples[idx - 1]
    after = samples[idx]
    if (t - before[0]) <= (after[0] - t):
        return before
    return after


def write_events_csv(out_path: str, events, series):
    with open(out_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "event_time",
            "event_text",
            "cpu_sample_time",
            "cpu_sample_line",
            "mem_sample_time",
            "mem_sample_line",
        ])

        cpu_key = next((k for k in series.keys() if "cpu" in k), None)
        mem_key = next((k for k in series.keys() if "mem" in k or "memory" in k), None)

        cpu_samples = series.get(cpu_key, []) if cpu_key else []
        mem_samples = series.get(mem_key, []) if mem_key else []

        for ts, text in events:
            cpu = nearest_sample(cpu_samples, ts) if cpu_samples else None
            mem = nearest_sample(mem_samples, ts) if mem_samples else None
            writer.writerow([
                ts.strftime(TIME_FMT),
                text,
                cpu[0].strftime(TIME_FMT) if cpu else "",
                cpu[2] if cpu else "",
                mem[0].strftime(TIME_FMT) if mem else "",
                mem[2] if mem else "",
            ])


def main():
    ap = argparse.ArgumentParser(description="Correlate Remora output with NodeODM task logs.")
    ap.add_argument("--log", required=True, help="Path to nodeodm.log")
    ap.add_argument("--remora-dir", required=True, help="Path to remora_<jobid> directory")
    ap.add_argument("--out", required=True, help="Output directory")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)

    events = parse_nodeodm_events(args.log)
    series = parse_remora_series(args.remora_dir)

    events_csv = os.path.join(args.out, "events.csv")
    write_events_csv(events_csv, events, series)

    summary_path = os.path.join(args.out, "summary.txt")
    with open(summary_path, "w") as f:
        f.write(f"events: {len(events)}\n")
        f.write(f"remora_series: {', '.join(series.keys())}\n")

    print(f"Wrote {events_csv}")
    print(f"Wrote {summary_path}")


if __name__ == "__main__":
    main()
