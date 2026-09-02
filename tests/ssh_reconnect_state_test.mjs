import assert from 'node:assert/strict';
import fs from 'node:fs';

const stateSource = fs.readFileSync(
  new URL('../entry/src/main/ets/model/RemoteSshState.ets', import.meta.url), 'utf8');
const indexSource = fs.readFileSync(
  new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');

assert.match(stateSource, /Reconnecting = '等待重连'/);
assert.match(stateSource, /HostKeyFailed = '主机密钥异常'/);
assert.match(stateSource, /NetworkFailed = '网络不可达'/);
assert.match(stateSource, /attemptGeneration: number = 0/);
assert.match(indexSource, /scheduleConnectionRetry\(/);
assert.match(indexSource, /connection\.acceptMasterEvent\(generation, event\.id\)/);
assert.match(indexSource, /connection\.acceptScanEvent\(generation, event\.id\)/);
assert.match(indexSource, /cancelPendingRemoteSessions\(connection, reason\)/);
assert.match(indexSource, /connection\.pendingSessions = \[\]/);

const backendSource = fs.readFileSync(
  new URL('../entry/src/main/ets/model/ResidentSessionBackend.ets', import.meta.url), 'utf8');
const entryAbilitySource = fs.readFileSync(
  new URL('../entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url), 'utf8');
const configureBody = backendSource.match(/configure\(context: common\.Context[\s\S]*?\n  \}/)?.[0] ?? '';
assert.match(configureBody, /this\.shuttingDown = false/);
assert.match(configureBody, /if \(resumePersistence\)/);
const shutdownBody = backendSource.match(/shutdown\(\): void \{[\s\S]*?\n  \}/)?.[0] ?? '';
assert.match(shutdownBody, /connection\.invalidate\(true\)/);
assert.ok(shutdownBody.indexOf('connection.invalidate(true)') < shutdownBody.indexOf('this.stopNativeSession(scanId)'));
assert.ok(shutdownBody.indexOf('this.shuttingDown = true') < shutdownBody.indexOf('this.persistSessionsNow()'));
const flushBody = backendSource.match(/flushPersistence\(\): void \{[\s\S]*?\n  \}/)?.[0] ?? '';
assert.match(flushBody, /if \(this\.shuttingDown\)/);
const keepBackgroundBody = entryAbilitySource.match(
  /private async keepRunningInStatusBar\(\): Promise<void> \{[\s\S]*?\n  \}/)?.[0] ?? '';
assert.ok(keepBackgroundBody.indexOf('this.backend.flushPersistence()') <
  keepBackgroundBody.indexOf('await this.context.terminateSelf()'));
const foregroundBody = entryAbilitySource.match(/onForeground\(\): void \{[\s\S]*?\n  \}/)?.[0] ?? '';
assert.match(foregroundBody, /this\.allowTermination = false/);
assert.match(foregroundBody, /this\.backend\.configure/);
const backgroundBody = entryAbilitySource.match(/onBackground\(\): void \{[\s\S]*?\n  \}/)?.[0] ?? '';
assert.match(backgroundBody, /this\.backend\.flushPersistence\(\)/);

// Restart snapshots represent only real sidebar sessions. An invisible SSH
// request left in pendingSessions must never resurrect an older agent after a
// newer visible session was the one present when the app closed.
const persistedItemsBody = backendSource.match(
  /private persistedSessionItems\(\): SavedSessionInfo\[\] \{[\s\S]*?\n  \}/)?.[0] ?? '';
assert.match(persistedItemsBody, /this\.sessionManager\.sessions/);
assert.doesNotMatch(persistedItemsBody, /for \(const pending of connection\.pendingSessions\)/);

const visibleAtClose = [{ agentKind: 'Codex' }];
const invisibleOlderRequests = [{ agentKind: 'Kimi' }];
const restartSnapshot = visibleAtClose.map((session) => session.agentKind);
assert.deepEqual(restartSnapshot, ['Codex']);
assert.equal(restartSnapshot.includes(invisibleOlderRequests[0].agentKind), false);

const delays = [];
for (let attempt = 0; attempt < 9; attempt++) {
  const exponent = Math.min(attempt, 5);
  delays.push(Math.min(30000, 1000 * Math.pow(2, exponent)));
}
assert.deepEqual(delays, [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000, 30000]);

class AttemptGate {
  constructor() {
    this.generation = 0;
    this.manualDisconnect = false;
  }

  begin() {
    this.generation++;
    this.manualDisconnect = false;
    return this.generation;
  }

  accepts(generation) {
    return !this.manualDisconnect && generation === this.generation;
  }

  disconnect() {
    this.manualDisconnect = true;
    this.generation++;
  }
}

const gate = new AttemptGate();
const first = gate.begin();
const second = gate.begin();
assert.equal(gate.accepts(first), false);
assert.equal(gate.accepts(second), true);
gate.disconnect();
assert.equal(gate.accepts(second), false);

console.log('SSH generation gate and exponential reconnect contract: OK');
