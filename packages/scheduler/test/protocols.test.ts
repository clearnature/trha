// Protocol compatibility tests: OpenAI, Anthropic, Responses
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { createServer } from '../src/Server/index.js';

const PORT = 13456;
let server: any;

beforeAll(async () => {
  const { app } = createServer({
    port: PORT,
    token: 'test-token',
    haskellHost: 'localhost',
    haskellPort: 8080,
  });
  server = app.listen(PORT);
  // Wait for server to be ready
  await new Promise(resolve => setTimeout(resolve, 100));
});

afterAll(() => {
  server?.close();
});

const BASE = `http://localhost:${PORT}`;

// ── OpenAI Compatible ────────────────────────────────────────────────────

describe('OpenAI Compatible API', () => {
  it('GET /v1/models returns model list', async () => {
    const res = await fetch(`${BASE}/v1/models`);
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.object).toBe('list');
    expect(data.data).toBeInstanceOf(Array);
    expect(data.data.length).toBeGreaterThan(0);
    expect(data.data[0]).toHaveProperty('id');
    expect(data.data[0]).toHaveProperty('object', 'model');
    expect(data.data[0]).toHaveProperty('owned_by', 'gh-harness');
  });

  it('POST /v1/chat/completions returns completion', async () => {
    const res = await fetch(`${BASE}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'deepseek-chat',
        messages: [{ role: 'user', content: 'Hello' }],
      }),
    });
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data).toHaveProperty('id');
    expect(data).toHaveProperty('object', 'chat.completion');
    expect(data).toHaveProperty('model');
    expect(data.choices).toBeInstanceOf(Array);
    expect(data.choices[0]).toHaveProperty('message');
    expect(data.choices[0].message).toHaveProperty('role', 'assistant');
    expect(data.choices[0].message).toHaveProperty('content');
    expect(data.choices[0]).toHaveProperty('finish_reason', 'stop');
    expect(data).toHaveProperty('usage');
    expect(data.usage).toHaveProperty('prompt_tokens');
    expect(data.usage).toHaveProperty('completion_tokens');
    expect(data.usage).toHaveProperty('total_tokens');
  });

  it('POST /v1/chat/completions returns 400 without messages', async () => {
    const res = await fetch(`${BASE}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'deepseek-chat' }),
    });
    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toHaveProperty('type', 'invalid_request_error');
  });

  it('POST /v1/chat/completions with stream returns SSE', async () => {
    const res = await fetch(`${BASE}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'deepseek-chat',
        messages: [{ role: 'user', content: 'Hi' }],
        stream: true,
      }),
    });
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('text/event-stream');
    const text = await res.text();
    expect(text).toContain('data: ');
    // Either success chunks + [DONE], or error chunk
    const hasDone = text.includes('[DONE]');
    const hasError = text.includes('error');
    expect(hasDone || hasError).toBe(true);
  });
});

// ── Anthropic Compatible ─────────────────────────────────────────────────

describe('Anthropic Compatible API', () => {
  it('POST /v1/messages returns message', async () => {
    const res = await fetch(`${BASE}/v1/messages`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'deepseek-chat',
        messages: [{ role: 'user', content: 'Hello' }],
        max_tokens: 100,
      }),
    });
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data).toHaveProperty('type', 'message');
    expect(data).toHaveProperty('id');
    expect(data).toHaveProperty('role', 'assistant');
    expect(data).toHaveProperty('model');
    expect(data.content).toBeInstanceOf(Array);
    expect(data.content[0]).toHaveProperty('type', 'text');
    expect(data.content[0]).toHaveProperty('text');
    expect(data).toHaveProperty('stop_reason', 'end_turn');
    expect(data).toHaveProperty('usage');
    expect(data.usage).toHaveProperty('input_tokens');
    expect(data.usage).toHaveProperty('output_tokens');
  });

  it('POST /v1/messages with system prompt', async () => {
    const res = await fetch(`${BASE}/v1/messages`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'deepseek-chat',
        system: 'You are a helpful assistant.',
        messages: [{ role: 'user', content: 'Hello' }],
        max_tokens: 100,
      }),
    });
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data).toHaveProperty('type', 'message');
  });

  it('POST /v1/messages returns 400 without messages', async () => {
    const res = await fetch(`${BASE}/v1/messages`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'deepseek-chat' }),
    });
    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data).toHaveProperty('type', 'error');
    expect(data.error).toHaveProperty('type', 'invalid_request_error');
  });

  it('POST /v1/messages with stream returns Anthropic SSE events', async () => {
    const res = await fetch(`${BASE}/v1/messages`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'deepseek-chat',
        messages: [{ role: 'user', content: 'Hi' }],
        stream: true,
      }),
    });
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('text/event-stream');
    const text = await res.text();
    expect(text).toContain('event: message_start');
    expect(text).toContain('event: content_block_start');
    expect(text).toContain('event: content_block_delta');
    expect(text).toContain('event: content_block_stop');
    expect(text).toContain('event: message_delta');
    expect(text).toContain('event: message_stop');
  });
});

// ── Responses API ────────────────────────────────────────────────────────

describe('Responses API', () => {
  it('POST /v1/responses with string input', async () => {
    const res = await fetch(`${BASE}/v1/responses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'deepseek-chat',
        input: 'Hello',
      }),
    });
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data).toHaveProperty('object', 'response');
    expect(data).toHaveProperty('id');
    expect(data).toHaveProperty('model');
    expect(data).toHaveProperty('status', 'completed');
    expect(data.output).toBeInstanceOf(Array);
    expect(data.output[0]).toHaveProperty('type', 'message');
    expect(data.output[0]).toHaveProperty('role', 'assistant');
    expect(data.output[0].content[0]).toHaveProperty('type', 'output_text');
    expect(data.output[0].content[0]).toHaveProperty('text');
    expect(data).toHaveProperty('usage');
    expect(data.usage).toHaveProperty('input_tokens');
    expect(data.usage).toHaveProperty('output_tokens');
    expect(data.usage).toHaveProperty('total_tokens');
  });

  it('POST /v1/responses with array input', async () => {
    const res = await fetch(`${BASE}/v1/responses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'deepseek-chat',
        input: [
          { role: 'user', content: 'Hello' },
          { role: 'assistant', content: 'Hi there!' },
          { role: 'user', content: 'How are you?' },
        ],
      }),
    });
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data).toHaveProperty('status', 'completed');
  });

  it('POST /v1/responses with instructions', async () => {
    const res = await fetch(`${BASE}/v1/responses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'deepseek-chat',
        instructions: 'You are a helpful assistant.',
        input: 'Hello',
      }),
    });
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data).toHaveProperty('status', 'completed');
  });

  it('POST /v1/responses returns 400 without input', async () => {
    const res = await fetch(`${BASE}/v1/responses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'deepseek-chat' }),
    });
    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toHaveProperty('type', 'invalid_request_error');
  });

  it('POST /v1/responses with stream returns Responses SSE events', async () => {
    const res = await fetch(`${BASE}/v1/responses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'deepseek-chat',
        input: 'Hi',
        stream: true,
      }),
    });
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('text/event-stream');
    const text = await res.text();
    expect(text).toContain('event: response.created');
    expect(text).toContain('event: response.in_progress');
    expect(text).toContain('event: response.output_item.added');
    expect(text).toContain('event: response.content_part.added');
    expect(text).toContain('event: response.output_text.delta');
    expect(text).toContain('event: response.output_text.done');
    expect(text).toContain('event: response.content_part.done');
    expect(text).toContain('event: response.output_item.done');
    expect(text).toContain('event: response.completed');
  });
});

// ── Auth ─────────────────────────────────────────────────────────────────

describe('Authentication', () => {
  it('/health is accessible without auth', async () => {
    const res = await fetch(`${BASE}/health`);
    expect(res.status).toBe(200);
  });

  it('/v1/* is accessible without custom token', async () => {
    const res = await fetch(`${BASE}/v1/models`);
    expect(res.status).toBe(200);
  });

  it('/api/* requires token', async () => {
    const res = await fetch(`${BASE}/api/sessions`);
    expect(res.status).toBe(401);
  });

  it('/api/* works with valid token', async () => {
    const res = await fetch(`${BASE}/api/sessions`, {
      headers: { Authorization: 'Bearer test-token' },
    });
    expect(res.status).toBe(200);
  });
});
