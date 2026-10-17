from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
files=[root/'battery stuff'/name for name in ['OptimizerPolicy.swift','OptimizerService.swift','OptimizerView.swift','ManagedPythonJob.swift']]
for path in files:
    source=path.read_text()
    for pattern in [r'\bimport\s+(IOKit|Darwin)',r'IOConnectCall',r'IORegistryEntrySet',r'\b(setpriority|task_policy_set|sysctlbyname|posix_spawn|kill)\s*\(',r'\.(terminate|suspend|interrupt|resume)\s*\(',r'/bin/(ba)?sh',r'/usr/bin/pmset',r'AuthorizationExecuteWithPrivileges']:
        assert not re.search(pattern,source),f'Forbidden optimizer control in {path.name}: {pattern}'
smc=(root/'battery stuff/SMCPowerReader.swift').read_text()
assert 'private enum ReadCommand: UInt8 { case keyInfo = 9, bytes = 5 }' in smc
assert 'command: ReadCommand' in smc
assert 'command: UInt8' not in smc
assert 'command: .keyInfo' in smc and 'command: .bytes' in smc
print('Optimizer safety boundary: no hardware/system-policy/process-signal APIs; sensor command interface permits reads only.')
