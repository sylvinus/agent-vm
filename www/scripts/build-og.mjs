/**
 * Renders public/og.png from an inline SVG.
 *
 * Run with `npm run og` after changing the wording. The PNG is committed, so a
 * normal `npm run build` (and the CI deploy) never needs sharp or a font stack
 * on the machine doing the build.
 */

import { mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const here = dirname(fileURLToPath(import.meta.url));
const out = resolve(here, '../public/og.png');

const W = 1200;
const H = 630;
const GRID = 60;

const gridLines = [];
for (let x = GRID; x < W; x += GRID) {
  gridLines.push(`<line x1="${x}" y1="0" x2="${x}" y2="${H}" />`);
}
for (let y = GRID; y < H; y += GRID) {
  gridLines.push(`<line x1="0" y1="${y}" x2="${W}" y2="${y}" />`);
}

// The SVG renderer behind sharp does not map the generic `sans-serif` keyword
// to a real family, so both stacks name actual faces and end on the keyword.
// macOS hits Helvetica, a Linux CI box hits Liberation.
const SANS = 'Inter, Helvetica Neue, Helvetica, Liberation Sans, Arial, sans-serif';
const MONO = 'JetBrains Mono, SF Mono, Menlo, DejaVu Sans Mono, Liberation Mono, monospace';

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <linearGradient id="fade" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.05" />
      <stop offset="1" stop-color="#ffffff" stop-opacity="0" />
    </linearGradient>
  </defs>

  <rect width="${W}" height="${H}" fill="#131210" />
  <g stroke="#ffffff" stroke-opacity="0.035" stroke-width="1">
    ${gridLines.join('\n    ')}
  </g>
  <rect width="${W}" height="${H}" fill="url(#fade)" />

  <g transform="translate(96 96)">
    <rect x="0" y="0" width="56" height="56" rx="13" fill="none" stroke="#8a8275" stroke-width="3" />
    <rect x="17" y="17" width="22" height="22" rx="5" fill="#e08c3e" />
    <text x="78" y="39" font-family="${MONO}" font-size="34" font-weight="700" fill="#f1ece2">
      agent-vm
    </text>
  </g>

  <text x="96" y="310" font-family="${SANS}" font-size="66" font-weight="700" fill="#f1ece2">
    Give agents a machine
  </text>
  <text x="96" y="388" font-family="${SANS}" font-size="66" font-weight="700" fill="#f1ece2">
    they can wreck.
    <tspan fill="#e08c3e"> Keep yours.</tspan>
  </text>

  <text x="96" y="462" font-family="${SANS}" font-size="29" fill="#b8afa1">
    Sandboxed Linux VMs for AI coding agents. One per project.
  </text>

  <line x1="96" y1="524" x2="${W - 96}" y2="524" stroke="#2c2823" stroke-width="2" />

  <text x="96" y="568" font-family="${MONO}" font-size="24" fill="#8a8275">
    www.agent-vm.org
  </text>
  <text x="${W - 96}" y="568" text-anchor="end" font-family="${MONO}" font-size="24" fill="#8a8275">
    MIT  ·  macOS + Linux  ·  built on Lima
  </text>
</svg>`;

await mkdir(dirname(out), { recursive: true });
await sharp(Buffer.from(svg)).png({ compressionLevel: 9 }).toFile(out);

console.log(`wrote ${out}`);
