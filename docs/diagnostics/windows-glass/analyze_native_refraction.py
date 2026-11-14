"""Decode GPU position/sequence bands; do not equate desktop time with scanout."""
import collections
import bisect
import json
import re
import statistics
import sys

def fields(line):
    return dict(re.findall(r"(\w+)=([^\s]+)",line))

def distribution(values):
    if not values:return None
    ordered=sorted(values)
    def percentile(p):
        at=(len(ordered)-1)*p
        lo=int(at);hi=min(lo+1,len(ordered)-1)
        return ordered[lo]+(ordered[hi]-ordered[lo])*(at-lo)
    return {"n":len(values),"median":statistics.median(values),"p95":percentile(.95),"max":max(values)}

def decode_candidates(text,origin,first,last):
    runs=[]
    for kind,length in re.findall(r"([GMo])(\d+)",text):
        end=origin+int(length);runs.append((origin,end,kind))
        origin=end
    # The captured checker also falls in G/M classifier ranges. Decode uniform
    # 54px cells, not total G/M cluster width, without assuming zero alignment.
    ends=[b for a,b,kind in runs]
    candidates={a-bit*54 for a,b,kind in runs for bit in range(13)
        if first<=a-bit*54<=last}
    result={}
    for left in candidates:
        value=0
        for bit in range(12):
            x=left+bit*54;index=bisect.bisect_right(ends,x)
            if index==len(runs):break
            a,b,kind=runs[index]
            if kind not in "GM" or b<x+54:break
            value|=(kind=="G")<<bit
        else:result[left]=value
    return result

source,pixels=sys.argv[1:3]
frames={};frequency=None;optics=[];clicks=[];received=0
for line in open(source,encoding="utf-8",errors="replace"):
    v=fields(line)
    if line.startswith("bridge_start "):frequency=int(v["freq"])
    elif line.startswith("native_lens_frame "):
        event={k:int(value) for k,value in v.items()};frames[event["seq"]]=event
    elif line.startswith("optics_control "):optics.append(v)
    elif line.startswith("rgba_receive "):received+=1
    elif line.startswith("dart_event "):
        event=json.loads(line.split(" json=",1)[1])
        if event.get("event")=="pointer_down":clicks.append(event)

counts=collections.Counter();first={};errors=[];error_counts=collections.Counter()
samples=collections.Counter();max_error=collections.Counter();read_end=None
for line in open(pixels,encoding="utf-8",errors="replace"):
    if line.startswith("probe_tool_end "):read_end=fields(line)
    if not line.startswith("probe_cap "):continue
    counts["desktop_images"]+=1
    v=fields(line);origin=int(v["x0"]);qpc=int(v["last_present"])
    rect=[int(x) for x in v["rect"].split(",")]
    positions=decode_candidates(v["r0"],origin,rect[0],rect[2]-648)
    sequences=decode_candidates(v["r1"],origin,rect[0],rect[2]-648)
    matches=[(left,positions[left],sequences[left]) for left in positions.keys()&sequences.keys()
        if sequences[left] in frames and frames[sequences[left]]["left"]==positions[left]
        and frames[sequences[left]]["qpc"]<=qpc]
    if not matches:
        counts["no_complete_tags"]+=1;continue
    if len(matches)!=1:
        counts["ambiguous_tags"]+=1;continue
    left,encoded,seq=matches[0];frame=frames[seq]
    counts["decoded"]+=1
    stage=str(frame["target_hz"]);samples[stage]+=1
    first[frame["seq"]]=min(qpc,first.get(frame["seq"],qpc))
    error=left-encoded
    max_error[stage]=max(max_error[stage],abs(error))
    if error:
        error_counts[stage]+=1
        if len(errors)<8:errors.append({"seq":frame["seq"],"actual_left":left,
            "encoded_left":encoded,"source_left":frame["left"],"error_px":error})

stages={}
for hz in (60,240):
    events=sorted((e for e in frames.values() if e["target_hz"]==hz),key=lambda e:e["seq"])
    observed=[e for e in events if e["seq"] in first]
    intervals=[(b["qpc"]-a["qpc"])*1000/frequency for a,b in zip(events,events[1:])]
    cpu=[(e["submitted_qpc"]-e["qpc"])*1000/frequency for e in events]
    ages=[(first[e["seq"]]-e["qpc"])*1000/frequency for e in observed]
    stages[str(hz)]={"submitted_updates":len(events),"observed_unique_updates":len(observed),
        "decoded_images":samples[str(hz)],"mismatched_images":error_counts[str(hz)],
        "max_alignment_error_px":max_error[str(hz)],
        "actual_submit_hz":1000/statistics.mean(intervals) if intervals else None,
        "submit_interval_ms":distribution(intervals),"cpu_prepare_to_commit_ms":distribution(cpu),
        "first_observed_desktop_age_ms":distribution(ages)}
print(json.dumps({"decode_method":"joint uniform 12x54px cells; source-position consistency, no zero-error assumption",
    "counts":dict(counts),"stages":stages,"optics_control":optics,
    "rgba_received":received,"pointer_replies":clicks,"mismatch_examples":errors,
    "reader_end":read_end},indent=2))
