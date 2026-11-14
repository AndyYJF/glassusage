"""Run only the authorized independent bounded window plus classified readback."""
import ctypes as c
from ctypes import wintypes as w
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).parent
settings = Path("C:/Users/AndyYan/AppData/Roaming/com.glassusage.desktop/settings.json")
before = hashlib.sha256(settings.read_bytes()).hexdigest()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
bridge = "--flutter-bridge" in sys.argv
lens = "--native-refraction" in sys.argv
if lens: bridge=True
prefix = root / (("native-refraction-" if lens else "flutter-bridge-" if bridge else "native-atomic-")+stamp)
source_log, capture_log = Path(str(prefix)+"-source.log"), Path(str(prefix)+"-pixels.log")
command = [str(root/("native_refraction_probe.exe" if lens else "flutter_bridge_probe.exe" if bridge else "native_comp_probe.exe")),str(source_log)]
if bridge:
    command.append(str(root/"flutter-bridge-assets"))
command.append("20")
probe = subprocess.Popen(command,
    cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    creationflags=subprocess.CREATE_NO_WINDOW)
reader = None
try:
    while True:
        first = probe.stdout.readline()
        if not first:
            raise RuntimeError(probe.stderr.read()[:1000] or "Probe exited before ready")
        if first.startswith('{"ready":'):
            ready = json.loads(first)
            break
    print(json.dumps({"probe_pid":probe.pid,"ready":ready,"source_log":str(source_log),"capture_log":str(capture_log)}),flush=True)
    reader = subprocess.Popen([str(root/("lagprobe_refraction.exe" if lens else "lagprobe_bridge.exe" if bridge else "lagprobe.exe")),str(ready["hwnd"]),str(capture_log),"22"],
        cwd=root, creationflags=subprocess.CREATE_NO_WINDOW)
    time.sleep(.5)
    if reader.poll() is not None and reader.returncode:
        raise RuntimeError(f"Readback exited {reader.returncode}")
    k=c.WinDLL("kernel32",use_last_error=True)
    k.OpenEventW.argtypes=[w.DWORD,w.BOOL,w.LPCWSTR]
    k.OpenEventW.restype=w.HANDLE
    k.SetEvent.argtypes=[w.HANDLE]
    k.CloseHandle.argtypes=[w.HANDLE]
    event=k.OpenEventW(2,False,ready["event"])
    if not event:
        raise c.WinError(c.get_last_error())
    try:
        if not k.SetEvent(event):
            raise c.WinError(c.get_last_error())
    finally:
        k.CloseHandle(event)
    print(json.dumps({"animation_started":True,"seconds":20}),flush=True)
    output, errors=probe.communicate(timeout=30)
    reader.wait(timeout=25)
    print(json.dumps({"probe_exit":probe.returncode,"reader_exit":reader.returncode,
        "output":output.strip(),"errors":errors.strip(),
        "settings_unchanged":hashlib.sha256(settings.read_bytes()).hexdigest()==before}),flush=True)
finally:
    for process in (probe,reader):
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
