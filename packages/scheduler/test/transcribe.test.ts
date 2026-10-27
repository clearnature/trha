import { afterEach, describe, expect, it, vi } from 'vitest';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  AsrNotConfigured,
  asrConfigured,
  transcribeWav,
} from '../src/Server/transcribe.js';

const ENV = ['TRHA_ASR_BASE_URL', 'TRHA_ASR_MODEL', 'TRHA_ASR_KEY', 'TRHA_ASR_LANGUAGE'];

afterEach(() => {
  for (const k of ENV) delete process.env[k];
  vi.unstubAllGlobals();
});

async function wavFile(bytes = 100): Promise<{ dir: string; file: string }> {
  const dir = await mkdtemp(path.join(tmpdir(), 'trha-asr-'));
  const file = path.join(dir, 'voice.wav');
  await writeFile(file, Buffer.alloc(bytes, 1));
  return { dir, file };
}

function configure(): void {
  process.env.TRHA_ASR_BASE_URL = 'http://asr.test/v1';
  process.env.TRHA_ASR_MODEL = 'asr-1';
  process.env.TRHA_ASR_KEY = 'k';
}

describe('asrConfigured', () => {
  it('is false without base url and model', () => {
    expect(asrConfigured()).toBe(false);
  });

  it('is true when both are set', () => {
    configure();
    expect(asrConfigured()).toBe(true);
  });
});

describe('transcribeWav', () => {
  it('throws AsrNotConfigured when unconfigured', async () => {
    const { dir, file } = await wavFile();
    try {
      await expect(transcribeWav(file)).rejects.toBeInstanceOf(AsrNotConfigured);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it('posts an input_audio chat completion and returns the text', async () => {
    configure();
    const calls: { url: string; body: Record<string, unknown> }[] = [];
    vi.stubGlobal('fetch', async (url: string, init: { body?: string }) => {
      calls.push({ url, body: JSON.parse(init.body ?? '{}') as Record<string, unknown> });
      return new Response(JSON.stringify({ choices: [{ message: { content: ' 你好 ' } }] }), {
        status: 200,
      });
    });

    const { dir, file } = await wavFile();
    try {
      await expect(transcribeWav(file)).resolves.toBe('你好');
      expect(calls[0]?.url).toBe('http://asr.test/v1/chat/completions');
      const body = calls[0]?.body as {
        messages: { content: { type: string; input_audio: { data: string } }[] }[];
        asr_options: { language: string };
      };
      expect(body.messages[0]?.content[0]?.type).toBe('input_audio');
      expect(body.messages[0]?.content[0]?.input_audio.data.startsWith('data:audio/wav;base64,')).toBe(
        true,
      );
      expect(body.asr_options.language).toBe('auto');
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it('rejects a missing file', async () => {
    configure();
    await expect(transcribeWav('/nonexistent/voice.wav')).rejects.toThrow();
  });
});
