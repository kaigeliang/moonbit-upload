#!/usr/bin/env python3
"""Launch a test-only loopback sshd with generated keys and strict host verification."""
import atexit, getpass, os, socket, subprocess, time
from pathlib import Path

class Fixture:
 def __init__(self,root):
  self.root=Path(root);self.root.mkdir(parents=True,exist_ok=True)
  self.process=None
  for name in ['host','client']:
   subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(self.root/name)],check=True)
  with socket.socket() as sock:
   sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
  user=getpass.getuser()
  auth=self.root/'authorized_keys';auth.write_text((self.root/'client.pub').read_text());auth.chmod(0o600)
  config=self.root/'sshd_config';config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {self.root/'host'}
PidFile {self.root/'sshd.pid'}
AuthorizedKeysFile {auth}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM {"yes" if os.uname().sysname=="Linux" else "no"}
StrictModes no
AllowUsers {user}
LogLevel ERROR
''')
  # All test keys, paths and listener are fixture-owned. No global config is edited.
  self.log=(self.root/'sshd.log').open('wb');atexit.register(self.close)
  self.sudo=os.uname().sysname=='Linux' and os.geteuid()!=0
  launch=(['sudo','-n'] if self.sudo else [])+['/usr/sbin/sshd','-D','-e','-f',str(config)]
  self.process=subprocess.Popen(launch,stdout=self.log,stderr=self.log)
  for _ in range(100):
   if self.process.poll() is not None: raise RuntimeError((self.root/'sshd.log').read_text())
   try:
    with socket.create_connection(('127.0.0.1',port),timeout=.2):break
   except OSError:time.sleep(.05)
  else:raise TimeoutError('sshd readiness')
  known=self.root/'known_hosts';known.write_text(f'[127.0.0.1]:{port} '+(self.root/'host.pub').read_text())
  self.client_config=self.root/'ssh_config';self.client_config.write_text(f'''Host local-test
 HostName 127.0.0.1
 Port {port}
 User {user}
 IdentityFile {self.root/'client'}
 IdentitiesOnly yes
 StrictHostKeyChecking yes
 UserKnownHostsFile {known}
''')
  subprocess.run(['ssh','-F',str(self.client_config),'-o','BatchMode=yes','local-test','true'],check=True,capture_output=True)
 def close(self):
  if self.process is not None and self.process.poll() is None:
   if getattr(self,'sudo',False):
    pid_file=self.root/'sshd.pid'
    pid=pid_file.read_text().strip() if pid_file.exists() else str(self.process.pid)
    subprocess.run(['sudo','-n','kill','-TERM',pid],check=False,capture_output=True)
   else:self.process.terminate()
   self.process.wait(timeout=10)
  self.log.close()
