import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { resolve, relative, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const check = process.argv.includes('--check');
const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
  entry.isDirectory() ? walk(resolve(dir, entry.name)) : [resolve(dir, entry.name)]);
const pages = [resolve(root, 'README.md'), ...walk(resolve(root, 'docs'))];
let blocks = 0;
let stale = false;
for (const page of pages) {
  if (!page.endsWith('.md')) continue;
  const before = readFileSync(page, 'utf8');
  const after = before.replace(/<!-- (snippet|include): ([\w./-]+) -->[\s\S]*?<!-- end:\2 -->/g,
    (_, kind, name) => {
      const sourcePath = resolve(root, name);
      if (relative(root, sourcePath).startsWith('..')) throw new Error(`Source outside repository: ${name}`);
      const source = readFileSync(sourcePath, 'utf8').trimEnd();
      const body = kind === 'snippet'
        ? `\`\`\`${extname(name).slice(1)}\n${source}\n\`\`\``
        : source.replace(/^# .*\n+/, '');
      blocks++;
      return `<!-- ${kind}: ${name} -->\n${body}\n<!-- end:${name} -->`;
    });
  if ((before.match(/<!-- (?:snippet|include): /g) ?? []).length !==
      (after.match(/<!-- end:/g) ?? []).length) throw new Error(`Unpaired snippet markers: ${page}`);
  if (before === after) continue;
  if (check) {
    console.error(`Stale generated content: ${relative(root, page)}`);
    stale = true;
  } else writeFileSync(page, after);
}
if (!blocks) throw new Error('No canonical snippets found');
if (stale) process.exitCode = 1;
else console.log(`${blocks} canonical content blocks ${check ? 'verified' : 'synchronized'}.`);
