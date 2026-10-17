#!/bin/zsh
set -eu
cd "${0:A:h:h}"
python3 - <<'PY'
from pathlib import Path
import subprocess
out = Path('/tmp/battery-study-ui-preview')
out.mkdir(exist_ok=True)
sources = sorted(str(p) for p in Path('battery stuff').glob('*.swift') if p.name != 'BatteryMonitorApp.swift')
subprocess.run(['swiftc','-swift-version','5','-default-isolation','MainActor','-module-cache-path','/tmp/battery-swift-cache',*sources,'Tests/UsageStudyUICheck.swift','-o',str(out/'check')],check=True,timeout=180)
subprocess.run([str(out/'check'),str(out)],check=True,timeout=20)
PY
