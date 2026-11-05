// Prueft jede Datei aus Fixtures/demo gegen das Antwort-Schema der Spec, mit dem
// Pruefer aus test:openapi-client-responses. Aufruf:
//   node Fixtures/check-fixtures.mjs <server-worktree> Fixtures/demo
const [root, dir] = process.argv.slice(2);
const { readFileSync } = await import('node:fs');
const { buildOpenApiSpec } = await import(`${root}/server/openapi.js`);
const { schemaProblems } = await import(`${root}/test/openapi-schema-check.js`);
const spec = buildOpenApiSpec({ protocol: 'http', get: () => 'localhost' }, '0.0.0');
const map = {
  version: ['get', '/api/v1/version'], 'auth-oidc-config': ['get', '/api/v1/auth/oidc/config'],
  'auth-login': ['post', '/api/v1/auth/login', 200], 'auth-devices-create': ['post', '/api/v1/auth/devices', 201],
  'auth-me': ['get', '/api/v1/auth/me'], 'auth-devices': ['get', '/api/v1/auth/devices'], dashboard: ['get', '/api/v1/dashboard'],
  tasks: ['get', '/api/v1/tasks'], 'tasks-meta-options': ['get', '/api/v1/tasks/meta/options'], task: ['get', '/api/v1/tasks/{id}'], 'task-checklist': ['get', '/api/v1/tasks/{id}'],
  'task-created': ['post', '/api/v1/tasks', 201], 'task-updated': ['put', '/api/v1/tasks/{id}'],
  'shopping-lists': ['get', '/api/v1/shopping'], 'shopping-versions': ['get', '/api/v1/shopping/versions'],
  'shopping-suggestions': ['get', '/api/v1/shopping/suggestions'], 'shopping-categories': ['get', '/api/v1/shopping/categories'],
  'shopping-items': ['get', '/api/v1/shopping/{listId}/items'], calendar: ['get', '/api/v1/calendar'],
  'calendar-upcoming': ['get', '/api/v1/calendar/upcoming'], 'calendar-calendars': ['get', '/api/v1/calendar/calendars'],
  'calendar-event': ['get', '/api/v1/calendar/{id}'], 'reminders-upcoming': ['get', '/api/v1/reminders/upcoming'],
  'reminders-pending': ['get', '/api/v1/reminders/pending'],
};
let bad = 0;
for (const [file, [method, path, status = 200]] of Object.entries(map)) {
  let response = spec.paths[path][method].responses[status] ?? spec.paths[path][method].responses[201];
  if (response.$ref) response = response.$ref.replace(/^#\//, '').split('/').reduce((n, k) => n[k], spec);
  const data = JSON.parse(readFileSync(`${dir}/${file}.json`, 'utf8'));
  const problems = schemaProblems(spec, response.content['application/json'].schema, data, '$', {});
  if (problems.length) { bad++; console.log(file, problems.slice(0, 5)); }
}
console.log(bad ? `${bad} Dateien mit Abweichungen` : `alle ${Object.keys(map).length} Dateien passen zur Spec`);
