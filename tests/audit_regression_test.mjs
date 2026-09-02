import assert from 'node:assert/strict';
import fs from 'node:fs';

const indexSource = fs.readFileSync(
  new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const sidebarSource = fs.readFileSync(
  new URL('../entry/src/main/ets/view/SidebarView.ets', import.meta.url), 'utf8');
const terminalViewSource = fs.readFileSync(
  new URL('../entry/src/main/ets/view/TerminalView.ets', import.meta.url), 'utf8');
const deviceDialogSource = fs.readFileSync(
  new URL('../entry/src/main/ets/view/DeviceManagerDialog.ets', import.meta.url), 'utf8');
const backendSource = fs.readFileSync(
  new URL('../entry/src/main/ets/model/ResidentSessionBackend.ets', import.meta.url), 'utf8');
const sessionSource = fs.readFileSync(
  new URL('../entry/src/main/ets/model/TerminalSession.ets', import.meta.url), 'utf8');
const terminalHtml = fs.readFileSync(
  new URL('../entry/src/main/resources/rawfile/terminal/terminal.html', import.meta.url), 'utf8');
const sidebarViewSource = sidebarSource;

assert.match(sidebarSource, /'垂直分屏', 'Ctrl \+ Alt \+ D'/);
assert.match(terminalViewSource, /const RENDERER_HEARTBEAT_TIMEOUT = 12000/);
assert.match(indexSource, /combinedAuthOutput\.slice\(-65536\)/);
assert.doesNotMatch(indexSource, /authOutput \+ event\.data\)\.slice\(-8000\)/);
assert.doesNotMatch(indexSource, /primaryRenderedSessions\(\)/);

const saveMethod = deviceDialogSource.match(/private async saveDevice\(\): Promise<void> \{[\s\S]*?\n  \}/)?.[0] ?? '';
assert.ok(saveMethod.indexOf('await this.onDeviceSaved') < saveMethod.indexOf('this.onDevicesChanged'));
assert.match(saveMethod, /this\.onDeviceCommitted\(savedDevice\)/);
assert.match(sessionSource, /markUnread\(value: boolean\)/);
assert.match(backendSource, /session\.subscribeOutput/);
assert.match(backendSource, /session\.markUnread\(true\)/);
assert.doesNotMatch(backendSource, /setInterval\(/);
assert.match(backendSource, /session\.sshTarget\.length > 0/);
assert.doesNotMatch(sessionSource.match(/containsInputPrompt\(value: string\)[\s\S]*?\n  \}/)?.[0] ?? '',
  /password:/);
assert.match(sidebarViewSource, /private commitRename\(session: TerminalSession\)/);
assert.match(sidebarViewSource, /\.onBlur\(\(\) => \{\s*this\.commitRename\(item\)/);
const agentsBody = sidebarSource.match(/private agents\(source: TerminalSession\[\]\): TerminalSession\[\] \{[\s\S]*?\n  \}/)?.[0] ?? '';
assert.doesNotMatch(agentsBody, /\.sort\(/);
assert.doesNotMatch(sidebarSource, /private agentUrgency\(/);
const saveStyleBody = indexSource.match(/private saveStylePrefs\(\): void \{[\s\S]*?\n  \}/)?.[0] ?? '';
assert.match(saveStyleBody, /store\.flushSync\(\)/);
assert.doesNotMatch(saveStyleBody, /PREF_(CUSTOM_AGENTS|DEVICES|SELECTED_DEVICE|REMOTE_AGENTS)/);
assert.match(terminalViewSource, /window\.termFind/);
const openSearchBody = terminalViewSource.match(/private openTerminalSearch\(\): void \{[\s\S]*?\n  \}/)?.[0] ?? '';
assert.doesNotMatch(openSearchBody, /requestFocus|setTimeout/);
assert.match(terminalViewSource, /\.defaultFocus\(true\)/);
assert.doesNotMatch(terminalViewSource, /Button\('[↑↓×]'/);
assert.match(terminalViewSource, /searchActionButton\(IconName\.Close/);
assert.match(terminalViewSource, /\.accessibilityText\(label\)/);
assert.match(terminalViewSource, /\.constraintSize\(\{ minWidth: 40, maxWidth: 96 \}\)/);
assert.match(terminalViewSource, /Text\(this\.searchResultLabel\(\)\)[\s\S]*?\.maxLines\(1\)/);
assert.match(terminalHtml, /window\.termFind = function/);
assert.doesNotMatch(terminalHtml, /window\.termPasteClipboard/);
assert.doesNotMatch(terminalHtml, /window\.termReplay/);

for (const file of ['SessionNotificationService.ets', 'BackgroundSessionService.ets',
  'StatusBarResidentService.ets']) {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/model/' + file, import.meta.url), 'utf8');
  assert.doesNotMatch(source, /const APP_BUNDLE_NAME =/);
  assert.match(source, /common\/AppIdentity/);
}

console.log('audited SSH, shortcut and renderer regressions: OK');
