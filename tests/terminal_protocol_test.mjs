import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import vm from 'node:vm';

const terminalRoot = new URL('../entry/src/main/resources/rawfile/terminal/', import.meta.url);
const html = fs.readFileSync(new URL('terminal.html', terminalRoot), 'utf8');
const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
assert.ok(scriptMatch, 'terminal.html must contain one inline protocol script');

function sha256(name) {
  const value = fs.readFileSync(new URL(name, terminalRoot));
  return crypto.createHash('sha256').update(value).digest('hex');
}

// These exact upstream builds are known to work together. A deliberate vendor
// upgrade must update the hashes and rerun the protocol test.
assert.equal(sha256('xterm.js'),
  '1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495');
assert.equal(sha256('addon-fit.js'),
  'bdaefa370b1bfc42ee88d46fe6072400902a4d4b2d45cd93438dda9b23c97089');
assert.equal(sha256('addon-serialize.js'),
  'fc432359a02f7482bdccd7b8ac46dc917c2d05ea540737900ded8d9cd150b633');

const writes = [];
let resetCount = 0;

class FakeTerminal {
  constructor(options) {
    this.options = options;
    this.cols = 80;
    this.rows = 24;
    this.buffer = {
      active: {
        baseY: 0,
        cursorY: 0,
        getLine: () => null
      }
    };
  }

  loadAddon(addon) {
    if (addon.activate) addon.activate(this);
  }

  open() {}
  onData(callback) { this.dataCallback = callback; }
  onResize(callback) { this.resizeCallback = callback; }
  onTitleChange(callback) { this.titleCallback = callback; }
  onWriteParsed(callback) { this.writeParsedCallback = callback; }
  attachCustomKeyEventHandler(callback) { this.keyCallback = callback; }
  write(data, callback) { writes.push(data); if (callback) callback(); }
  reset() { resetCount++; }
  clear() {}
  focus() {}
  paste() {}
  getSelection() { return ''; }
  hasSelection() { return false; }
  selectAll() {}
}

class FakeFitAddon {
  fit() {}
}

class FakeSerializeAddon {
  activate() {}
  serialize() { return '\x1b[2Jserialized-checkpoint'; }
}

const windowListeners = new Map();
const documentListeners = new Map();
const terminalElement = { style: {} };
const document = {
  documentElement: { style: {} },
  body: { style: {}, appendChild() {}, removeChild() {} },
  getElementById: () => terminalElement,
  addEventListener: (name, callback) => { documentListeners.set(name, callback); },
  createElement: () => ({ style: {}, select() {} }),
  execCommand: () => true
};
const windowObject = {
  addEventListener: (name, callback) => { windowListeners.set(name, callback); },
  ResizeObserver: undefined
};

const context = {
  Terminal: FakeTerminal,
  FitAddon: { FitAddon: FakeFitAddon },
  SerializeAddon: { SerializeAddon: FakeSerializeAddon },
  window: windowObject,
  document,
  navigator: {},
  console,
  setTimeout,
  clearTimeout,
  requestAnimationFrame: (callback) => setTimeout(callback, 0),
  cancelAnimationFrame: clearTimeout,
  ResizeObserver: undefined
};
vm.runInNewContext(scriptMatch[1], context, { filename: 'terminal.html' });

const sent = [];
const port = {
  onmessage: null,
  onmessageerror: null,
  postMessage(message) { sent.push(message); }
};
const messageListener = windowListeners.get('message');
assert.ok(messageListener, 'output-port transfer listener must be registered');
messageListener({ data: '__terminai_output_port__', ports: [port] });
assert.deepEqual(sent, ['P']);

port.onmessage({ data: 'D7\nhello' });
assert.equal(writes.at(-1), 'hello');
assert.equal(sent.at(-1), 'A7');

port.onmessage({ data: 'B12' });
port.onmessage({ data: 'R12\nold-output' });
assert.equal(resetCount, 1);
assert.equal(writes.at(-1), 'old-output');
assert.equal(sent.at(-1), 'R12');
port.onmessage({ data: 'E12' });
assert.equal(sent.at(-1), 'H12');

port.onmessage({ data: 'Q42' });
assert.equal(sent.at(-1), 'q42');

port.onmessage({ data: 'S321' });
assert.ok(sent.at(-1).startsWith('C321\n'));
assert.ok(sent.at(-1).includes('serialized-checkpoint'));

console.log('terminal protocol and vendor compatibility: OK');
