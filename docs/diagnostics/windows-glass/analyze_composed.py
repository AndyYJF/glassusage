"""Correlate classified composed pixels with the opt-in callback pattern."""
import bisect
import json
import re
import sys
from collections import Counter


def fields(line):
    return dict(re.findall(r"(\w+)=([^\s]+)", line))


def distribution(values):
    values = sorted(values)
    if not values:
        return None
    return {
        "n": len(values), "min": values[0],
        "median": values[len(values) // 2],
        "p95": values[int((len(values) - 1) * .95)], "max": values[-1],
    }


callbacks = []
moves = []
frequency = None
with open(sys.argv[1], encoding="utf-8", errors="replace") as source:
    for line in source:
        if line.startswith("probe_start "):
            frequency = int(fields(line)["freq"])
        elif line.startswith("probe_cb ") or ("--surface" in sys.argv and line.startswith("visual_frame ")):
            item = fields(line)
            callbacks.append((int(item["qpc"]), int(item["seq"]),
                              tuple(map(int, item["view"].split(",")))))
        elif line.startswith("probe_move "):
            item = fields(line)
            moves.append((int(item["qpc"]), int(item["x"]), int(item["y"])))
callbacks.sort()
by_code = {}
for callback in callbacks:
    by_code.setdefault(callback[1] & 255, []).append(callback)
code_times = {code: [item[0] for item in items] for code, items in by_code.items()}


def runs(text, origin):
    result = []
    for kind, count in re.findall(r"([GMo])(\d+)", text):
        count = int(count)
        result.append((origin, origin + count, kind))
        origin += count
    return result


def color_at(row, x):
    return next((kind for left, right, kind in row if left <= x < right), "o")


def decode_row(row, width, output_right, allow_right_clip):
    clusters = []
    for left, right, kind in row:
        if kind == "o":
            continue
        if clusters and left - clusters[-1][1] <= 12:
            clusters[-1][1] = right
        else:
            clusters.append([left, right])
    decoded = []
    for left, right in clusters:
        complete = abs(right - left - width) <= 3
        clipped_right = (allow_right_clip and output_right - 8 <= right <= output_right
                         and width * .75 <= right - left < width)
        if not complete and not clipped_right:
            continue
        colors = [(bit, color_at(row, left + width * (bit + .5) / 8))
                  for bit in range(8) if left + width * (bit + .5) / 8 < right]
        if any(kind == "o" for _, kind in colors):
            continue
        code = sum((kind == "G") << bit for bit, kind in colors)
        mask = sum(1 << bit for bit, _ in colors)
        decoded.append((left, code, mask))
    return decoded


captures = []
failures = Counter()
tool_summary = None
output_right = None
masked_callbacks = {}
with open(sys.argv[2], encoding="utf-8", errors="replace") as source:
    for line in source:
        if line.startswith("probe_tool_start "):
            output_right = int(fields(line)["output"].split(",")[2])
        if line.startswith("probe_tool_end "):
            tool_summary = fields(line)
        if not line.startswith("probe_cap "):
            continue
        item = fields(line)
        present = int(item["last_present"])
        rect = tuple(map(int, item["rect"].split(",")))
        width = next((int(a.split("=",1)[1]) for a in sys.argv if a.startswith("--pattern-width=")), rect[2] - rect[0])
        origin = int(item["x0"])
        rows = {key: runs(item[key], origin) for key in ("r0", "r1", "r3", "r4", "r5")}
        decoded = []
        for key in ("r4", "r3", "r5"):
            candidates = decode_row(rows[key], width, output_right, rect[2] > output_right)
            if len(candidates) == 1:
                decoded.append((key, *candidates[0]))
        if not decoded:
            failures["no_full_width_code_row"] += 1
            continue
        key, left, code, mask = decoded[0]
        if any(abs(other_left - left) > 3 or (other_code ^ code) & (other_mask & mask)
               for _, other_left, other_code, other_mask in decoded[1:]):
            failures["code_rows_disagree"] += 1
            continue
        if mask == 255:
            choices, times = by_code.get(code, []), code_times.get(code, [])
        else:
            cache_key = (mask, code)
            if cache_key not in masked_callbacks:
                choices = [cb for cb in callbacks if cb[1] & mask == code]
                masked_callbacks[cache_key] = (choices, [cb[0] for cb in choices])
            choices, times = masked_callbacks[cache_key]
        index = bisect.bisect_right(times, present) - 1
        if index < 0:
            failures["no_matching_callback"] += 1
            continue
        callback_qpc, sequence, view = choices[index]
        age_ms = (present - callback_qpc) * 1000 / frequency
        if age_ms > 1000:
            failures["ambiguous_or_old_code"] += 1
            continue
        error_px = left - view[0]
        green_edges = [a for key in ("r0", "r1") for a, b, kind in rows[key]
                       if kind == "G" and abs(b - a - 64) <= 1]
        stripe_ok = any(abs(((edge - error_px + 256) % 512) - 256) <= 2
                        for edge in green_edges)
        if not stripe_ok:
            failures["stripe_crosscheck_failed"] += 1
            continue
        captures.append({"qpc": present, "seq": sequence, "age_ms": age_ms,
                         "error_px": error_px, "pixel_left": left,
                         "callback_left": view[0], "live_left": rect[0],
                         "code_bits": mask.bit_count(),
                         "acquired_qpc": int(item["qpc"])})

if not captures:
    print(json.dumps({"matched": 0, "failures": failures, "tool": tool_summary}))
    sys.exit(0)
first, last = captures[0]["qpc"], captures[-1]["qpc"]
in_run_moves = [move for move in moves if first <= move[0] <= last]
moving = [frame for frame in captures if any(
    move[0] - frequency * .03 <= frame["qpc"] <= move[0] + frequency * .2
    for move in in_run_moves)]
first_seen = {}
for frame in captures:
    first_seen.setdefault(frame["seq"], frame)
result = {
    "matched": len(captures), "failures": failures, "tool": tool_summary,
    "partially_clipped_code_frames": sum(f["code_bits"] < 8 for f in captures),
    "moves_qpc_x_y": in_run_moves,
    "all_composed_callback_age_ms": distribution([f["age_ms"] for f in captures]),
    "first_seen_callback_age_ms": distribution([f["age_ms"] for f in first_seen.values()]),
    "all_abs_position_error_px": distribution([abs(f["error_px"]) for f in captures]),
    "all_nonzero_error_frames": sum(f["error_px"] != 0 for f in captures),
    "moving_callback_age_ms": distribution([f["age_ms"] for f in moving]),
    "moving_abs_position_error_px": distribution([abs(f["error_px"]) for f in moving]),
    "nonzero_error_frames": sum(f["error_px"] != 0 for f in moving),
    "moving_examples": sorted(moving, key=lambda f: abs(f["error_px"]), reverse=True)[:12],
}
result["move_timelines"] = []
for move_qpc, move_x, move_y in in_run_moves:
    prior_frame = next((f for f in reversed(captures) if f["qpc"] < move_qpc), None)
    if prior_frame and prior_frame["pixel_left"] == move_x:
        result["move_timelines"].append({"move_qpc": move_qpc, "move_x": move_x,
            "move_y": move_y, "status": "no_horizontal_change; vertical offset not measured"})
        continue
    nearby = [f for f in captures if move_qpc - frequency * .01 <= f["qpc"] <= move_qpc + frequency * .5]
    correct = next((f for f in nearby if f["qpc"] >= move_qpc and
                    f["pixel_left"] == move_x and f["callback_left"] == move_x), None)
    wrong = [f for f in nearby if f["qpc"] >= move_qpc and
             f["pixel_left"] == move_x and f["error_px"] != 0]
    result["move_timelines"].append({
        "move_qpc": move_qpc, "move_x": move_x, "move_y": move_y,
        "axes": "horizontal_only",
        "first_correct_ms": (correct["qpc"] - move_qpc) * 1000 / frequency if correct else None,
        "first_correct_seq": correct["seq"] if correct else None,
        "wrong_composed_frames": len(wrong),
        "first_wrong_ms": (wrong[0]["qpc"] - move_qpc) * 1000 / frequency if wrong else None,
        "last_wrong_ms": (wrong[-1]["qpc"] - move_qpc) * 1000 / frequency if wrong else None,
    })
if "--summary" in sys.argv:
    result["native_move_count"] = len(in_run_moves)
    result.pop("moves_qpc_x_y", None)
    result.pop("move_timelines", None)
if "--export" in sys.argv:
    from pathlib import Path
    exported = Path(sys.argv[2] + ".decoded.json")
    exported.write_text(json.dumps({"frames": captures, "moves": in_run_moves,
                                   "frequency": frequency, "failures": failures}), encoding="utf-8")
    result["decoded_export"] = str(exported)
print(json.dumps(result, indent=2))
