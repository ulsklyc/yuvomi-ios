// Baut die Spec eines Server-Tags und kürzt sie auf die Operationen des nativen Clients.
//
// Aufruf: node scripts/prune-spec.mjs <entpackter-server-tag>
// Schreibt JSON auf stdout. Gerufen von scripts/update-spec.sh.
//
// Die Liste der Operationen kommt aus demselben Tag (`test/openapi-client-operations.js`),
// also aus der Datei, die auch `test:openapi-client-contract` prüft. Behalten wird nur,
// was diese Operationen über `$ref` erreichen. So zeigt ein Diff von Spec/openapi.json
// nur Änderungen, die die App betreffen.

import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const root = process.argv[2];
if (!root) {
  console.error('Aufruf: node scripts/prune-spec.mjs <entpackter-server-tag>');
  process.exit(1);
}

const load = (rel) => import(pathToFileURL(path.resolve(root, rel)).href);
const { buildOpenApiSpec } = await load('server/openapi.js');
const { CLIENT_OPERATIONS } = await load('test/openapi-client-operations.js');
const { version } = JSON.parse(await readFile(path.resolve(root, 'package.json'), 'utf8'));

const full = buildOpenApiSpec({ protocol: 'http', get: () => 'localhost' }, version);

const paths = {};
for (const [method, p] of CLIENT_OPERATIONS) {
  const op = full.paths[p]?.[method];
  if (!op) throw new Error(`Operation fehlt in der Spec: ${method.toUpperCase()} ${p}`);
  if (!op.operationId) throw new Error(`Operation ohne operationId: ${method.toUpperCase()} ${p}`);
  paths[p] ??= {};
  if (full.paths[p].parameters) paths[p].parameters = full.paths[p].parameters;
  paths[p][method] = op;
}

// Alle über `$ref` erreichbaren Komponenten einsammeln, auch über Komponenten hinweg.
const keep = new Map(); // "schemas/Foo" -> true
function walk(node) {
  if (Array.isArray(node)) return node.forEach(walk);
  if (!node || typeof node !== 'object') return;
  const ref = node.$ref;
  if (typeof ref === 'string' && ref.startsWith('#/components/')) {
    const key = ref.slice('#/components/'.length);
    if (!keep.has(key)) {
      keep.set(key, true);
      const [kind, name] = key.split('/');
      const target = full.components?.[kind]?.[name];
      if (!target) throw new Error(`Unbekannte Referenz: ${ref}`);
      walk(target);
    }
  }
  for (const value of Object.values(node)) walk(value);
}
walk(paths);

const components = {};
for (const key of [...keep.keys()].sort()) {
  const [kind, name] = key.split('/');
  components[kind] ??= {};
  components[kind][name] = full.components[kind][name];
}
components.securitySchemes = full.components.securitySchemes;

const usedTags = new Set(Object.values(paths).flatMap((item) =>
  Object.values(item).flatMap((op) => op?.tags ?? [])));

const pruned = {
  openapi: full.openapi,
  info: full.info,
  servers: full.servers,
  tags: (full.tags ?? []).filter((t) => usedTags.has(t.name)),
  paths,
  components,
  ...(full.security ? { security: full.security } : {}),
};

process.stdout.write(`${JSON.stringify(pruned, null, 2)}\n`);
