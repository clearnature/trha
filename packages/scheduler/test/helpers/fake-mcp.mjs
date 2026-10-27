// 假 stdio MCP 服务器：newline 分隔 JSON-RPC，用于 mcp.ts 客户端测试。
// 行为：initialize → capabilities；resources/list → 一个资源；
// resources/templates/list → 一个模板；resources/read → 文本内容。
import readline from 'node:readline';

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

const FAIL = process.env.FAKE_MCP_FAIL === '1';

function handle(msg) {
  if (msg.id === undefined) return; // 通知不回
  if (FAIL && msg.method !== 'initialize') {
    send({ jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: 'boom' } });
    return;
  }
  let result = null;
  switch (msg.method) {
    case 'initialize': result = { capabilities: {} }; break;
    case 'resources/list':
      result = { resources: [{ uri: 'file:///fake/a.txt', name: 'a', mimeType: 'text/plain' }] };
      break;
    case 'resources/templates/list':
      result = { resourceTemplates: [{ uriTemplate: 'file:///fake/{id}', name: 'tpl' }] };
      break;
    case 'resources/read':
      result = { contents: [{ uri: msg.params?.uri ?? 'file:///fake/a.txt', mimeType: 'text/plain', text: 'fake resource body' }] };
      break;
    default: result = {};
  }
  send({ jsonrpc: '2.0', id: msg.id, result });
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  const t = line.trim();
  if (!t) return;
  try { handle(JSON.parse(t)); } catch { /* 坏行忽略 */ }
});
rl.on('close', () => process.exit(0));
