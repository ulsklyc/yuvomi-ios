// Baut das 1024-px-App-Icon aus den SVG-Bausteinen von scripts/generate-icons.js.
import { readFileSync } from 'node:fs';
const [root, out] = process.argv.slice(2);
const { default: sharp } = await import(`${root}/node_modules/sharp/dist/index.mjs`);
const src = readFileSync(`${root}/scripts/generate-icons.js`, 'utf8');
const block = (name) => src.match(new RegExp(`const ${name} = \`([\\s\\S]*?)\`;`))[1];
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 160 160" fill="none">
  ${block('DEFS')}
  <rect width="160" height="160" fill="url(#bg)"/>
  <rect width="160" height="160" fill="url(#sheen)"/>
  ${block('CIRCLES')}
</svg>`;
await sharp(Buffer.from(svg)).flatten({ background: '#6c3aed' }).removeAlpha().png().toFile(out);
const meta = await sharp(out).metadata();
console.log(JSON.stringify({ width: meta.width, height: meta.height, channels: meta.channels, hasAlpha: meta.hasAlpha }));
