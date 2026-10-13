import { connect, uploadFile, downloadFile } from './client.mjs';
const $=id=>document.getElementById(id);
let key='', owner='', controller=null, running=false, complete=false;
let session=null;
try {session=JSON.parse(localStorage.getItem('moon-upload-session')||'null');} catch {localStorage.removeItem('moon-upload-session');}
const size=n=>`${(n/1024/1024).toFixed(1)} MiB`;
function message(text){$('status').textContent=text;}
function controls(){
  $('file').disabled=!key||running;
  $('start').disabled=!key||!$('file').files.length||running||complete;
  $('start').textContent=session?'继续上传':'开始上传';
  $('pause').disabled=!running;
  $('reset').disabled=running;
  $('download').disabled=!complete||!key;
  $('connect').disabled=running;
}
function showSession(){ $('resume').textContent=session?`已保存续传记录：${session.file.name}。刷新后重新选择原文件即可继续。`:''; }
showSession();
$('connect-form').addEventListener('submit',async e=>{
  e.preventDefault();
  try {const supplied=$('key').value.trim();const identity=await connect(supplied);key=supplied;owner=identity.owner;$('key').value='';$('identity').textContent=`已连接：${owner}。单文件上限 ${size(identity.maxBytes)}。`;message('请选择文件');}
  catch(e){key='';message(e.message);}
  controls();
});
$('file').addEventListener('change',()=>{complete=false;$('filename').textContent=$('file').files[0]?`${$('file').files[0].name} · ${size($('file').files[0].size)}`:'尚未选择文件';controls();});
$('start').addEventListener('click',async()=>{
  const file=$('file').files[0];if(!file)return;
  controller=new AbortController();running=true;controls();message('正在确认已上传进度…');
  try {
    session=await uploadFile(file,{key,session,signal:controller.signal,onSession:s=>{session=s;localStorage.setItem('moon-upload-session',JSON.stringify(s));showSession();},onProgress:(n,total)=>{const pct=total?Math.round(n/total*100):100;$('progress').value=pct;$('amount').textContent=`${pct}% · ${size(n)} / ${size(total)}`;message('上传中');}});
    complete=true;message('上传完成，可以下载验证');
  } catch(e){message(controller.signal.aborted?'已暂停，可以继续上传':e.message);}
  finally{running=false;controller=null;controls();}
});
$('pause').addEventListener('click',()=>controller?.abort());
$('reset').addEventListener('click',()=>{session=null;complete=false;localStorage.removeItem('moon-upload-session');$('progress').value=0;$('amount').textContent='0%';message('已清除本页记录；服务器文件未删除');showSession();controls();});
$('download').addEventListener('click',async()=>{try{await downloadFile(session,key);message('下载已开始');}catch(e){message(e.message);}});
controls();
