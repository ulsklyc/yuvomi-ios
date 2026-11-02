// Zieht die Demo-Fixtures der App aus einer laufenden Yuvomi-Seed-Instanz.
//
// Der Weg ist der der App: Anmeldung mit Passwort, dann ein Geraete-Credential
// (POST /auth/devices), und mit diesem Bearer jede Lese-Operation des
// Client-Vertrags. Geheimnisse (Credential, CSRF-Token) werden ersetzt, bevor
// eine Datei geschrieben wird.
//
// Aufruf:
//   node Fixtures/dump-fixtures.mjs <base-url> <benutzer> <passwort> [zielordner]
// Beispiel gegen die lokale Seed-Instanz aus scripts/seed-demo.js:
//   node Fixtures/dump-fixtures.mjs http://127.0.0.1:3917 alex demo1234 Fixtures/demo
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [base, username, password, outDir = 'Fixtures/demo'] = process.argv.slice(2);
if (!base || !username || !password) {
  console.error('Aufruf: node Fixtures/dump-fixtures.mjs <base-url> <benutzer> <passwort> [zielordner]');
  process.exit(2);
}
const API = `${base.replace(/\/$/, '')}/api/v1`;
const JSON_HEADERS = { 'Content-Type': 'application/json' };
const CREDENTIAL_PLACEHOLDER = 'ydc_FIXTURE_CREDENTIAL';

mkdirSync(outDir, { recursive: true });
const written = [];

function save(name, data) {
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
const get = async (path) => (await request('GET', path, { headers: bearer })).data;
const serverVersion = (await get('/version')).version ?? null;
save('auth-me', await get('/auth/me'));
save('auth-devices', await get('/auth/devices'));
save('dashboard', await get('/dashboard'));

const tasks = await get('/tasks');
save('tasks', tasks);
save('tasks-meta-options', await get('/tasks/meta/options'));
if (tasks.data?.length) save('task', await get(`/tasks/${tasks.data[0].id}`));

const lists = await get('/shopping');
save('shopping-lists', lists);
save('shopping-versions', await get('/shopping/versions'));
save('shopping-suggestions', await get('/shopping/suggestions'));
save('shopping-categories', await get('/shopping/categories'));
if (lists.data?.length) save('shopping-items', await get(`/shopping/${lists.data[0].id}/items`));

// Fenster wie die App: from und to selbst, 14 Tage als 14 x 86400 Sekunden
const now = new Date();
const day = (d) => d.toISOString().slice(0, 10);
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
