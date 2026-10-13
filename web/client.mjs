export class UploadError extends Error {}
const credentials = key => {
  if (!/^[a-f0-9]{64}$/.test(key)) throw new UploadError('访问密钥应为 64 位小写十六进制字符');
  return { Authorization: `Bearer ${key}`, 'Tus-Resumable': '1.0.0' };
};
async function check(response) {
  if (!response.ok) {
    const messages = {401:'访问密钥无效',403:'当前用户不能访问这个上传',409:'上传正在处理或偏移已变化',413:'文件或分块超过限制',408:'上传超时，请继续重试',507:'存储配额不足'};
    throw new UploadError(messages[response.status] || `请求失败（${response.status}）`);
  }
  return response;
}
export async function connect(key) {
  return (await check(await fetch('/session', {headers:credentials(key)}))).json();
}
function uploadPath(path) {
  if (!/^\/files\/[0-9]{1,23}$/.test(path)) throw new UploadError('无效的上传地址');
  return path;
}
export async function offsetOf(path, key, signal) {
  const r = await check(await fetch(uploadPath(path), {method:'HEAD',headers:credentials(key),signal}));
  const offset = Number(r.headers.get('Upload-Offset'));
  if (!Number.isSafeInteger(offset) || offset < 0) throw new UploadError('服务器返回无效偏移');
  return offset;
}
export async function uploadFile(file, {key, session=null, signal, onSession=()=>{}, onProgress=()=>{}}) {
  const identity = await connect(key);
  const fingerprint = {name:file.name,size:file.size,lastModified:file.lastModified};
  if (file.size > identity.maxBytes) throw new UploadError('文件超过服务允许的大小');
  if (session) {
    if (session.owner !== identity.owner || JSON.stringify(session.file) !== JSON.stringify(fingerprint)) {
      throw new UploadError('请使用原用户并重新选择同一个文件');
    }
    uploadPath(session.path);
  } else {
    const r = await check(await fetch('/files', {method:'POST',headers:{...credentials(key),'Upload-Length':String(file.size)},signal}));
    session = {path:uploadPath(r.headers.get('Location')), owner:identity.owner, file:fingerprint};
    onSession(session);
  }
  let offset = await offsetOf(session.path, key, signal);
  if (offset > file.size) throw new UploadError('服务器偏移超过文件大小');
  onProgress(offset, file.size);
  while (offset < file.size) {
    signal?.throwIfAborted();
    const blob = file.slice(offset, Math.min(file.size, offset + Math.min(identity.chunkBytes, 1024*1024)));
    let lastError;
    for (let attempt=0; attempt<3; attempt++) {
      try {
        const r = await check(await fetch(session.path, {method:'PATCH',headers:{...credentials(key),'Upload-Offset':String(offset),'Content-Type':'application/offset+octet-stream'},body:blob,signal}));
        const next = Number(r.headers.get('Upload-Offset'));
        if (next !== offset + blob.size) throw new UploadError('上传确认偏移不正确');
        offset=next; lastError=null; break;
      } catch (e) {
        if (signal?.aborted || e instanceof UploadError) throw e;
        lastError=e;
        await new Promise(resolve=>setTimeout(resolve,200*(attempt+1)));
        const committed = await offsetOf(session.path,key,signal);
        if (committed===offset+blob.size) {offset=committed;lastError=null;break;}
        if (committed!==offset) throw new UploadError('上传进度发生冲突，请暂停后重新续传');
      }
    }
    if (lastError) throw new UploadError('网络连接失败；进度已保存，可稍后续传');
    onProgress(offset,file.size);
  }
  return session;
}
export async function downloadFile(session, key) {
  const r = await check(await fetch(uploadPath(session.path)+'/content', {headers:credentials(key)}));
  // Browser saves the response body; very large downloads may consume memory.
  const url=URL.createObjectURL(await r.blob());
  const a=document.createElement('a'); a.href=url;a.download=session.file.name;a.click();
  setTimeout(()=>URL.revokeObjectURL(url),60000);
}
