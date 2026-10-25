import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const studio = path.join(root, 'dist/studio');

test('the new entry loads its own /studio/ bundle and wallpaper', () => {
  const html = readFileSync(path.join(studio, 'index.html'), 'utf8');
  const resources = [...html.matchAll(/(?:src|href)="(\/studio\/assets\/[^"]+)"/g)].map(m => m[1]);
  assert.ok(resources.some(p => p.endsWith('.js')));
  assert.ok(resources.some(p => p.endsWith('.css')));
  for (const resource of resources) assert.ok(existsSync(path.join(root, 'dist', resource.slice(1))), resource);
  const cssFile = resources.find(p => p.endsWith('.css'));
  assert.match(readFileSync(path.join(root, 'dist', cssFile.slice(1)), 'utf8'), /\/studio\/assets\/wallpaper\.png/);
  assert.ok(existsSync(path.join(studio, 'assets/wallpaper.png')));
});

test('comparison pages remain inside /studio/ and include every selectable capture', () => {
  const board = readFileSync(path.join(studio, 'localization-board.html'), 'utf8');
  const compare = readFileSync(path.join(studio, 'design-comparison.html'), 'utf8');
  assert.ok(board.includes("'./screens-i18n/'"));
  assert.ok(board.includes('href="./"'));
  assert.ok(compare.includes('href="./localization-board.html"'));
  assert.ok(!board.includes('href="/screens-i18n/'));
  for (const locale of ['ko', 'en']) for (const theme of ['light', 'dark']) {
    for (const page of ['keep', 'power', 'general', 'keep-end', 'general-end']) {
      const name = `${locale}-${theme}-${page}.jpg`;
      const bytes = readFileSync(path.join(studio, 'screens-i18n', name));
      assert.equal(bytes.readUInt16BE(0), 0xffd8, name);
    }
  }
});

test('legacy root and comparison assets are preserved byte for byte', () => {
  const legacy = JSON.parse(readFileSync(path.join(root, 'tests/legacy-static.sha256.json'), 'utf8'));
  for (const [relative, digest] of Object.entries(legacy)) {
    assert.equal(createHash('sha256').update(readFileSync(path.join(root, relative))).digest('hex'), digest, relative);
  }
});

test('static publication contains no development dependencies or diagnostic records', () => {
  assert.ok(!existsSync(path.join(studio, 'node_modules')));
  assert.ok(!existsSync(path.join(studio, 'src')));
  assert.ok(readdirSync(path.join(studio, 'screens-i18n')).every(name => name.endsWith('.jpg')));
  assert.ok(!existsSync(path.join(studio, 'verification-i18n.json')));
});
