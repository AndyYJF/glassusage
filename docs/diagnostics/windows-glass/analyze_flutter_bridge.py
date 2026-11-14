"""Read only fixture color runs: live foreground, alpha and routed pointer reply."""
import collections
import json
import re
import sys

native,pixels=sys.argv[1:3]
def fields(line):
    return dict(re.findall(r"(\w+)=([^\s]+)",line))
events=[]
phase=None
control_phase=None
rgba_phase=None
clicks=[]
for line in open(native,encoding="utf-8",errors="replace"):
    v=fields(line)
    if line.startswith("bridge_enable "):
        phase=int(v["qpc"])
    elif line.startswith("alpha_control_start "):
        control_phase=int(v["qpc"])
    elif line.startswith("rgba_bridge_start "):
        rgba_phase=int(v["qpc"])
    elif line.startswith("dart_event "):
        e=json.loads(line.split(" json=",1)[1]); e["qpc"]=int(v["qpc"])
        events.append(e)
        if e.get("event")=="pointer_down": clicks.append(e)

def color_runs(text,origin):
    out=[]
    for color,count in re.findall(r"([0-9A-F]{6}):(\d+),",text):
        count=int(count);out.append((origin,origin+count,color));origin+=count
    return out
def color_at(row,x):
    return next((color for a,b,color in row if a<=x<b),None)
stats={k:collections.Counter() for k in ("baseline","bridge","alpha_control","rgba_bridge")}
unique={k:set() for k in stats}
alpha={k:collections.Counter() for k in ("before_click","after_click","alpha_control","rgba_bridge")}
counts=collections.Counter()
examples=[]
for line in open(pixels,encoding="utf-8",errors="replace"):
    if not line.startswith("probe_cap "):continue
    v=fields(line);qpc=int(v["last_present"]);origin=int(v["x0"])
    stage="bridge" if phase is not None and qpc>=phase else "baseline"
    if control_phase is not None and qpc>=control_phase:stage="alpha_control"
    if rgba_phase is not None and qpc>=rgba_phase:stage="rgba_bridge"
    counts[stage]+=1
    for rowname in ("c0","c1","c2","c3","c4"):
        for a,b,col in color_runs(v[rowname],origin):
            stats[stage][col]+=b-a
    row=color_runs(v["c4"],origin)
    blocks=[]
    for a,b,col in row:
        if col not in ("00FF00","FF00FF"):continue
        if blocks and a==blocks[-1][1]:blocks[-1][1]=b
        else:blocks.append([a,b])
    blocks=[x for x in blocks if x[1]-x[0]==648]
    if len(blocks)!=1:
        counts[stage+"_no_full_code"]+=1;continue
    left=blocks[0][0]
    code=sum((color_at(row,left+81*bit+40)=="00FF00")<<bit for bit in range(8))
    unique[stage].add(code);counts[stage+"_decoded"]+=1
    sample_row=color_runs(v["c0"] if stage=="baseline" else v["c1"],origin)
    values=tuple(color_at(sample_row,left+x) for x in (96,256,416))
    clicked=bool(clicks and qpc>clicks[0]["qpc"])
    if stage=="bridge":alpha["after_click" if clicked else "before_click"][str(values)]+=1
    if stage=="alpha_control" and code==197:alpha["alpha_control"][str(values)]+=1
    if stage=="rgba_bridge" and code!=197:alpha["rgba_bridge"][str(values)]+=1
    if len(examples)<4 or (stage=="bridge" and not any(x["stage"]=="bridge" for x in examples)):
        examples.append({"qpc":qpc,"stage":stage,"left":left,"code":code,"opaque_half_clear_rgb":values})
result={"phase_qpc":phase,"dart_frames":sum(e.get("event")=="frame" for e in events),
    "control_phase_qpc":control_phase,
    "rgba_phase_qpc":rgba_phase,
    "dart_frames_after_bridge":sum(e.get("event")=="frame" and e["qpc"]>=phase for e in events) if phase else 0,
    "pointer_replies":clicks,"counts":dict(counts),
    "unique_foreground_codes":{k:len(v) for k,v in unique.items()},
    "code_ranges":{k:[min(v),max(v)] if v else None for k,v in unique.items()},
    "dominant_rgb":{k:v.most_common(10) for k,v in stats.items()},
    "alpha_samples":{k:v.most_common(5) for k,v in alpha.items()},"examples":examples}
print(json.dumps(result,indent=2))
