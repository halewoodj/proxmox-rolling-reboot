"""Exercise upstream script failure paths using fake SSH only."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
VERSION = subprocess.check_output([BASH,'--version'],text=True)
BASH_MAJOR = int(re.search(r'version (\d+)',VERSION).group(1))

SSH = '''#!/usr/bin/env python3
import json,os,shlex,subprocess,sys
command=sys.argv[-1]
tokens=shlex.split(command)
if 'bash' in tokens and '-lc' in tokens: command=tokens[-1]
with open(os.environ['TEST_COMMAND_LOG'],'a') as f: f.write(json.dumps(command)+'\\n')
if command=='true' or command.startswith('command -v '): pass
elif 'pvecm nodes' in command: print('1 1 NODE-1 (local)\\n2 1 NODE-2')
elif command.startswith('hostname'): print('NODE-1')
elif command=='pvecm status': print('Quorate: Yes')
elif command=='ceph health': print('HEALTH_OK')
elif 'qm list' in command:
 sys.exit(subprocess.call([os.environ['TEST_BASH'],'-c',command]))
elif 'apt-get update' in command:
 if os.environ.get('TEST_APT_FAIL'): sys.exit(100)
elif 'apt-get -s dist-upgrade' in command: print('Inst example [1] (2 repo [amd64])')
elif command=='pveversion': print('pve-manager/test')
elif command=='uname -r': print('6.8.1-pve')
elif 'vmlinuz-' in command: print('6.8.2-pve')
elif command=='[ -f /var/run/reboot-required ]': sys.exit(1)
else:
 print('Forbidden fake SSH command: '+command,file=sys.stderr)
 sys.exit(91)
'''


class ScriptTests(unittest.TestCase):
    def run_script(self, filename, **extra):
        with tempfile.TemporaryDirectory() as tmp:
            tmp=Path(tmp)
            path=tmp/'ssh'
            path.write_text(SSH.replace('#!/usr/bin/env python3','#!'+sys.executable))
            path.chmod(0o700)
            for command, kind in [('qm','qemu'),('pct','lxc')]:
                p=tmp/command
                p.write_text('#!/bin/sh\nif [ "$TEST_LIST_FAILURE" = "'+kind+'" ]; then exit 1; fi\nexit 0\n')
                p.chmod(0o700)
            log=tmp/'commands.jsonl'
            env=os.environ.copy()
            env.update(PATH=str(tmp)+os.pathsep+env['PATH'],TEST_COMMAND_LOG=str(log),
                       TEST_BASH=BASH,TERM='dumb',**extra)
            args=[BASH,str(ROOT/filename),'--cluster-host','root@NODE-1',
                  '--nodes','NODE-1,NODE-2','--dry-run']
            if filename=='rolling-reboot.sh': args.extend(['--yes','--direct-node-ssh','--ceph-timeout','1'])
            result=subprocess.run(args,env=env,capture_output=True,text=True,timeout=30)
            commands=[json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, commands

    @unittest.skipUnless((ROOT/'update.sh').exists() and BASH_MAJOR>=4,'requires updater and Bash 4+')
    def test_failed_apt_update_returns_failure(self):
        result,commands=self.run_script('update.sh',TEST_APT_FAIL='1')
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('apt-get update failed',result.stdout)
        self.assertFalse(any('dist-upgrade' in c for c in commands))

    @unittest.skipUnless((ROOT/'update.sh').exists() and BASH_MAJOR>=4,'requires updater and Bash 4+')
    def test_updater_preview_does_not_apply_package_changes(self):
        result,commands=self.run_script('update.sh')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(sum('apt-get -s dist-upgrade' in c for c in commands),2)
        self.assertFalse(any('-y dist-upgrade' in c or 'autoremove' in c or 'apt-get clean' in c for c in commands))

    @unittest.skipUnless(not (ROOT/'update.sh').exists(),'standalone reboot repository')
    def test_failed_qm_list_stops_before_reboot(self):
        result,commands=self.run_script('rolling-reboot.sh',TEST_LIST_FAILURE='qemu')
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('Could not list guests',result.stdout+result.stderr)
        self.assertFalse(any('systemctl reboot' in c or ' migrate ' in c for c in commands))

    @unittest.skipUnless(not (ROOT/'update.sh').exists(),'standalone reboot repository')
    def test_failed_pct_list_stops_before_reboot(self):
        result,commands=self.run_script('rolling-reboot.sh',TEST_LIST_FAILURE='lxc')
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('Could not list guests',result.stdout+result.stderr)
        self.assertFalse(any('systemctl reboot' in c or ' migrate ' in c for c in commands))


if __name__=='__main__': unittest.main()
