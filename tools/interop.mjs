import { Upload } from 'tus-js-client';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

const [base, resumePath, token] = process.argv.slice(2);
const input = Buffer.alloc(2 * 1024 * 1024, 'x');
async function upload(options) {
  return new Promise((resolve, reject) => {
    const task = new Upload(input, {
      endpoint: `${base}/files`, headers: { Authorization: `Bearer ${token}` }, chunkSize: 1024 * 1024,
      retryDelays: [0, 50, 100], storeFingerprintForResuming: false,
      ...options,
      onError: reject, onSuccess: () => resolve(task.url),
    });
    task.start();
  });
}
for (const options of [{}, { uploadUrl: `${base}${resumePath}` }]) {
  const url = await upload(options);
  const head = await fetch(url, { method: 'HEAD', headers: { 'Tus-Resumable': '1.0.0', Authorization: `Bearer ${token}` } });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('Upload-Offset'), String(input.length));
  const response = await fetch(`${url}/content`, {headers: {Authorization: `Bearer ${token}`}});
  assert.equal(response.status, 200);
  const downloaded = Buffer.from(await response.arrayBuffer());
  assert.equal(createHash('sha256').update(downloaded).digest('hex'),
               createHash('sha256').update(input).digest('hex'));
}
console.log(JSON.stringify({ passed: true, client: 'tus-js-client@4.3.1',
  cases: ['create and upload', 'resume pre-existing partially uploaded resource'] }));
