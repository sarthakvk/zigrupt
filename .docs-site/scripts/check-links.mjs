// Validate local links and assets in the built docs site, plus selected repository
// Markdown links. Run after building .docs-site/dist.
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { resolve, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseHTML } from 'linkedom';

const root = fileURLToPath(new URL('../../', import.meta.url));
const dist = resolve(root, '.docs-site/dist');
const origin = 'https://zigrupt.sarthakvk.com';
const base = (process.env.DOCS_BASE || '/').replace(/\/$/, '') + '/';
const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
  entry.isDirectory() ? walk(resolve(dir, entry.name)) : [resolve(dir, entry.name)]);
if (!existsSync(dist)) throw new Error('Build the documentation before checking links');
const files = walk(dist);
const documents = new Map();
const errors = new Set();
let checked = 0;

function document(path) {
  if (!documents.has(path)) documents.set(path, parseHTML(readFileSync(path, 'utf8')).document);
  return documents.get(path);
}
function urlFor(path) {
  let route = relative(dist, path).split('\\').join('/');
  if (route.endsWith('index.html')) route = route.slice(0, -10);
  return new URL(base + route, origin);
}
function verify(value, from, fromUrl = urlFor(from)) {
  const label = relative(root, from);
  let target;
  try { target = new URL(value, fromUrl); }
  catch { errors.add(`${label}: invalid URL ${value}`); return; }
  if (target.origin !== origin) return; // Includes data/mailto/external URLs.
  if (!target.pathname.startsWith(base)) {
    errors.add(`${label}: URL escapes ${base}: ${value}`);
    return;
  }
  const path = resolve(dist, decodeURIComponent(target.pathname.slice(base.length)));
  if (relative(dist, path).startsWith('..')) {
    errors.add(`${label}: URL escapes build directory: ${value}`);
    return;
  }
  const file = existsSync(path) && statSync(path).isDirectory() ? resolve(path, 'index.html') : path;
  checked++;
  if (!existsSync(file)) errors.add(`${label}: missing target ${value}`);
  else if (target.hash && file.endsWith('.html') &&
    !document(file).getElementById(decodeURIComponent(target.hash.slice(1)))) {
    errors.add(`${label}: missing fragment ${value}`);
  }
}
function cssUrls(css, path) {
  for (const match of css.matchAll(/url\(\s*['"]?([^'"\s)]+)['"]?\s*\)/g)) {
    if (!match[1].startsWith('#')) verify(match[1], path);
  }
}
for (const file of files) {
  if (file.endsWith('.css')) cssUrls(readFileSync(file, 'utf8'), file);
  if (!file.endsWith('.html')) continue;
  const doc = document(file);
  for (const node of doc.querySelectorAll('[href], [src], [srcset], [poster]')) {
    for (const attribute of ['href', 'src', 'poster']) {
      // Starlight emits a synthetic /404/ canonical for Pages' special 404.html.
      if (file.endsWith('/404.html') && node.getAttribute('rel') === 'canonical') continue;
      if (node.hasAttribute(attribute)) verify(node.getAttribute(attribute), file);
    }
    if (node.hasAttribute('srcset')) {
      for (const item of node.getAttribute('srcset').split(',')) verify(item.trim().split(/\s+/)[0], file);
    }
  }
  for (const style of doc.querySelectorAll('style, [style]')) {
    cssUrls(style.localName === 'style' ? style.textContent : style.getAttribute('style'), file);
  }
}

// Check repository-facing relative Markdown links without needing a hosted site.
for (const name of ['README.md', 'CONTRIBUTING.md', 'examples/README.md', 'benchmarks/README.md']) {
  const file = resolve(root, name);
  const prose = readFileSync(file, 'utf8').replace(/^```[^\n]*\n[\s\S]*?^```/gm, '');
  for (const match of prose.matchAll(/!?\[[^\]]*\]\(([^\s)]+)(?:\s+[^)]*)?\)/g)) {
    const href = match[1];
    if (/^(?:[a-z]+:|#|\/)/i.test(href)) continue;
    const path = decodeURIComponent(href.split('#')[0]);
    checked++;
    if (!existsSync(resolve(dirname(file), path))) errors.add(`${name}: missing repository target ${href}`);
  }
}

for (const asset of ['pagefind/pagefind.js', 'pagefind/pagefind-entry.json', 'sitemap-index.xml']) {
  if (!existsSync(resolve(dist, asset))) errors.add(`Missing generated asset: ${asset}`);
}
if (!files.some((file) => file.includes('/pagefind/') && file.endsWith('.pf_index'))) {
  errors.add('No Pagefind language index was generated');
}
if (errors.size) {
  for (const error of errors) console.error(error);
  process.exitCode = 1;
} else console.log(`Checked ${documents.size} HTML pages and ${checked} local references; search assets present.`);
