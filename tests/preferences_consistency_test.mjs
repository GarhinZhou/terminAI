import assert from 'node:assert/strict';
import fs from 'node:fs';

const preferencesSource = fs.readFileSync(
  new URL('../entry/src/main/ets/model/TerminaiPreferences.ets', import.meta.url), 'utf8');
const backendSource = fs.readFileSync(
  new URL('../entry/src/main/ets/model/ResidentSessionBackend.ets', import.meta.url), 'utf8');
const indexSource = fs.readFileSync(
  new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const closeSource = fs.readFileSync(
  new URL('../entry/src/main/ets/model/WindowClosePreference.ets', import.meta.url), 'utf8');
const notificationSource = fs.readFileSync(
  new URL('../entry/src/main/ets/model/SessionNotificationService.ets', import.meta.url), 'utf8');
const entrySource = fs.readFileSync(
  new URL('../entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url), 'utf8');

assert.match(preferencesSource, /private static instance: preferences\.Preferences/);
assert.match(preferencesSource, /static get\(context: common\.Context\): preferences\.Preferences/);
assert.match(entrySource, /TerminaiPreferences\.configure\(applicationContext\)/);
assert.match(backendSource, /TerminaiPreferences\.get\(context\)/);
assert.match(indexSource, /TerminaiPreferences\.get\(ctx\)/);
assert.match(closeSource, /TerminaiPreferences\.get\(context\)/);
assert.match(notificationSource, /TerminaiPreferences\.get\(context\)/);

for (const source of [backendSource, indexSource, closeSource, notificationSource]) {
  assert.doesNotMatch(source, /getPreferencesSync\(/);
  assert.doesNotMatch(source, /\.flush\(/);
}

assert.match(backendSource, /session snapshot saved count=/);
assert.match(indexSource, /session snapshot loaded count=/);

console.log('single Preferences owner and synchronous snapshot flush contract: OK');
