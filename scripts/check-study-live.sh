#!/bin/zsh
set -eu
cd "${0:A:h:h}"
python3 - <<'PY'
import subprocess,sys,tempfile
from pathlib import Path
with tempfile.TemporaryDirectory(prefix='battery-study-live-') as directory:
    binary=Path(directory)/'check'
    subprocess.run(['swiftc','-module-cache-path','/tmp/battery-swift-cache','battery stuff/UsageStudyModels.swift','battery stuff/UsageProcessCollector.swift','Tests/UsageCollectorLiveCheck.swift','-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary),sys.executable],check=True,timeout=30)
PY
