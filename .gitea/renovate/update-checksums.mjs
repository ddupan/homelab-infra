// Renovate postUpgradeTask (renovate.json): re-pin sha256 values after a version bump.
//
// Renovate's regex manager can bump `x_version` but knows nothing about the checksum beside it,
// so every such PR used to fail closed in the play (#799). Mark the checksum line instead:
//
//   # renovate: datasource=github-releases depName=go-acme/lego
//   lego_version: "5.6.0"
//   # checksum-from: https://…/v{version}/lego_{version}_checksums.txt lego_v{version}_linux_amd64.tar.gz
//   lego_checksum: "sha256:…"
//
// {version} is the value of the nearest `x: "…"` line under a `# renovate:` comment above the
// marker. The next line's 64-hex value is replaced with the hash listed for that file name, so
// the new pin still shows up in the PR diff for review. Only node built-ins: this runs inside the
// Renovate container. Usage: node update-checksums.mjs <file>...
import { readFileSync, writeFileSync } from 'node:fs';

const MARKER = /^\s*# checksum-from: (\S+) (\S+)\s*$/;
const VERSION = /^\s*[\w.-]+:\s*"?([^"\s#]+)"?/;

export async function update(text, fetchText) {
  const lines = text.split('\n');
  let version = null;
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*# renovate:/.test(lines[i])) version = lines[i + 1]?.match(VERSION)?.[1] ?? null;
    const m = lines[i].match(MARKER);
    if (!m) continue;
    if (!version) throw new Error(`line ${i + 1}: checksum-from without a # renovate: version above`);
    const [url, name] = [m[1], m[2]].map((s) => s.replaceAll('{version}', version));
    const hash = (await fetchText(url))
      .split('\n')
      .map((l) => l.trim().split(/\s+\*?/))
      .find(([, f]) => f === name)?.[0];
    if (!/^[0-9a-f]{64}$/.test(hash ?? '')) throw new Error(`${url}: no sha256 for ${name}`);
    if (!/[0-9a-f]{64}/.test(lines[i + 1])) throw new Error(`line ${i + 2}: no sha256 to replace`);
    lines[i + 1] = lines[i + 1].replace(/[0-9a-f]{64}/, hash);
  }
  return lines.join('\n');
}

// The WAN drops at random (CLAUDE.md); a failed task leaves the PR with the stale pin, which
// still fails closed, so retrying a few times is all this needs.
async function fetchText(url) {
  for (let attempt = 1; ; attempt++) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(30_000) });
      if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
      return await res.text();
    } catch (e) {
      if (attempt === 5) throw e;
      await new Promise((r) => setTimeout(r, attempt * 5_000));
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  for (const file of process.argv.slice(2)) {
    const before = readFileSync(file, 'utf8');
    const after = await update(before, fetchText);
    if (after !== before) writeFileSync(file, after);
  }
}
