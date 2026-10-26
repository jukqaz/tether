import { cpSync, copyFileSync, existsSync, mkdirSync, readdirSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const prototype = path.join(root, 'prototype');
const built = path.join(prototype, 'dist/client');
if (!existsSync(path.join(built, 'index.html'))) throw new Error('Build the retained prototype first.');
const studio = path.join(root, 'dist/studio');
mkdirSync(studio, { recursive: true });
// Drop only obsolete generated bundles; retain legacy Site assets.
const oldAssets = path.join(studio, 'assets');
if (existsSync(oldAssets)) for (const name of readdirSync(oldAssets)) {
  if (/^index-[A-Za-z0-9_-]+\.(js|css)$/.test(name) && !existsSync(path.join(built, 'assets', name))) unlinkSync(path.join(oldAssets, name));
}
cpSync(built, studio, { recursive: true });
for (const name of ['localization-board.html', 'design-comparison.html']) {
  copyFileSync(path.join(prototype, name), path.join(studio, name));
}
const screenshots = path.join(studio, 'screens-i18n');
mkdirSync(screenshots, { recursive: true });
for (const name of readdirSync(path.join(prototype, 'screens-i18n'))) {
  if (name.endsWith('.jpg')) copyFileSync(path.join(prototype, 'screens-i18n', name), path.join(screenshots, name));
}
console.log('Assembled /studio/ with the prototype, comparison pages and JPEG captures.');
