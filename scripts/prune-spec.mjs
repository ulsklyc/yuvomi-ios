// Baut die Spec eines Server-Tags und kürzt sie auf die Operationen des nativen Clients.
//
// Aufruf: node scripts/prune-spec.mjs <entpackter-server-tag>
// Schreibt JSON auf stdout. Gerufen von scripts/update-spec.sh.
//
// Die Liste der Operationen kommt aus demselben Tag (`test/openapi-client-operations.js`),
// also aus der Datei, die auch `test:openapi-client-contract` prüft. Behalten wird nur,
// was diese Operationen über `$ref` erreichen. So zeigt ein Diff von Spec/openapi.json
// nur Änderungen, die die App betreffen.
//
// Antworten tolerant, Anfragen strikt (docs/adr/0002, Glossar: "unbekannter Wert"):
// Der Swift OpenAPI Generator macht aus jedem `enum` ein geschlossenes Swift-Enum. Ein neuer
// Wert in einer Antwort, etwa ein neuer Aufgabenstatus, ließe sonst das Dekodieren der ganzen
// Antwort scheitern, in jeder installierten App. Deshalb entfernt `loosenResponses()` weiter
// unten jedes `enum` in Schemas, die nur in Antworten vorkommen; `type` bleibt stehen, aus
// `status` wird also ein `String`. Die Adapter in YuvomiAPI übersetzen ihn in ein Kern-Enum
// mit einem Fall für den unbekannten Wert. Was in Anfragen erreichbar ist (Parameter,
// Request-Bodies), behält seine Enums: Dort schickt die App, und der Server soll nur
// bekannte Werte bekommen. Die Regel steht nur hier, nicht verteilt über `typeOverrides`.

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

// Als JSON kopieren: buildOpenApiSpec() darf dasselbe JS-Objekt an mehreren Stellen
// verwenden, etwa ein Status-Schema in einem Parameter und in einer Antwort. Ohne Kopie
// träfe das Entfernen eines `enum` an der Antwortstelle auch die Anfrage.
const pruned = JSON.parse(JSON.stringify({
  openapi: full.openapi,
  info: full.info,
  servers: full.servers,
  tags: (full.tags ?? []).filter((t) => usedTags.has(t.name)),
  paths,
  components,
  ...(full.security ? { security: full.security } : {}),
}));

loosenResponses(pruned);
process.stdout.write(`${JSON.stringify(pruned, null, 2)}\n`);

// Entfernt `enum` überall, wo nur Antworten hinkommen (Begründung im Kopf der Datei).
// Gemeint sind alle Antworten einer Operation, nicht nur 2xx: Auch ein Fehler-Body mit
// neuem Code soll lesbar bleiben.
//
// Geteilte Schemas, die in einer Anfrage UND in einer Antwort vorkommen und ein `enum`
// erreichen, bekommen eine Antwortkopie `<Name>Response`; die Antwortseite zeigt per `$ref`
// auf die Kopie, die Anfrageseite behält das strikte Original. Eine Kopie statt die Stellen
// inline zu ersetzen: Der Generator benennt Inline-Schemas nach ihrer Fundstelle, ein
// geteiltes Schema ergäbe so viele gleiche Typen mit wechselnden Namen. Eine Kopie bleibt
// ein benannter Typ mit `$ref`, das erzeugt keine Warnung und einen stabilen Namen. Stand
// v2.84.0 teilt kein Schema beide Seiten; die Regel greift erst, wenn der Server das ändert.
function loosenResponses(spec) {
  const schemas = spec.components.schemas ?? {};
  const refName = (ref) => {
    const prefix = '#/components/schemas/';
    return typeof ref === 'string' && ref.startsWith(prefix) ? ref.slice(prefix.length) : null;
  };

  // Schemas, die von `node` aus über `$ref` erreichbar sind, auch über Schemas hinweg.
  // Auch `#/components/responses/...` wird verfolgt, denn das sind ebenfalls Antworten.
  function reachable(node, found = new Set()) {
    if (Array.isArray(node)) { node.forEach((n) => reachable(n, found)); return found; }
    if (!node || typeof node !== 'object') return found;
    const name = refName(node.$ref);
    if (name && !found.has(name)) { found.add(name); reachable(schemas[name], found); }
    const resp = typeof node.$ref === 'string' && node.$ref.startsWith('#/components/responses/')
      ? node.$ref.slice('#/components/responses/'.length) : null;
    if (resp) reachable(spec.components.responses?.[resp], found);
    for (const value of Object.values(node)) reachable(value, found);
    return found;
  }

  const requestSide = new Set();
  const responseSide = new Set();
  const operations = [];
  for (const item of Object.values(spec.paths)) {
    reachable(item.parameters ?? [], requestSide);
    for (const [method, op] of Object.entries(item)) {
      if (method === 'parameters') continue;
      operations.push(op);
      reachable(op.parameters ?? [], requestSide);
      reachable(op.requestBody ?? {}, requestSide);
      reachable(op.responses ?? {}, responseSide);
    }
  }

  // Erreicht ein Schema irgendwo ein `enum`, direkt oder über `$ref`?
  const hasEnum = (node) => {
    if (Array.isArray(node)) return node.some(hasEnum);
    if (!node || typeof node !== 'object') return false;
    return 'enum' in node || Object.values(node).some(hasEnum);
  };
  const reachesEnum = (name) => [name, ...reachable(schemas[name])].some((n) => hasEnum(schemas[n]));

  const copies = new Map(); // Original -> Antwortkopie
  for (const name of [...responseSide].sort()) {
    if (!requestSide.has(name) || !reachesEnum(name)) continue;
    const copy = `${name}Response`;
    if (schemas[copy]) throw new Error(`Antwortkopie ${copy} kollidiert mit einem Schema der Spec`);
    copies.set(name, copy);
  }
  for (const [name, copy] of copies) schemas[copy] = JSON.parse(JSON.stringify(schemas[name]));

  // Läuft nur über Schema-Schlüsselwörter. So bleibt eine Eigenschaft, die zufällig `enum`
  // heißt, stehen, und `example`-Werte bleiben unberührt.
  function loosen(schema) {
    if (!schema || typeof schema !== 'object' || Array.isArray(schema)) return;
    const name = refName(schema.$ref);
    if (name && copies.has(name)) schema.$ref = `#/components/schemas/${copies.get(name)}`;
    delete schema.enum;
    for (const key of ['properties', 'patternProperties']) {
      for (const sub of Object.values(schema[key] ?? {})) loosen(sub);
    }
    for (const key of ['items', 'additionalProperties', 'not', 'contains', 'propertyNames']) loosen(schema[key]);
    for (const key of ['allOf', 'anyOf', 'oneOf', 'prefixItems']) (schema[key] ?? []).forEach(loosen);
  }
  function loosenResponse(response) {
    for (const media of Object.values(response?.content ?? {})) loosen(media.schema);
    for (const header of Object.values(response?.headers ?? {})) loosen(header.schema);
  }

  for (const op of operations) Object.values(op.responses ?? {}).forEach(loosenResponse);
  Object.values(spec.components.responses ?? {}).forEach(loosenResponse);
  for (const name of Object.keys(schemas)) {
    const responseOnly = responseSide.has(name) && !requestSide.has(name);
    if (responseOnly || [...copies.values()].includes(name)) loosen(schemas[name]);
  }

  // Sortiert wie oben, damit Kopien im Diff an fester Stelle stehen.
  spec.components.schemas = Object.fromEntries(Object.entries(schemas).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
}
