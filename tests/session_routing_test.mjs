import assert from 'node:assert/strict';
import fs from 'node:fs';

const sessionSource = fs.readFileSync(
  new URL('../entry/src/main/ets/model/TerminalSession.ets', import.meta.url), 'utf8');
const viewSource = fs.readFileSync(
  new URL('../entry/src/main/ets/view/TerminalView.ets', import.meta.url), 'utf8');
const indexSource = fs.readFileSync(
  new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const backendSource = fs.readFileSync(
  new URL('../entry/src/main/ets/model/ResidentSessionBackend.ets', import.meta.url), 'utf8');

// Source-level contract: native callbacks must be bound to a logical UID and a
// start generation. Routing only by a reusable native id caused cross-session
// output after rapid close/create cycles.
assert.match(sessionSource, /dispatchForSession\(uid: number, generation: number/);
assert.match(sessionSource, /item\.uid === uid/);
assert.match(sessionSource, /session\.acceptNativeEvent\(generation, ev\)/);
assert.match(viewSource, /onNativeEvent\(generation, ev\)/);
assert.doesNotMatch(viewSource, /this\.session\.id = id;/);
assert.match(sessionSource, /subscribeOutput\(callback:/);
assert.match(sessionSource, /unsubscribeOutput\(observerId:/);
assert.match(sessionSource, /s\.onNativeEvent = \(generation: number, event: SessionEvent\)/);
assert.doesNotMatch(indexSource, /s\.onNativeEvent\s*=/);
assert.match(sessionSource, /subscribeState\(callback:/);
assert.match(backendSource, /session\.subscribeState/);
assert.match(backendSource, /inspectSessionAsync\(expectedNativeId\)/);
assert.match(backendSource, /schedulePersistence\(\): void/);
assert.match(backendSource, /encodeSavedSessions\(items\)/);
const updateProcessBody = sessionSource.match(/updateProcess\(info: SessionProcessInfo\): void \{[\s\S]*?\n  \}/)?.[0] ?? '';
assert.doesNotMatch(updateProcessBody, /this\.alive\s*=\s*false/);
assert.match(updateProcessBody, /this\.processSignalAvailable = false/);
assert.match(indexSource, /case KEYCODE_D:[\s\S]*this\.openSplit\(shift\)/);
assert.match(indexSource, /splitTerminalPane\(session: TerminalSession\)/);
assert.match(indexSource, /splitDivider\(\)/);
assert.match(indexSource, /this\.splitRatio \* 100/);
assert.match(indexSource, /case KEYCODE_W:[\s\S]*this\.closeSplit\(\)/);
assert.match(indexSource, /@State private splitPaneCwd: string = ''/);
assert.match(indexSource, /Text\(this\.programLabel\(this\.splitPaneSession!\)\)/);
assert.match(indexSource, /Text\(this\.displayCwd\(this\.splitPaneCwd\)\)/);
assert.match(indexSource, /s\.uid === this\.splitSessionUid[\s\S]*this\.splitPaneCwd = s\.cwd/);
assert.doesNotMatch(indexSource, /Button\('关闭分屏'/);
assert.match(indexSource, /this\.splitPaneSession !== null && !this\.splitHorizontal/);
assert.match(indexSource, /if \(this\.splitHorizontal\) \{[\s\S]*Text\(this\.programLabel\(session\)\)/);
assert.match(indexSource, /private sharedTitlePrimaryWeight\(\): number/);
assert.match(indexSource, /this\.workspaceWidth \* this\.splitRatio/);
assert.match(indexSource, /const flexibleWidth = this\.workspaceWidth - 1/);
assert.match(indexSource, /layoutWeight\(this\.sharedTitleSecondaryWeight\(\)\)/);
assert.match(indexSource, /right: this\.titleButtonInset \+ 10/);
assert.match(viewSource, /@Prop @Watch\('onFocusRequestChanged'\) focusRequest/);
assert.match(viewSource, /@Prop @Watch\('onLayoutRefreshRequestChanged'\) layoutRefreshRequest/);
assert.match(viewSource, /private scheduleTerminalLayoutFit\(\): void/);
assert.doesNotMatch(viewSource.match(/private scheduleTerminalLayoutFit\(\): void \{[\s\S]*?\n  \}/)?.[0] ?? '',
  /controller\.refresh\(/);
assert.match(indexSource, /private scheduleSplitLayoutRefresh\(\): void/);
assert.match(indexSource, /this\.terminalLayoutRefreshRequest\+\+/);
assert.match(indexSource, /layoutRefreshRequest: this\.terminalLayoutRefreshRequest/);
assert.match(viewSource, /handleOutputPortMessage\(portGeneration: number/);
assert.match(viewSource, /portGeneration !== this\.outputPortGeneration/);

class SimulatedSession {
  constructor(uid) {
    this.uid = uid;
    this.nativeId = -1;
    this.generation = 0;
    this.phase = 'created';
    this.events = [];
    this.dropped = 0;
  }

  begin() {
    this.generation++;
    this.phase = 'starting';
    return this.generation;
  }

  accept(generation, event) {
    if (generation !== this.generation || this.phase === 'disposed') {
      this.dropped++;
      return false;
    }
    if (this.nativeId <= 0 && this.phase === 'starting') this.nativeId = event.id;
    if (this.nativeId !== event.id) {
      this.dropped++;
      return false;
    }
    this.phase = event.kind === 'exit' ? 'exited' : 'running';
    this.events.push(event.data);
    return true;
  }

  complete(generation, nativeId) {
    if (generation !== this.generation || this.phase === 'disposed') return 'stale';
    if (this.phase === 'exited') return 'exited';
    if (this.nativeId > 0 && this.nativeId !== nativeId) return 'stale';
    this.nativeId = nativeId;
    this.phase = 'running';
    return 'accepted';
  }

  dispose() {
    this.phase = 'disposed';
    this.nativeId = -1;
    this.generation++;
  }
}

const first = new SimulatedSession(1);
const firstGeneration = first.begin();
// Reader output is allowed to arrive before createSession returns its id.
assert.equal(first.accept(firstGeneration, { id: 41, kind: 'output', data: 'early' }), true);
assert.equal(first.complete(firstGeneration, 41), 'accepted');
assert.deepEqual(first.events, ['early']);

const second = new SimulatedSession(2);
const secondGeneration = second.begin();
assert.equal(second.accept(secondGeneration, { id: 42, kind: 'output', data: 'second' }), true);
assert.equal(second.complete(secondGeneration, 42), 'accepted');
assert.deepEqual(first.events, ['early']);
assert.deepEqual(second.events, ['second']);

first.dispose();
assert.equal(first.accept(firstGeneration, { id: 41, kind: 'output', data: 'late' }), false);
assert.deepEqual(first.events, ['early']);
assert.equal(first.dropped, 1);

const exitedEarly = new SimulatedSession(3);
const exitedGeneration = exitedEarly.begin();
assert.equal(exitedEarly.accept(exitedGeneration, { id: 43, kind: 'exit', data: '' }), true);
assert.equal(exitedEarly.complete(exitedGeneration, 43), 'exited');

console.log('session uid/generation/native-id routing contract: OK');
