#!/usr/bin/python3
"""Plan test shards and merge their results (prep-pro fast path).

plan:   split the enumerated test classes into N parallel shards, balanced by
        the durations measured on earlier runs (longest first, onto the
        least loaded shard), plus one serial shard for the timing-sensitive
        classes listed in serial-tests.txt.
report: read the xcodebuild logs of every shard (and of the solo re-run of
        classes that failed in parallel), check every enumerated test has a
        result, print the merged summary, and record class durations.

Runs on the Mac's /usr/bin/python3 (3.9): keep the syntax old.
"""
import argparse
import datetime
import json
import os
import re
import statistics
import sys

TEST_ID = re.compile(r"\b([A-Za-z_]\w*)/([A-Za-z_]\w*)/(test\w*)\b")
CASE = re.compile(r"^Test Case '-\[(\w+)\.(\w+) (\w+)\]' (passed|failed|skipped) \((\d+\.\d+) seconds\)")
SUITE = re.compile(r"^Test Suite '([^']+)' (started|passed|failed) at (\S+ \S+?)\.?$")
ERROR = re.compile(r"error: -\[(\w+)\.(\w+) (\w+)\] : (.*)$")
CRASH = re.compile(r"(Restarting after unexpected exit, crash, or test timeout|Test crashed with signal|crashed with signal|The test runner exited|Early unexpected exit)")


def read_patterns(path):
    out = []
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(re.compile(line))
    return out


def read_timings(path):
    t = {}
    if path and os.path.exists(path):
        for line in open(path):
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 2:
                try:
                    t[parts[0]] = float(parts[1])
                except ValueError:
                    pass
    return t


def enumerated(path):
    """Target/Class/test identifiers from xcodebuild -enumerate-tests output."""
    text = open(path, errors="replace").read()
    return sorted(set("%s/%s/%s" % m for m in TEST_ID.findall(text)))


def cmd_plan(a):
    tests = enumerated(a.tests)
    if not tests:
        sys.exit("no tests enumerated from %s" % a.tests)
    classes = sorted(set(t.rsplit("/", 1)[0] for t in tests))
    serial_pat = read_patterns(a.serial)
    timings = read_timings(a.timings)
    known = [timings[c] for c in classes if c in timings]
    default = statistics.median(known) if known else 5.0
    cost = dict((c, timings.get(c, default)) for c in classes)
    serial = [c for c in classes if any(p.search(c) for p in serial_pat)]
    parallel = [c for c in classes if c not in serial]
    shards = [[] for _ in range(a.workers)]
    load = [0.0] * a.workers
    for c in sorted(parallel, key=lambda c: (-cost[c], c)):
        i = load.index(min(load))
        shards[i].append(c)
        load[i] += cost[c]
    os.makedirs(a.out, exist_ok=True)
    for i, s in enumerate(shards, 1):
        with open(os.path.join(a.out, "shard-%d.txt" % i), "w") as f:
            f.write("".join(c + "\n" for c in sorted(s)))
    with open(os.path.join(a.out, "shard-serial.txt"), "w") as f:
        f.write("".join(c + "\n" for c in serial))
    with open(os.path.join(a.out, "expected.txt"), "w") as f:
        f.write("".join(t + "\n" for t in tests))
    print("plan: %d tests in %d classes; %d parallel shards, estimated %s s; serial shard %d classes, estimated %.0f s"
          % (len(tests), len(classes), a.workers, "/".join("%.0f" % x for x in load),
             len(serial), sum(cost[c] for c in serial)))


def parse_log(path):
    cases = {}      # Target/Class/test -> (status, seconds)
    errors = {}     # Target/Class/test -> [messages]
    started = {}
    suites = {}     # Class -> seconds
    crashes = []
    if not os.path.exists(path):
        return cases, errors, suites, ["log missing: %s" % path]
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        m = CASE.match(line)
        if m:
            target, cls, test, status, secs = m.groups()
            cases["%s/%s/%s" % (target, cls, test)] = (status, float(secs))
            continue
        m = ERROR.search(line)
        if m:
            target, cls, test, msg = m.groups()
            errors.setdefault("%s/%s/%s" % (target, cls, test), []).append(msg.strip())
            continue
        m = SUITE.match(line)
        if m:
            name, kind, ts = m.groups()
            try:
                when = datetime.datetime.strptime(ts, "%Y-%m-%d %H:%M:%S.%f")
            except ValueError:
                continue
            if kind == "started":
                started[name] = when
            elif name in started:
                suites[name] = (when - started[name]).total_seconds()
            continue
        if CRASH.search(line):
            crashes.append(line.strip()[:240])
    return cases, errors, suites, crashes


def cmd_report(a):
    expected = [l.strip() for l in open(a.expected) if l.strip()]
    results = {}
    errors = {}
    class_secs = {}
    shard_lines = []
    crashes = {}
    for spec in a.log:
        name, path = spec.split("=", 1)
        cases, errs, suites, crash = parse_log(path)
        results.update(dict((k, (v[0], v[1], name)) for k, v in cases.items()))
        errors.update(errs)
        if crash:
            crashes[name] = crash[:5]
        for t in cases:
            target, cls, _ = t.split("/")
            if cls in suites:
                class_secs["%s/%s" % (target, cls)] = suites[cls]
        n_fail = sum(1 for v in cases.values() if v[0] == "failed")
        shard_lines.append("  %-8s %4d tests  %3d failed  %s" % (name, len(cases), n_fail, path))

    first = dict(results)
    rerun_note = []
    if a.rerun and os.path.exists(a.rerun):
        cases, errs, _, crash = parse_log(a.rerun)
        if crash:
            crashes["rerun"] = crash[:5]
        for t, (status, secs) in cases.items():
            before = first.get(t)
            if before and before[0] == "failed" and status == "passed":
                rerun_note.append(t)
            results[t] = (status, secs, "rerun")
            if status == "passed":
                errors.pop(t, None)
            else:
                errors[t] = errs.get(t, errors.get(t, []))

    missing = [t for t in expected if t not in results]
    extra = sorted(t for t in results if t not in set(expected))
    failed = sorted(t for t, v in results.items() if v[0] == "failed")
    skipped = [t for t, v in results.items() if v[0] == "skipped"]
    passed = [t for t, v in results.items() if v[0] == "passed"]

    out = []
    out.append("shards:")
    out.extend(shard_lines)
    out.append("result: %d expected, %d passed, %d failed, %d skipped, %d with no result"
               % (len(expected), len(passed), len(failed), len(skipped), len(missing)))
    if failed:
        out.append("FAILED:")
        for t in failed:
            out.append("  %s  [%s]" % (t, results[t][2]))
            for msg in errors.get(t, [])[:3]:
                out.append("      %s" % msg[:300])
    if missing:
        out.append("NO RESULT (crash, timeout or a shard that did not run):")
        out.extend("  " + t for t in missing[:60])
        if len(missing) > 60:
            out.append("  ... and %d more" % (len(missing) - 60))
    if extra:
        out.append("ran but not enumerated: %d (%s)" % (len(extra), ", ".join(extra[:5])))
    if rerun_note:
        out.append("PASSED ONLY WHEN RE-RUN ALONE (parallel-sensitive; add the class to serial-tests.txt):")
        out.extend("  " + t for t in rerun_note)
    for name, lines in crashes.items():
        out.append("crash/restart lines in %s:" % name)
        out.extend("  " + l for l in lines)
    ok = not failed and not missing
    out.append("TESTS %s" % ("PASSED" if ok else "FAILED"))
    text = "\n".join(out) + "\n"
    sys.stdout.write(text)
    if a.summary:
        open(a.summary, "w").write(text)
    if a.failed_classes:
        cls = sorted(set(t.rsplit("/", 1)[0] for t in failed + missing))
        open(a.failed_classes, "w").write("".join(c + "\n" for c in cls))
    if a.results_json:
        json.dump(dict((t, {"status": v[0], "seconds": v[1], "shard": v[2]}) for t, v in sorted(results.items())),
                  open(a.results_json, "w"), indent=1)
    if a.timings and class_secs:
        t = read_timings(a.timings)
        t.update(class_secs)
        tmp = a.timings + ".tmp"
        with open(tmp, "w") as f:
            f.write("".join("%s\t%.2f\n" % kv for kv in sorted(t.items())))
        os.replace(tmp, a.timings)
    sys.exit(0 if ok else 1)


def cmd_seed(a):
    """Seed timings.tsv from an earlier serial xcodebuild log."""
    cases, _, suites, _ = parse_log(a.log)
    t = read_timings(a.timings)
    for k in cases:
        target, cls, _ = k.split("/")
        if cls in suites:
            t["%s/%s" % (target, cls)] = suites[cls]
    with open(a.timings, "w") as f:
        f.write("".join("%s\t%.2f\n" % kv for kv in sorted(t.items())))
    print("timings: %d classes" % len(t))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd")
    pl = sub.add_parser("plan")
    pl.add_argument("--tests", required=True)
    pl.add_argument("--serial", required=True)
    pl.add_argument("--timings")
    pl.add_argument("--workers", type=int, default=4)
    pl.add_argument("--out", required=True)
    rp = sub.add_parser("report")
    rp.add_argument("--expected", required=True)
    rp.add_argument("--log", action="append", default=[], help="NAME=path")
    rp.add_argument("--rerun")
    rp.add_argument("--summary")
    rp.add_argument("--failed-classes")
    rp.add_argument("--results-json")
    rp.add_argument("--timings")
    sd = sub.add_parser("seed")
    sd.add_argument("--log", required=True)
    sd.add_argument("--timings", required=True)
    a = p.parse_args()
    if a.cmd == "plan":
        cmd_plan(a)
    elif a.cmd == "report":
        cmd_report(a)
    elif a.cmd == "seed":
        cmd_seed(a)
    else:
        p.print_help()
        sys.exit(2)


if __name__ == "__main__":
    main()
