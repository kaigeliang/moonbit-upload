#!/usr/bin/env python3
"""Content-only SSH comparison; no global configuration or existing targets changed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import shlex
import signal
import socket
import subprocess
import threading
import time
import uuid

MIB=1024*1024

class WireProxy:
    """Count encrypted SSH stream bytes, excluding TCP/IP headers and probe SSH."""
    def __init__(self, host, port):
        self.target=(host,port);self.up=0;self.down=0;self.rate=0
        self.on_budget=None;self.budget=None
        self.lock=threading.Lock();self.sock=socket.socket();self.sock.bind(('127.0.0.1',0));self.sock.listen()
        self.port=self.sock.getsockname()[1]
        threading.Thread(target=self.accept,daemon=True).start()
    def accept(self):
        while True:
            try: local,_=self.sock.accept()
            except OSError:return
            remote=socket.create_connection(self.target,timeout=15);remote.settimeout(None)
            for source,dest,up in [(local,remote,True),(remote,local,False)]:
                threading.Thread(target=self.pipe,args=(source,dest,up),daemon=True).start()
    def pipe(self, source, dest, up):
        try:
            while True:
                data=source.recv(32768)
                if not data:break
                rate=self.rate if up else 0
                if rate:time.sleep(len(data)/rate)
                dest.sendall(data)
                with self.lock:
                    if up:self.up+=len(data)
                    else:self.down+=len(data)
                    callback=self.on_budget if up and self.budget is not None and self.up>=self.budget else None
                    if callback is not None:self.on_budget=None;self.budget=None
                if callback is not None:callback()
        except (OSError,ConnectionError):pass
        finally:
            try:dest.shutdown(socket.SHUT_WR)
            except OSError:pass
    def counts(self):
        with self.lock:return (self.up,self.down)

class Runner:
    def __init__(self,args):
        self.a=args;self.out=args.output.resolve();self.out.mkdir(parents=True,exist_ok=False)
        self.driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        self.results=[];self.tag='mrbench-'+uuid.uuid4().hex[:10]
        self.remote=args.remote_parent.rstrip('/')+'/'+self.tag
        base=['ssh','-F',str(args.ssh_config.resolve())]
        self.probe=[*base,'-o','BatchMode=yes',args.host]
        config=subprocess.check_output([*base,'-G',args.host],text=True,stderr=subprocess.DEVNULL)
        cfg=dict(line.split(' ',1) for line in config.splitlines() if ' ' in line)
        if cfg.get('proxycommand','none')!='none' or cfg.get('proxyjump','none')!='none':
            raise RuntimeError('Counting proxy requires a direct SSH route; do not silently bypass a jump/proxy')
        self.wire=WireProxy(cfg['hostname'],int(cfg['port']))
        self.control='/tmp/'+self.tag+'-%C';self.config=self.out/'ssh_config'
        self.config.write_text(f'''Host {args.host}
  ControlMaster auto
  ControlPersist 600
  ControlPath {self.control}
  Compression no
  Ciphers aes128-gcm@openssh.com
  ServerAliveInterval 0
  ProxyCommand /usr/bin/nc 127.0.0.1 {self.wire.port}
Include {args.ssh_config.resolve()}
''')
        self.ssh=['ssh','-F',str(self.config)]
        subprocess.run([*self.ssh,'-MNf',args.host],check=True)
        self.remote_run(['mkdir','-m','700',self.remote])
        self.version={'client_platform':platform.platform(),'ssh':subprocess.run(['ssh','-V'],capture_output=True,text=True).stderr.strip(),
                      'scp':'OpenSSH scp, default SFTP transport',
                      'rsync_client':subprocess.check_output([args.rsync,'--version'],text=True).splitlines()[0],
                      'receiver':self.remote_run(['uname','-sm']).strip(),
                      'rsync_receiver':self.remote_run(['rsync','--version']).splitlines()[0],
                      'moonrelay_client':subprocess.check_output([str(args.cli),'--version'],text=True).strip(),
                      'moonrelay_receiver':self.remote_run([args.remote_bin,'--version']).strip(),
                      'cli_sha256':self.digest(args.cli),
                      'receiver_cli_sha256':self.remote_run(['sha256sum',args.remote_bin]).split()[0]}
        self.source=self.out/'inputs';self.source.mkdir();self.big=self.source/'payload.bin'
        with self.big.open('wb') as f:
            for i in range(args.big_mib):f.write(hashlib.shake_256(('moonrelay-fair-bench-v1-'+str(i)).encode()).digest(MIB))
        self.tree=self.source/'smallfiles';self.tree.mkdir()
        for i in range(args.small_files):
            folder=self.tree/('group-'+str(i%4));folder.mkdir(exist_ok=True)
            (folder/f'{i:04}.bin').write_bytes(hashlib.shake_256(('small-'+str(i)).encode()).digest(65536))
        self.expected_big={'payload.bin':{'bytes':self.big.stat().st_size,'sha256':self.digest(self.big)}}
        self.expected_tree={str(p.relative_to(self.tree)):{'bytes':p.stat().st_size,'sha256':self.digest(p)} for p in self.tree.rglob('*') if p.is_file()}
        self.save()
    @staticmethod
    def digest(p):
        h=hashlib.sha256()
        with p.open('rb') as f:
            for b in iter(lambda:f.read(MIB),b''):h.update(b)
        return h.hexdigest()
    def remote_run(self,argv):
        return subprocess.check_output([*self.probe,shlex.join(argv)],text=True,timeout=120)
    def inspect(self,path,verify=False):
        program='''import pathlib,sys,json,hashlib,subprocess
p=pathlib.Path(sys.argv[1]);verify=sys.argv[2]=='yes';tool=sys.argv[3];peer=sys.argv[4]
files=[p] if p.is_file() else list(p.rglob('*')) if p.exists() else []
final={};all_files=[]
for f in files:
 if not f.is_file():continue
 rel=f.name if p.is_file() else str(f.relative_to(p));all_files.append(f)
 if any(part.endswith('.moonrelay') or part.endswith('.moonrelay-tree') or part=='.rsync-partial' or part.startswith('.') for part in pathlib.Path(rel).parts):continue
 final[rel]={'bytes':f.stat().st_size,'sha256':hashlib.sha256(f.read_bytes()).hexdigest() if verify else None}
recovery=pathlib.Path(str(p)+'.moonrelay');extra=[f for f in recovery.rglob('*') if f.is_file()] if recovery.exists() else []
tree_state=pathlib.Path(str(p)+'.moonrelay-tree')
footprint=list(p.parent.rglob('*')) if p.name=='payload.bin' else all_files+extra+(list(tree_state.rglob('*')) if tree_state.exists() else [])
footprint=set(f for f in footprint if f.is_file())
logical=sum(f.stat().st_size for f in footprint);allocated=sum(f.stat().st_blocks*512 for f in footprint)
progress_files=list(p.parent.rglob('*')) if p.name=='payload.bin' and not verify else all_files
progress=max([f.stat().st_size for f in progress_files if f.is_file()]+[0]);offset=None
if tool=='moonrelay' and recovery.exists() and not verify:
 r=subprocess.run([peer,'status',str(p)],text=True,capture_output=True)
 if r.returncode==0:offset=int(json.loads(r.stdout)['offset']);progress=offset
print(json.dumps({'files':final,'retained_logical_bytes':logical,'allocated_bytes':allocated,'progress_bytes':progress,'committed_offset':offset,'final_path_exists':p.exists()}))
'''
        return json.loads(self.remote_run(['python3','-c',program,path,'yes' if verify else 'no',self.tool,self.a.remote_bin]))
    def command(self,tool,source,target,tree=False):
        endpoint=self.a.host+':'+target
        if tool=='moonrelay':return [str(self.a.cli),'push',str(source),endpoint,'--remote-bin',self.a.remote_bin,'--ssh-config',str(self.config)]+(['--recursive'] if tree else [])
        if tool=='scp':return ['scp','-q','-B','-F',str(self.config)]+(['-r'] if tree else [])+[str(source),endpoint]
        return [self.a.rsync,'-rt','--partial-dir=.rsync-partial','--no-whole-file','--no-compress','--stats','-e',shlex.join(self.ssh),str(source)+('/' if tree else ''),endpoint]
    def sample_rss(self,pgid):
        try:
            lines=subprocess.check_output(['ps','-axo','pgid=,rss='],text=True).splitlines()
            return sum(int(line.split()[1]) for line in lines if len(line.split())==2 and int(line.split()[0])==pgid)*1024
        except (OSError,subprocess.SubprocessError):return 0
    def transfer(self,command,label,interrupt=False,target=None):
        start=time.monotonic();before=self.wire.counts();peak=0;cut=None
        with (self.out/(label+'.stdout')).open('wb') as stdout,(self.out/(label+'.stderr')).open('wb') as stderr:
            p=subprocess.Popen(command,stdout=stdout,stderr=stderr,start_new_session=True)
            done=threading.Event();exit_at=[]
            def wait_for_exit():
                p.wait();exit_at.append(time.monotonic());done.set()
            threading.Thread(target=wait_for_exit,daemon=True).start()
            if interrupt:
                def kill_at_budget():
                    nonlocal cut
                    cut={'trigger':'sender encrypted SSH stream budget','sent_bytes_observed':self.wire.counts()[0]-before[0]}
                    try:os.killpg(p.pid,signal.SIGKILL)
                    except ProcessLookupError:pass
                self.wire.budget=before[0]+self.a.cut_mib*MIB
                self.wire.on_budget=kill_at_budget
            try:
                while not done.is_set():
                    peak=max(peak,self.sample_rss(p.pid))
                    if time.monotonic()-start>900:raise TimeoutError(label)
                    time.sleep(.1)
                rc=p.wait(timeout=20)
            finally:
                if p.poll() is None:os.killpg(p.pid,signal.SIGKILL);p.wait(timeout=20)
        done.wait(20)
        seconds=(exit_at[0] if exit_at else time.monotonic())-start
        time.sleep(.1);after=self.wire.counts()
        if interrupt:
            if cut is None or rc!=-signal.SIGKILL:raise RuntimeError('Could not interrupt '+label)
        elif rc!=0:raise RuntimeError(label+' failed: '+(self.out/(label+'.stderr')).read_text(errors='replace')[-2000:])
        return {'process_seconds':seconds,'client_process_group_peak_rss_sampled_bytes':peak,
                'ssh_stream_sent_bytes':after[0]-before[0],'ssh_stream_received_bytes':after[1]-before[1],
                'exit_code':rc,'cut_observation':cut,'absolute_wire_start':before,'absolute_wire_end':after}
    def verify(self,target,expected):
        start=time.monotonic();actual=self.inspect(target,True)
        # Single-file remote basename is always payload.bin; all targets share it.
        assert actual['files']==expected,(target,actual['files'],expected)
        return actual,time.monotonic()-start
    def save(self):
        doc={'complete':False,'environment':self.version if hasattr(self,'version') else {},
             'parameters':{'big_mib':self.a.big_mib,'small_files':self.a.small_files,'small_file_bytes':65536,'rounds':self.a.rounds,'cut_target_mib':self.a.cut_mib,'cut_basis':'sender encrypted SSH stream budget; same counting-proxy callback for all tools',
                           'restart_link_cap_bytes_per_second':self.a.restart_mibps*MIB,'cipher':'aes128-gcm@openssh.com','compression':False,
                           'connection':'single prewarmed SSH ControlMaster shared by all tools; probe SSH uses separate connection',
                           'wire_counter':'encrypted SSH stream bytes through common loopback TCP relay; excludes TCP/IP headers; master setup and verification/probes excluded',
                           'memory':'sampled sum of sender process group RSS; excludes pre-existing shared SSH master; 100ms polling plus ps/probe overhead',
                           'cache':'warm/shared source, no privileged cache eviction, balanced Latin rotation, fresh receiver directories',
                           'contract':'content and relative paths only; same independent external SHA-256 after every successful command; tool built-in hashing remains enabled',
                           'durability':'process-completion and content verification, no common fsync/power-loss contract'},'driver_sha256':self.driver_sha256,'input_manifest':{'large':self.expected_big if hasattr(self,'expected_big') else {},'small_directory':self.expected_tree if hasattr(self,'expected_tree') else {}},'runs':self.results}
        (self.out/'results.json').write_text(json.dumps(doc,indent=2)+'\n')
    def run(self):
        tools=['moonrelay','scp','rsync']
        for round_no in range(self.a.rounds):
            order=tools[round_no%3:]+tools[:round_no%3]
            for scenario in self.a.scenarios:
                for tool in order:
                    self.tool=tool;root=f'{self.remote}/r{round_no+1}-{scenario}-{tool}';self.remote_run(['mkdir','-m','700',root]);target=root+'/payload.bin' if scenario!='small-directory' else root+'/tree'
                    source=self.tree if scenario=='small-directory' else self.big
                    expected=self.expected_tree if scenario=='small-directory' else self.expected_big
                    cmd=self.command(tool,source,target,scenario=='small-directory');cut=None;before=None
                    if scenario=='completed-rerun':
                        self.transfer(cmd,f'r{round_no+1}-{scenario}-{tool}-setup');self.verify(target,expected)
                    if scenario=='interrupted-restart':
                        self.wire.rate=self.a.restart_mibps*MIB
                        cut=self.transfer(cmd,f'r{round_no+1}-{scenario}-{tool}-interrupted',True,target)
                        time.sleep(1);before=self.inspect(target)
                        settled=self.wire.counts()
                        cut['settled_ssh_stream_sent_bytes']=settled[0]-cut['absolute_wire_start'][0]
                        cut['settled_ssh_stream_received_bytes']=settled[1]-cut['absolute_wire_start'][1]
                        assert 0<before['progress_bytes']<self.a.big_mib*MIB,(tool,before)
                    result=self.transfer(cmd,f'r{round_no+1}-{scenario}-{tool}')
                    actual,verification_seconds=self.verify(target,expected)
                    self.wire.rate=0
                    record={'round':round_no+1,'scenario':scenario,'tool':tool,'order':order,'command':cmd,
                            'payload_bytes':sum(f['bytes'] for f in expected.values()),'file_count':len(expected),
                            **result,'independent_sha256_passed':True,'verification_seconds':verification_seconds,
                            'verified_delivery_seconds':result['process_seconds']+verification_seconds,
                            'receiver_logical_bytes_after':actual['retained_logical_bytes'],'receiver_allocated_bytes_after':actual['allocated_bytes'],
                            'interrupted_leg':cut,'state_before_restart':before,'actual_file_hashes':actual['files'],'completed_at_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
                    if tool=='moonrelay' and scenario=='fresh' and round_no==0:
                        start_clean=time.monotonic();clean_result=self.remote_run([self.a.remote_bin,'clean',target]);clean_seconds=time.monotonic()-start_clean
                        cleaned,_=self.verify(target,expected)
                        record['optional_completed_cleanup']={'seconds':clean_seconds,'result':json.loads(clean_result),'logical_bytes_after':cleaned['retained_logical_bytes'],'allocated_bytes_after':cleaned['allocated_bytes'],'sha256_passed':True}
                    self.results.append(record);self.save()
                    assert root.startswith(self.remote+'/r') and self.tag in root
                    self.remote_run(['python3','-c','import shutil,sys;shutil.rmtree(sys.argv[1])',root])
                    print(json.dumps({k:record[k] for k in ['round','scenario','tool','process_seconds','ssh_stream_sent_bytes','verified_delivery_seconds']},ensure_ascii=False),flush=True)
        self.save();p=self.out/'results.json';doc=json.loads(p.read_text());doc['complete']=True;p.write_text(json.dumps(doc,indent=2)+'\n')
        print('BENCHMARK COMPLETE',p,flush=True)
    def close(self):
        subprocess.run([*self.ssh,'-O','exit',self.a.host],capture_output=True)
        self.wire.sock.close()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--host',required=True);p.add_argument('--ssh-config',type=Path,required=True)
    p.add_argument('--remote-parent',required=True);p.add_argument('--remote-bin',required=True)
    p.add_argument('--cli',type=Path,required=True);p.add_argument('--rsync',default='rsync')
    p.add_argument('--output',type=Path,required=True);p.add_argument('--rounds',type=int,default=3)
    p.add_argument('--big-mib',type=int,default=128);p.add_argument('--small-files',type=int,default=32)
    p.add_argument('--scenarios',nargs='+',choices=['fresh','completed-rerun','small-directory','interrupted-restart'],default=['fresh','completed-rerun','small-directory','interrupted-restart'])
    p.add_argument('--cut-mib',type=int,default=32);p.add_argument('--restart-mibps',type=int,default=8)
    args=p.parse_args()
    if args.rounds<3 or args.big_mib<=args.cut_mib+16:p.error('Use at least three rounds and a sufficiently large interruption window')
    runner=Runner(args)
    try:runner.run()
    finally:runner.close()

if __name__=='__main__':main()
