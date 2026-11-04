// Prüft, dass jede fremde Action in .github/workflows/ auf einen Commit-SHA gepinnt ist,
// mit der Version als Kommentar:
//
//   uses: actions/checkout@<40-stelliger-sha> # v7.0.1
//
// Ein Tag wie `@v4` ist beweglich: wer ihn verschieben kann, führt Code in unseren Jobs
// aus, auch im Spec-Update mit Schreibrecht auf Branches und PRs. Der SHA ist unbeweglich,
// der Kommentar hält ihn lesbar, und Dependabot (github-actions) hebt beide zusammen.
// Geprüft wird JEDE `uses:`-Zeile in JEDER Workflow-Datei, keine Allowlist. Lokale
// Actions (`./...`) tragen keinen Ref und sind ausgenommen. Vorbild ist
// test/test-workflow-pins.js im Server-Repo.
//
// Aufruf: node scripts/check-workflow-pins.mjs   (gerufen von .github/workflows/ci.yml)

import { readFileSync, readdirSync } from 'node:fs';

const DIR = new URL('../.github/workflows/', import.meta.url);
const PINNED = /^\s*(?:- )?uses:\s*([\w.-]+\/[\w.-]+(?:\/[\w./-]+)?)@([0-9a-f]{40})\s+#\s*v?\d+\.\d+\.\d+\S*\s*$/;
const USES = /^\s*(?:- )?uses:/;

const files = readdirSync(DIR).filter((f) => /\.ya?ml$/.test(f)).sort();
const offenders = [];
let total = 0;

for (const file of files) {
  readFileSync(new URL(file, DIR), 'utf8').split('\n').forEach((line, i) => {
    if (!USES.test(line) || line.includes('uses: ./')) return;
    total += 1;
    if (!PINNED.test(line)) offenders.push(`.github/workflows/${file}:${i + 1}: ${line.trim()}`);
  });
}

if (files.length === 0 || total === 0) {
  console.error('Keine Workflows oder keine uses:-Zeile gefunden - die Prüfung liefe ins Leere.');
  process.exit(1);
}
if (offenders.length > 0) {
  console.error('Nicht gepinnt. Erwartet: uses: <owner>/<repo>@<40-stelliger-sha> # vX.Y.Z');
  for (const o of offenders) console.error(`  ${o}`);
  process.exit(1);
}
console.log(`Action-Pins: ${total} uses:-Zeilen in ${files.length} Workflows, alle auf SHA gepinnt.`);
