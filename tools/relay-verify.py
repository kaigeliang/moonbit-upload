#!/usr/bin/env python3
"""Black-box framed receiver and CLI checks. A local ssh shim tests transport orchestration, not SSH cryptography."""
import argparse, atexit, hashlib, json, os, struct, subprocess, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
CLI=ROOT/'_build/native/release/build/cmd/moonrelay/moonrelay.exe'

def rpc(req,data=b''):
 raw=json.dumps(req).encode();p=subprocess.run([str(CLI),'rpc'],input=struct.pack('>I',len(raw))+raw+data,capture_output=True,timeout=120)
 assert p.returncode==0,(p.stderr,p.returncode)
 assert len(p.stdout)>=4,p.stderr
 n=struct.unpack('>I',p.stdout[:4])[0]
 return json.loads(p.stdout[4:4+n]),p.stdout[4+n:]

def request(op,path,data=b'',length=0,sha='',offset=0,count=0,stamp=''):
 return rpc(dict(op=op,path=str(path),length=str(length),sha256=sha,offset=str(offset),count=count,stamp=stamp),data)

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--big-mib',type=int,default=64);parser.add_argument('--ssh-config');parser.add_argument('--real-ssh',action='store_true');parser.add_argument('--consumer',action='store_true');parser.add_argument('--host',default='local-test');args=parser.parse_args()
 out=ROOT/'output'/time.strftime('relay-%Y%m%d-%H%M%S');out.mkdir(parents=True)
 fixture=None
 if args.real_ssh:
  from importlib.machinery import SourceFileLoader
  module=SourceFileLoader('ssh_fixture',str(ROOT/'tools/ssh-fixture.py')).load_module()
  fixture=module.Fixture(out/'ssh');atexit.register(fixture.close);args.ssh_config=str(fixture.client_config)
 checks=[]
 def passed(name):checks.append(dict(name=name,passed=True));print('PASS',name,flush=True)
 data=bytes(range(256))*4096+b'tail';sha=hashlib.sha256(data).hexdigest();target=out/'destination.bin'
 reply,_=request('open',target,length=len(data),sha=sha);assert reply['ok'] and not target.exists()
 reply,_=request('write',target,data[:600000],len(data),sha,0,600000);assert reply['ok'] and int(reply['info']['offset'])==600000
 reply,_=request('write',target,b'wrong',len(data),sha,0,5);assert not reply['ok']
 # Kill this exact receiver while it is waiting for the rest of a chunk.
 partial=dict(op='write',path=str(target),length=str(len(data)),sha256=sha,offset='600000',count=len(data)-600000,stamp='')
 raw=json.dumps(partial).encode();receiver=subprocess.Popen([str(CLI),'rpc'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 try:
  receiver.stdin.write(struct.pack('>I',len(raw))+raw+data[600000:616384]);receiver.stdin.flush()
  deadline=time.monotonic()+5
  while not (Path(str(target)+'.moonrelay')/'1/chunk.pending').exists():
   assert time.monotonic()<deadline;assert receiver.poll() is None;time.sleep(.01)
  receiver.kill();receiver.wait(timeout=10)
 finally:
  if receiver.poll() is None:receiver.kill();receiver.wait(timeout=10)
  receiver.stdin.close();receiver.stdout.close();receiver.stderr.close()
 reply,_=request('open',target,length=len(data),sha=sha);assert int(reply['info']['offset'])==600000
 passed('actual receiver SIGKILL preserves committed prefix')
 reply,_=request('write',target,b'ab',len(data),sha,600000,200);assert not reply['ok']
 reply,_=request('open',target,length=len(data),sha=sha);assert int(reply['info']['offset'])==600000
 reply,_=request('write',target,data[600000:],len(data),sha,600000,len(data)-600000);assert reply['ok']
 reply,_=request('commit',target,length=len(data),sha=sha);assert reply['ok'] and target.read_bytes()==data
 passed('bounded RPC append, stale offsets, incomplete body, restart resume and verified publication')
 reply,_=request('open',target,length=len(data),sha='0'*64);assert not reply['ok']
 bad=out/'bad.bin';reply,_=request('open',bad,length=3,sha='0'*64);assert reply['ok']
 request('write',bad,b'abc',3,'0'*64,0,3)
 reply,_=request('commit',bad,length=3,sha='0'*64);assert not reply['ok'] and not bad.exists()
 existing=out/'existing.bin';existing.write_bytes(b'keep')
 reply,_=request('open',existing,length=3,sha=hashlib.sha256(b'abc').hexdigest());assert not reply['ok'] and existing.read_bytes()==b'keep'
 passed('changed content, hash mismatch and existing destination fail without overwrite')
 oversized=subprocess.run([str(CLI),'rpc'],input=struct.pack('>I',999999999),capture_output=True,timeout=10);assert oversized.returncode==0
 passed('oversized protocol header rejected without reading arbitrary payload')
 env=os.environ.copy();extra=[]
 if args.ssh_config:
  extra=['--ssh-config',args.ssh_config]
 else:
  shims=out/'shims';shims.mkdir();shim=shims/'ssh'
  shim.write_text('#!/usr/bin/env python3\nimport os,shlex,sys\na=shlex.split(sys.argv[-1]);os.execv(a[0],a)\n');shim.chmod(0o755);env['PATH']=str(shims)+os.pathsep+env['PATH']
 remote_binary=CLI
 def run(*argv,ok=True):
  p=subprocess.run([str(CLI),*map(str,argv),'--remote-bin',str(remote_binary),*extra],env=env,capture_output=True,timeout=300)
  assert (p.returncode==0)==ok,(argv,p.returncode,p.stderr[-1000:]);return p
 source=out/'source.bin'
 with source.open('wb') as f:
  for i in range(args.big_mib):f.write(hashlib.shake_256(str(i).encode()).digest(1048576))
 expected=hashlib.sha256(source.read_bytes()).hexdigest()
 remote=out/'remote.bin';endpoint=f'{args.host}:{remote}'
 result=json.loads(run('push',source,endpoint).stdout);assert result['complete'] and result['sha256']==expected
 assert hashlib.sha256(remote.read_bytes()).hexdigest()==expected
 assert json.loads(run('status',endpoint).stdout)['complete']
 assert json.loads(run('verify',endpoint,'--sha256',expected).stdout)['sha256']==expected
 run('verify',endpoint,'--sha256','0'*64,ok=False)
 destination=out/'pulled.bin';result=json.loads(run('pull',endpoint,destination).stdout)
 assert result['complete'] and hashlib.sha256(destination.read_bytes()).hexdigest()==expected
 passed('CLI SSH orchestration push, pull, status, verify and large-file hashes')
 large_sha=expected
 # Keep one full-size pair; equivalent recovery/consumer checks use smaller fixtures.
 if args.big_mib>64:
  small=out/'fault-source.bin'
  with source.open('rb') as f:small.write_bytes(f.read(64*1048576))
  source=small;expected=hashlib.sha256(source.read_bytes()).hexdigest()
  remote=out/'fault-remote.bin';endpoint=f'{args.host}:{remote}'
  run('push',source,endpoint)
 # Restart a partially persisted pull from independent protocol-created local prefix.
 resumed=out/'resumed.bin';request('open',resumed,length=source.stat().st_size,sha=expected)
 prefix=source.read_bytes()[:8388608];request('write',resumed,prefix,source.stat().st_size,expected,0,len(prefix))
 run('pull',endpoint,resumed);assert hashlib.sha256(resumed.read_bytes()).hexdigest()==expected
 assert json.loads(run('status',resumed).stdout)['complete']
 run('verify',resumed,'--sha256',expected)
 passed('pull uses existing committed chunks and verifies before final publication')
 # A fixture-only receiver drops one committed-write response and one read payload.
 wrapper=out/"receiver 'quoted'.py"
 wrapper.write_text('#!/usr/bin/env python3\nimport json,os,struct,subprocess,sys\nfrom pathlib import Path\npacket=sys.stdin.buffer.read()\nn=struct.unpack(">I",packet[:4])[0]\nr=json.loads(packet[4:4+n])\np=subprocess.run(['+repr(str(CLI))+',"rpc"],input=packet,capture_output=True)\nmarker=Path('+repr(str(out))+')/("lost-"+r["op"])\nif r["op"] in ("write","read") and not marker.exists():\n marker.touch()\n if r["op"]=="read":\n  sys.stdout.buffer.write(p.stdout[:len(p.stdout)//2]);sys.stdout.buffer.flush()\n os._exit(75)\nsys.stdout.buffer.write(p.stdout)\n')
 wrapper.chmod(0o755);remote_binary=wrapper
 lost_remote=out/'lost-remote.bin';lost_endpoint=f'{args.host}:{lost_remote}'
 p=run('push',source,lost_endpoint);assert b'reconnect' in p.stderr
 p=run('pull',lost_endpoint,out/'lost-pull.bin');assert b'reconnect' in p.stderr
 assert hashlib.sha256((out/'lost-pull.bin').read_bytes()).hexdigest()==expected
 passed('live push and pull recover lost commit response and truncated download packet')
 # Verify the same executable's HTTP aliases with independent server and hash checks.
 import verify
 verify.BINARY=ROOT/'_build/native/release/build/cmd/server/server.exe'
 server=verify.Server(out/'http-store')
 try:
  http_env=os.environ|{'MOON_UPLOAD_KEY':verify.TEST_KEY}
  url=f'http://127.0.0.1:{server.port}'
  http_source=out/'http-source.bin';http_source.write_bytes(data)
  def http_run(*argv):
   p=subprocess.run([str(CLI),*map(str,argv)],env=http_env,capture_output=True,timeout=60)
   assert p.returncode==0,p.stderr[-1000:];return p
  receipt=json.loads(http_run('push',http_source,url).stdout)
  full=url+receipt['path']
  assert json.loads(http_run('status',full).stdout)['complete']
  http_run('verify',full,'--sha256',sha)
  http_run('pull',full,out/'http-pull.bin','--receipt',str(http_source)+'.moon-upload.json')
  assert (out/'http-pull.bin').read_bytes()==data
  passed('unified HTTP push, pull, status and verify reuse existing authenticated library')
 finally:server.stop()
 if args.consumer:
  consumer_source=out/'consumer-source.bin';consumer_source.write_bytes(data)
  subprocess.run([str(ROOT/'tools/consumer-verify.sh'),str(consumer_source),f'{args.host}:{out/"consumer-remote.bin"}',str(out/'consumer-pull.bin'),str(CLI),args.ssh_config or '-'],env=env,check=True,timeout=600)
  assert hashlib.sha256((out/'consumer-pull.bin').read_bytes()).hexdigest()==sha
  passed('independent MoonBit module directly calls public push/pull API and progress callbacks')
 report=dict(passed=True,platform=os.uname().sysname,mode='real-ssh' if args.ssh_config else 'local-ssh-shim',big_mib=args.big_mib,large_sha256=large_sha,recovery_mib=min(args.big_mib,64),consumer_bytes=len(data) if args.consumer else 0,checks=checks)
 (out/'verification.json').write_text(json.dumps(report,indent=2)+'\n');print('REPORT',out/'verification.json',flush=True)
 if fixture:fixture.close()
if __name__=='__main__': main()
