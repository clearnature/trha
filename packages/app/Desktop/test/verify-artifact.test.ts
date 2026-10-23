import { describe, it, expect } from 'vitest';
import { archFromNode, parseDebInfo, verifyDebFields } from '../scripts/verify-artifact.mjs';

describe('parseDebInfo', () => {
  it('extracts Package, Version and Architecture', () => {
    const out = 'Package: trha\nVersion: 1.2.3\nArchitecture: amd64\n';
    expect(parseDebInfo(out)).toEqual({ pkg: 'trha', version: '1.2.3', arch: 'amd64' });
  });

  it('returns undefined for missing fields instead of throwing', () => {
    expect(parseDebInfo('Package: trha\n')).toEqual({
      pkg: 'trha',
      version: undefined,
      arch: undefined,
    });
  });

  it('ignores unrelated fields and trims surrounding spaces', () => {
    const out = [
      'Section: misc',
      'Package:  trha  ',
      'Version: 1.0',
      'Architecture: arm64',
      'Depends: nodejs',
    ].join('\n');
    expect(parseDebInfo(out)).toEqual({ pkg: 'trha', version: '1.0', arch: 'arm64' });
  });

  it('handles empty output', () => {
    expect(parseDebInfo('')).toEqual({ pkg: undefined, version: undefined, arch: undefined });
  });
});

describe('verifyDebFields', () => {
  it('accepts a matching artifact', () => {
    expect(verifyDebFields({ pkg: 'trha', version: '1.0.0', arch: 'amd64' }, 'amd64')).toEqual([]);
  });

  it('rejects a renamed package', () => {
    expect(verifyDebFields({ pkg: 'trha-desktop', version: '1.0.0', arch: 'amd64' }, 'amd64')).toEqual([
      "Package must be 'trha', got 'trha-desktop'",
    ]);
  });

  it('rejects an architecture mismatch', () => {
    expect(verifyDebFields({ pkg: 'trha', version: '1.0.0', arch: 'x64' }, 'amd64')).toEqual([
      "Architecture must be 'amd64', got 'x64'",
    ]);
  });

  it('rejects a missing version', () => {
    expect(verifyDebFields({ pkg: 'trha', version: undefined, arch: 'amd64' }, 'amd64')).toEqual([
      'Version missing',
    ]);
  });

  it('reports every violation at once', () => {
    const errors = verifyDebFields({ pkg: 'other', version: undefined, arch: 'arm64' }, 'amd64');
    expect(errors).toHaveLength(3);
  });
});

describe('archFromNode', () => {
  it('maps the running node arch to the release vocabulary', () => {
    const expected = process.arch === 'x64' ? 'amd64' : 'arm64';
    expect(archFromNode()).toBe(expected);
  });
});
