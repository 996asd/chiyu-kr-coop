#!/usr/bin/env python3
"""KR-MP M0 Replay Hash Verifier
Compares logs/record_hashes.log vs logs/replay_hashes.log every 30 ticks.
"""
import os, re, sys

REC_LOG = r"D:\kr-mp-mod\logs\record_hashes.log"
REP_LOG = r"D:\kr-mp-mod\logs\replay_hashes.log"

LINE_RE = re.compile(r"(\w+)=([^\s]+)")

def parse_log(path):
    rows = {}
    meta = ""
    if not os.path.exists(path):
        return meta, rows
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            if ln.startswith("#"):
                meta = ln
                continue
            kv = dict(LINE_RE.findall(ln))
            if "tick" in kv and "hash" in kv:
                rows[int(kv["tick"])] = kv
    return meta, rows

def main():
    rec_path = sys.argv[1] if len(sys.argv) > 1 else REC_LOG
    rep_path = sys.argv[2] if len(sys.argv) > 2 else REP_LOG

    rec_meta, rec = parse_log(rec_path)
    rep_meta, rep = parse_log(rep_path)

    print("============================================================")
    print("  KR-MP M0 Determinism Checksum Verifier")
    print("============================================================")
    print(f"Record log: {rec_path} ({len(rec)} checkpoints)")
    if rec_meta:
        print(f"  {rec_meta}")
    print(f"Replay log: {rep_path} ({len(rep)} checkpoints)")
    if rep_meta:
        print(f"  {rep_meta}")
    print("------------------------------------------------------------")

    if not rec:
        print("[ERROR] Record log is empty or missing. Press F6 in a level to record first.")
        sys.exit(2)
    if not rep:
        print("[ERROR] Replay log is empty or missing. Press F7 in the same level to replay first.")
        sys.exit(2)

    all_ticks = sorted(rec.keys())
    matched = 0
    mismatches = []
    missing = []

    for t in all_ticks:
        if t not in rep:
            missing.append(t)
            continue
        r1 = rec[t]
        r2 = rep[t]
        if r1["hash"] == r2["hash"]:
            matched += 1
        else:
            diffs = []
            for k in ["hash", "gold", "lives", "wave", "ents", "tracked", "E", "S", "T", "B", "H", "hp", "rng", "rng_s"]:
                if r1.get(k) != r2.get(k):
                    diffs.append(f"{k}: rec={r1.get(k)} != rep={r2.get(k)}")
            mismatches.append((t, diffs, r1, r2))

    if not mismatches and not missing:
        print(f"[PASS] 100% DETERMINISTIC MATCH! {matched}/{len(all_ticks)} checkpoints matched (tick {all_ticks[0]}..{all_ticks[-1]})")
        print("       Every 30-tick hash, gold, lives, wave, entity count, HP sum, and PRNG state are identical!")
        sys.exit(0)
    else:
        print(f"[FAIL] Matched {matched}/{len(all_ticks)} | Mismatches: {len(mismatches)} | Missing: {len(missing)}")
        if mismatches:
            t, diffs, r1, r2 = mismatches[0]
            print(f"\nFirst divergence at tick {t}:")
            for d in diffs:
                print(f"  - {d}")
        if missing:
            print(f"\nMissing replay ticks (first 5): {missing[:5]}")
        sys.exit(1)

if __name__ == "__main__":
    main()
