// node --test .gitea/renovate/update-checksums.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { update } from './update-checksums.mjs';

const OLD = 'a'.repeat(64);
const NEW = 'b'.repeat(64);
const sums = `${'c'.repeat(64)}  x_1.2.3_linux_arm64.tar.gz\n${NEW}  x_1.2.3_linux_amd64.tar.gz\n`;

test('re-pins from the listed checksums file', async () => {
  const src = [
    '# renovate: datasource=github-releases depName=o/x',
    'x_version: "1.2.3"',
    '# checksum-from: https://h/v{version}/sums.txt x_{version}_linux_amd64.tar.gz',
    `x_checksum: "sha256:${OLD}"`,
    'other: 1',
  ].join('\n');
  let asked;
  const out = await update(src, async (u) => ((asked = u), sums));
  assert.equal(asked, 'https://h/v1.2.3/sums.txt');
  assert.equal(out, src.replace(OLD, NEW));
});

test('fails closed when the file is not listed', async () => {
  const src = '# renovate: d\nv: 9.9.9\n# checksum-from: https://h/s x_{version}.tgz\nc: ' + OLD;
  await assert.rejects(update(src, async () => sums), /no sha256/);
});

test('leaves files without markers alone', async () => {
  const src = '# renovate: d\nv: 1\nc: ' + OLD;
  assert.equal(await update(src, async () => assert.fail('no fetch')), src);
});
