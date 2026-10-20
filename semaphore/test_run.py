"""Safety checks run with fake SSH and Bash; no network or package operations."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / 'semaphore/run.py'

FAKE_SSH = '''#!/usr/bin/env python3
import os,sys
args=sys.argv[1:]
dest=next(a for a in args if a.startswith('root@'))
command=args[-1]
node=dest.split('@')[1]
if command=='hostname -s': print(node)
elif command=='pvecm nodes':
 print('1 1 NODE-1 (local)\\n2 1 NODE-2')
 if os.environ.get('TEST_EXTRA_MEMBER'): print('3 1 NODE-3')
elif command=='pvecm status': print('Quorate: '+os.environ.get('TEST_QUORUM','Yes'))
elif command=='ceph health': print(os.environ.get('TEST_HEALTH','HEALTH_OK'))
else: sys.exit(90)
'''
FAKE_BASH = '''#!/usr/bin/env python3
import os,sys,json
assert 'PVE_SSH_PRIVATE_KEY' not in os.environ
with open(os.environ['TEST_INVOCATION'],'w') as f: json.dump(sys.argv[1:],f)
sys.exit(int(os.environ.get('TEST_SCRIPT_RC','0')))
'''


class RunnerTests(unittest.TestCase):
    def run_case(self, *args, **extra):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            for name, source in [('ssh', FAKE_SSH), ('bash', FAKE_BASH)]:
                p = tmp / name
                p.write_text(source.replace('#!/usr/bin/env python3', '#!' + sys.executable))
                p.chmod(0o700)
            invocation = tmp / 'invocation.json'
            env = os.environ.copy()
            env.update(PATH=str(tmp) + os.pathsep + env.get('PATH', ''),
                       PVE_NODES_JSON=json.dumps({'NODE-1':'192.0.2.1','NODE-2':'192.0.2.2'}),
                       PVE_CLUSTER_HOST='NODE-1', PVE_KNOWN_HOSTS='NODE-1 ssh-ed25519 fake',
                       PVE_SSH_PRIVATE_KEY='SECRET-MARKER', TEST_INVOCATION=str(invocation), **extra)
            result = subprocess.run([sys.executable, str(RUNNER), *args],env=env,
                                    text=True,capture_output=True,timeout=10)
            self.assertNotIn('SECRET-MARKER',result.stdout + result.stderr)
            return result, json.loads(invocation.read_text()) if invocation.exists() else None

    def test_preview_is_dry_run_and_scoped(self):
        result, args = self.run_case('preview')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--dry-run', args)
        self.assertEqual(args[args.index('--nodes')+1], 'NODE-1,NODE-2')
        self.assertEqual(args[args.index('--cluster-host')+1], 'root@NODE-1')
        if (ROOT / 'update.sh').exists():
            self.assertEqual(args[args.index('--jobs')+1], '1')
        else:
            self.assertIn('--direct-node-ssh', args)
            self.assertIn('--yes', args)
            self.assertNotIn('--skip-ceph-check', args)

    def test_apply_has_explicit_mode(self):
        result, args = self.run_case('apply', '--nodes', 'NODE-2')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('--dry-run',args)
        self.assertEqual(args[args.index('--nodes')+1], 'NODE-2')

    def test_extra_cluster_member_blocks_maintenance(self):
        result, args = self.run_case('preview', TEST_EXTRA_MEMBER='1')
        self.assertNotEqual(result.returncode,0)
        self.assertIsNone(args)

    def test_no_quorum_blocks_maintenance(self):
        result, args = self.run_case('apply', TEST_QUORUM='No')
        self.assertNotEqual(result.returncode,0)
        self.assertIsNone(args)

    def test_ceph_warning_blocks_maintenance(self):
        result, args = self.run_case('apply', TEST_HEALTH='HEALTH_WARN testing')
        self.assertNotEqual(result.returncode,0)
        self.assertIsNone(args)

    def test_out_of_scope_selection_blocks_maintenance(self):
        result, args = self.run_case('apply','--nodes','NODE-3')
        self.assertNotEqual(result.returncode,0)
        self.assertIsNone(args)

    def test_script_failure_is_reported(self):
        result, args = self.run_case('preview',TEST_SCRIPT_RC='42')
        self.assertEqual(result.returncode,42)
        self.assertIsNotNone(args)


if __name__ == '__main__':
    unittest.main()
