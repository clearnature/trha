// Voice transcription, ported from MiMo-Code's ASR contract: a chat
// completion whose user content is an `input_audio` data URL, plus
// `asr_options`.  Never `/audio/transcriptions`, never multipart.
//
// The endpoint/model/key come from `TRHA_ASR_*` so transcription need not be
// the same provider as the chat model; an unconfigured host answers 503
// instead of pretending the recording was transcribed.

import { readFile } from 'node:fs/promises';

export class AsrNotConfigured extends Error {
  constructor() {
    super('ASR not configured (TRHA_ASR_BASE_URL / TRHA_ASR_MODEL)');
    this.name = 'AsrNotConfigured';
  }
}

const env = (key: string): string => (process.env[key] ?? '').trim();

/** Whether a transcription endpoint is configured. */
export const asrConfigured = (): boolean =>
  !!env('TRHA_ASR_BASE_URL') && !!env('TRHA_ASR_MODEL');

/** Transcript text for a WAV file recorded on this host. */
export async function transcribeWav(file: string): Promise<string> {
  if (!asrConfigured()) throw new AsrNotConfigured();
  const bytes = await readFile(file);
  // A bare WAV header is 44 bytes: anything that small is an empty recording.
  if (bytes.length <= 44) throw new Error('empty recording');

  const base = env('TRHA_ASR_BASE_URL').replace(/\/+$/, '');
  const key = env('TRHA_ASR_KEY');
  const body = {
    model: env('TRHA_ASR_MODEL'),
    messages: [
      {
        role: 'user',
        content: [
          {
            type: 'input_audio',
            input_audio: { data: `data:audio/wav;base64,${bytes.toString('base64')}` },
          },
        ],
      },
    ],
    asr_options: { language: env('TRHA_ASR_LANGUAGE') || 'auto' },
  };

  const res = await fetch(`${base}/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(key ? { Authorization: `Bearer ${key}` } : {}),
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) {
    throw new Error(`ASR ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }

  const json = (await res.json()) as {
    choices?: { message?: { content?: unknown } }[];
  };
  const content = json.choices?.[0]?.message?.content;
  const text =
    typeof content === 'string'
      ? content
      : Array.isArray(content)
        ? content.map(p => (p as { text?: string }).text ?? '').join('')
        : '';
  if (!text.trim()) throw new Error('ASR returned empty text');
  return text.trim();
}
