// 假 stdio 语言服务器：说 Content-Length JSON-RPC，用于 lsp.ts 客户端测试。
// 行为：initialize → capabilities:{}；hover → 'fake hover'；documentSymbol →
// 一个具名符号；definition → 一个 file:///fake 位置；didOpen → 推一条假诊断；
// 其余请求 → result: null。通知（无 id）不回。
let acc = Buffer.alloc(0);
import fs from 'node:fs';
const log = (m) => { try { fs.appendFileSync('/tmp/fake-lsp.log', `${new Date().toISOString()} ${m}\n`); } catch {} };
log('started');
process.on('exit', (c) => log(`exit ${c}`));
process.on('uncaughtException', (e) => { log('uncaught: ' + e.stack); });
process.stdin.on('end', () => log('stdin end'));
process.stdin.on('error', (e) => log('stdin error: ' + e.message));

function send(msg) {
  const body = JSON.stringify(msg);
  process.stdout.write(`Content-Length: ${Buffer.byteLength(body, 'utf8')}\r\n\r\n${body}`);
}

function handle(msg) {
  if (msg.id === undefined) {
    if (msg.method === 'textDocument/didOpen') {
      const uri = msg.params?.textDocument?.uri;
      if (uri) {
        send({
          jsonrpc: '2.0',
          method: 'textDocument/publishDiagnostics',
          params: {
            uri,
            diagnostics: [{ message: 'fake diag', range: { start: { line: 0, character: 0 } }, severity: 1 }],
          },
        });
      }
    }
    return; // 通知不回
  }
  let result = null;
  switch (msg.method) {
    case 'initialize': result = { capabilities: {} }; break;
    case 'textDocument/hover': result = { contents: { value: 'fake hover' } }; break;
    case 'textDocument/documentSymbol':
      result = [{ name: 'fakeSym', kind: 12, range: { start: { line: 4 } } }];
      break;
    case 'textDocument/definition':
      result = [{ uri: 'file:///fake/x.ts', range: { start: { line: 0, character: 0 } } }];
      break;
    default: result = null;
  }
  send({ jsonrpc: '2.0', id: msg.id, result });
}

process.stdin.on('data', (chunk) => {
  acc = Buffer.concat([acc, chunk]);
  for (;;) {
    const i = acc.indexOf('\r\n\r\n');
    if (i < 0) return;
    const header = acc.slice(0, i).toString('ascii');
    const m = /Content-Length:\s*(\d+)/i.exec(header);
    if (!m) { acc = acc.slice(i + 4); continue; }
    const len = Number(m[1]);
    const start = i + 4;
    if (acc.length < start + len) return;
    const body = acc.slice(start, start + len).toString('utf8');
    acc = acc.slice(start + len);
    try { handle(JSON.parse(body)); } catch { /* 坏帧忽略 */ }
  }
});
process.stdin.resume();
