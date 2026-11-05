// Zieht die Demo-Fixtures der App aus einer laufenden Yuvomi-Seed-Instanz.
//
// Der Weg ist der der App: Anmeldung mit Passwort, dann ein Geraete-Credential
// (POST /auth/devices), und mit diesem Bearer jede Lese-Operation des
// Client-Vertrags. Geheimnisse (Credential, CSRF-Token) werden ersetzt, bevor
// eine Datei geschrieben wird.
//
// Aufruf:
//   node Fixtures/dump-fixtures.mjs <base-url> <benutzer> <passwort> [zielordner] [nur]
// `nur` ist eine Liste von Dateinamen mit Komma, etwa `task-checklist`: Dann schreibt das
// Skript nur diese Dateien und laesst die uebrigen Abzuege mit ihren Daten stehen.
// Beispiel gegen die lokale Seed-Instanz aus scripts/seed-demo.js:
//   node Fixtures/dump-fixtures.mjs http://127.0.0.1:3917 alex demo1234 Fixtures/demo
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [base, username, password, outDir = 'Fixtures/demo', only] = process.argv.slice(2);
const wanted = only ? new Set(only.split(',')) : null;
if (!base || !username || !password) {
  console.error('Aufruf: node Fixtures/dump-fixtures.mjs <base-url> <benutzer> <passwort> [zielordner] [nur]');
  process.exit(2);
}
const API = `${base.replace(/\/$/, '')}/api/v1`;
const JSON_HEADERS = { 'Content-Type': 'application/json' };
const CREDENTIAL_PLACEHOLDER = 'ydc_FIXTURE_CREDENTIAL';

mkdirSync(outDir, { recursive: true });
const written = [];

function save(name, data) {
  if (wanted && !wanted.has(name)) return;
  writeFileSync(join(outDir, `${name}.json`), `${JSON.stringify(data, null, 2)}\n`);
  written.push(name);
}

async function request(method, path, { headers = {}, body } = {}) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { ...(body !== undefined ? JSON_HEADERS : {}), ...headers },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${text.slice(0, 200)}`);
  return { res, data: text ? JSON.parse(text) : null };
}

// Instanz, ohne Anmeldung
save('version', (await request('GET', '/version')).data);
save('auth-oidc-config', (await request('GET', '/auth/oidc/config')).data);

// Anmeldung mit Sitzung, nur um das Geraet anzulegen
const login = await request('POST', '/auth/login', { body: { username, password } });
save('auth-login', { ...login.data, ...('csrfToken' in login.data ? { csrfToken: 'FIXTURE_CSRF_TOKEN' } : {}) });
const cookie = (login.res.headers.getSetCookie?.() ?? [login.res.headers.get('set-cookie')])
  .filter(Boolean).map((c) => c.split(';')[0]).join('; ');
const me = (await request('GET', '/auth/me', { headers: { Cookie: cookie } })).data;
const session = { Cookie: cookie, 'X-CSRF-Token': me.csrfToken };

const created = (await request('POST', '/auth/devices', {
  headers: session,
  body: { name: 'iPhone', platform: 'ios', device_id: 'fixture-device-0001' },
})).data;
const bearer = { Authorization: `Bearer ${created.credential}` };
save('auth-devices-create', { ...created, credential: CREDENTIAL_PLACEHOLDER });

// Ab hier wie die App: nur mit dem Geraete-Credential
const now = new Date();
const day = (d) => d.toISOString().slice(0, 10);
const get = async (path) => (await request('GET', path, { headers: bearer })).data;
const serverVersion = (await get('/version')).version ?? null;
save('auth-me', await get('/auth/me'));
save('auth-devices', await get('/auth/devices'));
save('dashboard', await get('/dashboard'));

const tasks = await get('/tasks');
save('tasks', tasks);
save('tasks-meta-options', await get('/tasks/meta/options'));
if (tasks.data?.length) save('task', await get(`/tasks/${tasks.data[0].id}`));

// Der Seed hat keine Aufgabe mit Checkliste und Unteraufgaben. Die App braucht eine fuer das
// Detail (Slice 5): einmal mit der Sitzung anlegen, dann wie die App mit dem Credential lesen.
// Die Beschreibung mischt Text, Markdown und Checkliste in allen Formen, die die Regel des
// Servers kennt (Einzug, `*`, `X`), dazu eine Zeile, die wie eine Checkliste aussieht, aber
// keine ist.
const CHECKLIST_TITLE = 'Pack for the weekend trip';
let checklist = tasks.data?.find((task) => task.title === CHECKLIST_TITLE);
if (!checklist && (!wanted || wanted.has('task-checklist'))) {
  const description = [
    'Leave by **Friday 5 pm**.',
    '',
    '- [x] Book the cabin',
    '- [ ] Pack sleeping bags',
    '  * [X] Charge the power bank',
    '- [ ] Buy snacks',
    '-[ ] not a checklist line',
  ].join('\n');
  checklist = (await request('POST', '/tasks', {
    headers: session,
    body: { title: CHECKLIST_TITLE, description, priority: 'medium', points: 5 },
  })).data.data;
  const sub = async (title) => (await request('POST', '/tasks', {
    headers: session,
    body: { title, parent_task_id: checklist.id },
  })).data.data;
  await sub('Check the car tyres');
  const done = await sub('Print the route');
  await request('PATCH', `/tasks/${done.id}/status`, { headers: session, body: { status: 'done' } });
}
if (checklist) save('task-checklist', await get(`/tasks/${checklist.id}`));

// Anlegen und Aendern wie die App (Slice 6a): mit dem Credential, nur die Felder des
// Formulars. Danach wieder loeschen, damit die Instanz keinen Rest behaelt.
if (!wanted || wanted.has('task-created') || wanted.has('task-updated')) {
  const writeHeaders = { ...bearer, 'Idempotency-Key': 'fixture-create-0001' };
  const createdTask = (await request('POST', '/tasks', {
    headers: writeHeaders,
    body: {
      title: 'Water the plants',
      description: 'The big ones on the balcony.',
      category: 'household',
      priority: 'low',
      due_date: day(new Date()),
      due_time: '18:30',
      assigned_to: [me.user.id],
    },
  })).data;
  save('task-created', createdTask);
  const id = createdTask.data.id;
  save('task-updated', (await request('PUT', `/tasks/${id}`, {
    headers: bearer,
    body: { title: 'Water all the plants', due_time: null },
  })).data);
  await request('DELETE', `/tasks/${id}`, { headers: bearer });
}

const lists = await get('/shopping');
save('shopping-lists', lists);
save('shopping-versions', await get('/shopping/versions'));
save('shopping-suggestions', await get('/shopping/suggestions'));
save('shopping-categories', await get('/shopping/categories'));
if (lists.data?.length) save('shopping-items', await get(`/shopping/${lists.data[0].id}/items`));

// Fenster wie die App: from und to selbst, 14 Tage als 14 x 86400 Sekunden
const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
const monthEnd = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 0));
const events = await get(`/calendar?from=${day(monthStart)}&to=${day(monthEnd)}`);
save('calendar', events);
save('calendar-upcoming', await get('/calendar/upcoming'));
save('calendar-calendars', await get('/calendar/calendars'));
const single = events.data?.find((event) => !event.recurrence_rule) ?? events.data?.[0];
if (single) save('calendar-event', await get(`/calendar/${single.id}`));

const from = new Date(Math.floor(now.getTime() / 1000) * 1000);
const to = new Date(from.getTime() + 14 * 86400 * 1000);
const iso = (d) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');
save('reminders-upcoming', await get(
  `/reminders/upcoming?from=${encodeURIComponent(iso(from))}&to=${encodeURIComponent(iso(to))}&types=task,event`,
));
save('reminders-pending', await get('/reminders/pending'));

// Das Fixture-Geraet wieder abmelden, damit die Instanz keinen Rest behaelt
await request('DELETE', '/auth/devices/current', { headers: bearer });

save('_meta', {
  source: base,
  user: username,
  captured_at: iso(now),
  server_version: serverVersion,
  files: written.slice(),
});
console.log(`${written.length} Dateien in ${outDir}`);
