#!/usr/bin/env bash
set -uo pipefail

# Removes stale SSH host keys for every inventory host, needed after reflashing a Pi.

cd "$(dirname "$0")/../playbooks" || exit 1

python3 -c "
import json, subprocess
inv = json.loads(subprocess.check_output(['ansible-inventory', '--list']))
hostvars = inv.get('_meta', {}).get('hostvars', {})
targets = set(hostvars)
for v in hostvars.values():
    if 'ansible_host' in v:
        targets.add(v['ansible_host'])
for t in sorted(targets):
    subprocess.run(['ssh-keygen', '-R', t])
"
