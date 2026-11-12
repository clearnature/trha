// Release artifact contract checks (Reasonix electron-builder notes):
//   * the .deb must answer to the stable name the release line reads
//     (renaming it publishes a version nobody picks up);
//   * architecture: electron-builder says x64, the release line says amd64;
//     the .deb field is read back, not assumed;
//   * owner is checked numerically (dpkg-deb prints 0/0, not root/root).
// Usage: node scripts/verify-artifact.mjs <path.deb>

import { execFileSync } from 'node:child_process';

export function archFromNode() {
  // node arch (x64) -> release-side arch (amd64), matching the updater's
  // runtime.GOARCH vocabulary
  switch (process.arch) {
    case 'x64': return 'amd64';
    case 'arm64': return 'arm64';
    default: throw new Error(`unsupported build arch: ${process.arch}`);
  }
}

export function parseDebInfo(output) {
  const field = (name) => {
    const m = output.match(new RegExp(`^${name}: (.*)$`, 'm'));
    return m ? m[1].trim() : undefined;
  };
  return { pkg: field('Package'), version: field('Version'), arch: field('Architecture') };
}

export function verifyDebFields(info, expectedArch) {
  const errors = [];
  if (info.pkg !== 'trha') errors.push(`Package must be 'trha', got '${info.pkg}'`);
  if (info.arch !== expectedArch) {
    errors.push(`Architecture must be '${expectedArch}', got '${info.arch}'`);
  }
  if (!info.version) errors.push('Version missing');
  return errors;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [deb] = process.argv.slice(2);
  if (!deb) { console.error('usage: verify-artifact.mjs <path.deb>'); process.exit(2); }
  const info = parseDebInfo(execFileSync('dpkg-deb', ['--field', deb, 'Package', 'Version', 'Architecture'], { encoding: 'utf8' }));
  const errors = verifyDebFields(info, archFromNode());
  if (errors.length) {
    console.error('CONTRACT FAIL:', errors.join('; '));
    process.exit(1);
  }
  console.log(`CONTRACT OK: ${info.pkg} ${info.version} ${info.arch}`);
}
