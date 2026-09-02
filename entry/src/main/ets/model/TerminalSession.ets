// Data model for one PTY terminal session.
import libterminal from 'libterminal.so';

const OUTPUT_HISTORY_MAX_LIMIT = 2 * 1024 * 1024;
const OUTPUT_HISTORY_MIN_LIMIT = 64 * 1024;
const OUTPUT_HISTORY_GLOBAL_BUDGET = 12 * 1024 * 1024;
const OUTPUT_HISTORY_CHUNK_LIMIT = 64 * 1024;
const OUTPUT_CHECKPOINT_MAX_LIMIT = 512 * 1024;

export interface SessionEvent {
  id: number;
  kind: string;      // "output" | "cwd" | "exit"
  data: string;
  exitCode: number;
}

export interface SessionProcessInfo {
  alive: boolean;
  shellPid: number;
  foregroundPid: number;
  foregroundCommand: string;
  foregroundIsShell: boolean;
  foregroundState: string;
  cpuTimeTicks: number;
}

export enum AgentRunState {
  Outputting = '正在输出',
  Silent = '静默运行',
  WaitingInput = '等待输入',
  ReturnedShell = '已返回 Shell',
  Exited = '会话已退出',
  Unknown = '状态未知'
}

/** Renderer-independent lifecycle of the native PTY owned by one logical session. */
export enum SessionRuntimePhase {
  Created = 'created',
  Starting = 'starting',
  Running = 'running',
  Exited = 'exited',
  Failed = 'failed',
  Disposed = 'disposed'
}

export enum NativeStartDisposition {
  Accepted = 0,
  AlreadyExited = 1,
  Stale = 2
}

/** Immutable diagnostics for routing assertions and future in-app support bundles. */
export class SessionRuntimeSnapshot {
  uid: number;
  nativeId: number;
  generation: number;
  phase: SessionRuntimePhase;
  alive: boolean;
  outputCursor: number;
  droppedNativeEvents: number;
  lastNativeEventAt: number;

  constructor(uid: number, nativeId: number, generation: number, phase: SessionRuntimePhase,
    alive: boolean, outputCursor: number, droppedNativeEvents: number, lastNativeEventAt: number) {
    this.uid = uid;
    this.nativeId = nativeId;
    this.generation = generation;
    this.phase = phase;
    this.alive = alive;
    this.outputCursor = outputCursor;
    this.droppedNativeEvents = droppedNativeEvents;
    this.lastNativeEventAt = lastNativeEventAt;
  }
}

/** One bounded slice from the session-owned output ring. */
export class TerminalOutputSlice {
  startCursor: number;
  endCursor: number;
  data: string;
  cursorWasTrimmed: boolean;

  constructor(startCursor: number, endCursor: number, data: string, cursorWasTrimmed: boolean) {
    this.startCursor = startCursor;
    this.endCursor = endCursor;
    this.data = data;
    this.cursorWasTrimmed = cursorWasTrimmed;
  }
}

/** Stable recovery payload plus the absolute output cursor it represents. */
export class TerminalOutputSnapshot {
  startCursor: number;
  endCursor: number;
  data: string;

  constructor(startCursor: number, endCursor: number, data: string) {
    this.startCursor = startCursor;
    this.endCursor = endCursor;
    this.data = data;
  }
}

class TerminalOutputObserver {
  id: number;
  callback: (data: string) => void;

  constructor(id: number, callback: (data: string) => void) {
    this.id = id;
    this.callback = callback;
  }
}

class TerminalStateObserver {
  id: number;
  callback: () => void;

  constructor(id: number, callback: () => void) {
    this.id = id;
    this.callback = callback;
  }
}

@Observed
export class TerminalSession {
  id: number = -1;         // native session id, assigned when shell spawns
  uid: number = 0;         // unique UI id (stable across list removals)
  name: string;
  /** Small reusable number rendered separately from the session name. */
  sequence: number = 1;
  /** Stable allocation key; renaming a session must not change its type bucket. */
  typeKey: string = '';
  cwd: string = '~';
  /** Optional command to run instead of the default login shell. */
  cmd: string = '';
  /** Login-shell name shown for plain terminals (zsh local, bash/fish/sh remote). */
  shellName: string = 'zsh';
  /** Logical agent kind selected by the user; independent of executable path overrides. */
  agentKind: string = '';
  /** Brand icon kind; custom agents use the shared Gemini mark. */
  agentIconKind: string = '';
  /** Device identity is copied into a session so removing a saved host does not orphan its label. */
  deviceId: string = 'local';
  deviceName: string = '本机';
  sshTarget: string = '';
  /** OpenSSH multiplex socket established by the device connection manager. */
  sshControlPath: string = '';
  /** Per-device known-hosts file shared by validation, scan and terminal sessions. */
  sshKnownHostsPath: string = '';
  alive: boolean = false;
  unread: boolean = false;
  exitCode: number = -1;
  exitNotificationSent: boolean = false;
  /** Multi-signal state derived from PTY output, rendered screen, input, process role and exit. */
  activityState: AgentRunState = AgentRunState.Unknown;
  lastOutputAt: number = 0;
  /** Last output containing visible text, rather than cursor/control traffic only. */
  lastMeaningfulOutputAt: number = 0;
  lastInputAt: number = 0;
  lastScreenChangedAt: number = 0;
  foregroundCommand: string = '';
  foregroundIsShell: boolean = false;
  foregroundPid: number = -1;
  foregroundState: string = '';
  lastCpuTimeTicks: number = 0;
  lastProcessActivityAt: number = 0;
  processSignalAvailable: boolean = false;
  private recentText: string = '';
  private screenText: string = '';
  private privateSignalTail: string = '';
  private titleSignalTail: string = '';
  private observedAgentProcess: boolean = false;
  private explicitReturnedShell: boolean = false;
  /** Bounded raw PTY history used to restore an ArkWeb page after hiding or reload. */
  private outputHistoryChunks: string[] = [];
  private outputHistoryLength: number = 0;
  private outputHistoryTruncated: boolean = false;
  /** Dynamic per-session share of the process-wide history budget. */
  private outputHistoryLimit: number = OUTPUT_HISTORY_MAX_LIMIT;
  /** Absolute cursor of outputHistoryChunks[0]; only moves forward when old output is trimmed. */
  private outputHistoryStartCursor: number = 0;
  /** xterm SerializeAddon checkpoint, captured only after the active renderer becomes quiet. */
  private outputCheckpoint: string = '';
  private outputCheckpointCursor: number = -1;
  outputVersion: number = 0;
  /** Guards asynchronous ArkWeb page callbacks from spawning duplicate native PTYs. */
  startInProgress: boolean = false;
  nativeStartCompleted: boolean = false;
  disposed: boolean = false;
  /** Every native start attempt owns one generation; callbacks from older attempts are rejected. */
  runtimeGeneration: number = 0;
  runtimePhase: SessionRuntimePhase = SessionRuntimePhase.Created;
  nativeStartedAt: number = 0;
  nativeExitedAt: number = 0;
  lastNativeEventAt: number = 0;
  droppedNativeEvents: number = 0;
  /** Explicit sidebar renames take precedence over agent-provided terminal titles. */
  manualTitle: boolean = false;
  /** TerminalView → Index: called when this session wants attention. */
  onStateChanged: () => void = () => {};
  /** Persisted metadata changed (title, cwd, etc.); activity-only changes do not use this callback. */
  onMetadataChanged: () => void = () => {};
  /** Process lifecycle changed independently of the current ArkUI renderer. */
  onRuntimeChanged: () => void = () => {};
  /** Multiple renderer clients may observe one PTY without stealing each other's callback. */
  private outputObserverCounter: number = 0;
  private outputObservers: TerminalOutputObserver[] = [];
  /** Process services observe state independently from the replaceable ArkUI page. */
  private stateObserverCounter: number = 0;
  private stateObservers: TerminalStateObserver[] = [];
  /** Native TSFN events are owned by the session, never by an evictable ArkWeb view. */
  onNativeEvent: (generation: number, event: SessionEvent) => void = () => {};
  /** Called when the shell's working directory changes. */
  onCwdChanged: (cwd: string) => void = () => {};
  /** Last native process inspection start; keeps background scans adaptive and staggered. */
  lastProcessInspectionAt: number = 0;

  constructor(name: string, sequence: number) {
    this.name = name;
    this.sequence = sequence;
  }

  displayName(): string {
    return this.name + this.sequence.toString();
  }

  isAgentSession(): boolean {
    return this.agentKind.length > 0;
  }

  markManualTitle(): void {
    this.manualTitle = true;
  }

  /**
   * herdrm displays the agent's stripped terminal title. xterm exposes the
   * same OSC 0/2 title source, so use it when the CLI supplies a meaningful
   * conversation title and the user has not explicitly renamed the session.
   */
  updateTerminalTitle(value: string): void {
    if (!this.isAgentSession() || this.manualTitle) {
      return;
    }
    let title = value
      .replace(/\x1B\[[0-?]*[ -\/]*[@-~]/g, '')
      .replace(/[\r\n\t]+/g, ' ')
      .replace(/\s{2,}/g, ' ')
      .trim();
    if (title.length < 2) {
      return;
    }
    const suffixes: string[] = [
      ' — Claude Code', ' - Claude Code', ' — Codex', ' - Codex',
      ' — Gemini', ' - Gemini', ' — Kimi', ' - Kimi'
    ];
    for (const suffix of suffixes) {
      if (title.endsWith(suffix)) {
        title = title.substring(0, title.length - suffix.length).trim();
        break;
      }
    }
    const lower = title.toLowerCase();
    const agent = this.agentKind.toLowerCase();
    const cwd = this.cwd.trim().toLowerCase();
    const generic = lower === agent || lower === 'codex' || lower === 'claude' ||
      lower === 'claude code' || lower === 'gemini' || lower === 'kimi' ||
      lower === 'grok' || lower === 'terminal' || lower === 'zsh' ||
      lower === 'bash' || lower === 'sh' || lower === 'fish' ||
      lower === cwd || lower.startsWith('~/') || lower.startsWith('/') ||
      /^[^ ]+@[^ ]+:[/~]/.test(title);
    if (generic || title.length < 2) {
      return;
    }
    if (title.length > 64) {
      title = title.substring(0, 63) + '…';
    }
    if (this.name !== title) {
      this.name = title;
      this.notifyStateChanged();
      this.onMetadataChanged();
    }
  }

  /** Parse OSC 0/2 titles directly from PTY output before ArkWeb finishes rendering it. */
  private trackTerminalTitles(data: string): void {
    let remaining = this.titleSignalTail + data;
    this.titleSignalTail = '';
    let searchFrom = 0;
    for (;;) {
      const start = remaining.indexOf('\x1B]', searchFrom);
      if (start < 0) {
        const escape = remaining.lastIndexOf('\x1B');
        if (escape >= 0) {
          const possiblePrefix = remaining.substring(escape);
          if ('\x1B]'.startsWith(possiblePrefix)) {
            this.titleSignalTail = possiblePrefix;
          }
        }
        return;
      }
      const separator = remaining.indexOf(';', start + 2);
      if (separator < 0) {
        this.titleSignalTail = remaining.substring(start).slice(-4096);
        return;
      }
      const code = remaining.substring(start + 2, separator);
      if (code !== '0' && code !== '2') {
        searchFrom = separator + 1;
        continue;
      }
      const bellEnd = remaining.indexOf('\x07', separator + 1);
      const stringEnd = remaining.indexOf('\x1B\\', separator + 1);
      let end = -1;
      let terminatorLength = 1;
      if (bellEnd >= 0 && (stringEnd < 0 || bellEnd < stringEnd)) {
        end = bellEnd;
      } else if (stringEnd >= 0) {
        end = stringEnd;
        terminatorLength = 2;
      }
      if (end < 0) {
        this.titleSignalTail = remaining.substring(start).slice(-4096);
        return;
      }
      this.updateTerminalTitle(remaining.substring(separator + 1, end));
      remaining = remaining.substring(end + terminatorLength);
      searchFrom = 0;
    }
  }

  private trimOutputHistory(): void {
    let historyTrimmed = false;
    while (this.outputHistoryLength > this.outputHistoryLimit &&
      this.outputHistoryChunks.length > 1) {
      const removed = this.outputHistoryChunks[0];
      this.outputHistoryChunks.splice(0, 1);
      this.outputHistoryLength -= removed.length;
      this.outputHistoryStartCursor += removed.length;
      historyTrimmed = true;
    }
    if (this.outputHistoryLength > this.outputHistoryLimit &&
      this.outputHistoryChunks.length === 1) {
      const only = this.outputHistoryChunks[0];
      const removedLength = only.length - this.outputHistoryLimit;
      this.outputHistoryChunks[0] = only.substring(removedLength);
      this.outputHistoryLength = this.outputHistoryChunks[0].length;
      this.outputHistoryStartCursor += removedLength;
      historyTrimmed = true;
    }
    if (historyTrimmed) {
      this.outputHistoryTruncated = true;
      // Start a recovery replay at a complete output line instead of in the
      // middle of a CSI/OSC sequence or a UTF-16 surrogate pair.
      if (this.outputHistoryChunks.length > 0) {
        const first = this.outputHistoryChunks[0];
        const lineBoundary = first.indexOf('\n');
        if (lineBoundary >= 0 && lineBoundary < 8192) {
          const removedLength = lineBoundary + 1;
          this.outputHistoryChunks[0] = first.substring(removedLength);
          this.outputHistoryLength -= removedLength;
          this.outputHistoryStartCursor += removedLength;
        }
      }
    }
    const checkpointLimit = Math.min(OUTPUT_CHECKPOINT_MAX_LIMIT,
      Math.max(OUTPUT_HISTORY_MIN_LIMIT, Math.floor(this.outputHistoryLimit / 2)));
    if (this.outputCheckpointCursor < this.outputHistoryStartCursor ||
      this.outputCheckpoint.length > checkpointLimit) {
      this.outputCheckpoint = '';
      this.outputCheckpointCursor = -1;
    }
  }

  /** Rebalance this session without ever allowing one terminal to dominate process memory. */
  setOutputHistoryLimit(limit: number): void {
    this.outputHistoryLimit = Math.max(OUTPUT_HISTORY_MIN_LIMIT,
      Math.min(OUTPUT_HISTORY_MAX_LIMIT, Math.floor(limit)));
    this.trimOutputHistory();
  }

  private appendOutputHistory(data: string): void {
    if (data.length === 0) {
      return;
    }
    const lastIndex = this.outputHistoryChunks.length - 1;
    if (lastIndex >= 0 &&
      this.outputHistoryChunks[lastIndex].length + data.length <= OUTPUT_HISTORY_CHUNK_LIMIT) {
      this.outputHistoryChunks[lastIndex] += data;
    } else {
      this.outputHistoryChunks.push(data);
    }
    this.outputHistoryLength += data.length;
    this.trimOutputHistory();
    this.outputVersion++;
  }

  outputHistoryText(): string {
    const history = this.outputHistoryChunks.join('');
    if (!this.outputHistoryTruncated) {
      return history;
    }
    // xterm is reset before replay. Reinforce a known primary-buffer/default-
    // attributes checkpoint so a truncated alternate-screen or color sequence
    // cannot poison the recovered terminal state.
    return '\x1Bc\x1B[?1049l\x1B[0m' +
      '[terminAI] 较早的终端输出已截断，以稳定模式恢复最近内容。\r\n' + history;
  }

  outputHistoryStart(): number {
    return this.outputHistoryStartCursor;
  }

  outputCursor(): number {
    return this.outputHistoryStartCursor + this.outputHistoryLength;
  }

  runtimeSnapshot(): SessionRuntimeSnapshot {
    return new SessionRuntimeSnapshot(this.uid, this.id, this.runtimeGeneration,
      this.runtimePhase, this.alive, this.outputCursor(), this.droppedNativeEvents,
      this.lastNativeEventAt);
  }

  subscribeOutput(callback: (data: string) => void): number {
    this.outputObserverCounter++;
    const observer = new TerminalOutputObserver(this.outputObserverCounter, callback);
    this.outputObservers.push(observer);
    return observer.id;
  }

  subscribeState(callback: () => void): number {
    this.stateObserverCounter++;
    const observer = new TerminalStateObserver(this.stateObserverCounter, callback);
    this.stateObservers.push(observer);
    return observer.id;
  }

  markUnread(value: boolean): void {
    if (this.unread === value) {
      return;
    }
    this.unread = value;
    this.notifyStateChanged();
  }

  unsubscribeState(observerId: number): void {
    if (observerId <= 0) {
      return;
    }
    const index = this.stateObservers.findIndex((observer: TerminalStateObserver) =>
      observer.id === observerId);
    if (index >= 0) {
      this.stateObservers.splice(index, 1);
    }
  }

  private notifyStateChanged(): void {
    this.onStateChanged();
    const observers = this.stateObservers.slice();
    for (const observer of observers) {
      try {
        observer.callback();
      } catch (error) {
        console.error('TERMINAI terminal state observer failed: ' + JSON.stringify(error));
      }
    }
  }

  unsubscribeOutput(observerId: number): void {
    if (observerId <= 0) {
      return;
    }
    const index = this.outputObservers.findIndex((observer: TerminalOutputObserver) =>
      observer.id === observerId);
    if (index >= 0) {
      this.outputObservers.splice(index, 1);
    }
  }

  private emitOutput(data: string): void {
    const observers = this.outputObservers.slice();
    for (const observer of observers) {
      try {
        observer.callback(data);
      } catch (error) {
        console.error('TERMINAI terminal output observer failed: ' + JSON.stringify(error));
      }
    }
  }

  /**
   * Read only the delta after an absolute renderer cursor. No TerminalView owns
   * a second growing output queue; all views consume this one bounded ring.
   */
  outputAfter(cursor: number, maximumLength: number): TerminalOutputSlice {
    const historyStart = this.outputHistoryStartCursor;
    const historyEnd = this.outputCursor();
    const cursorWasTrimmed = cursor < historyStart;
    const effectiveCursor = Math.max(cursor, historyStart);
    if (effectiveCursor >= historyEnd || maximumLength <= 0) {
      return new TerminalOutputSlice(effectiveCursor, effectiveCursor, '', cursorWasTrimmed);
    }

    let skip = effectiveCursor - historyStart;
    let remaining = Math.min(maximumLength, historyEnd - effectiveCursor);
    const pieces: string[] = [];
    for (const chunk of this.outputHistoryChunks) {
      if (skip >= chunk.length) {
        skip -= chunk.length;
        continue;
      }
      const available = chunk.length - skip;
      const take = Math.min(available, remaining);
      pieces.push(chunk.substring(skip, skip + take));
      remaining -= take;
      skip = 0;
      if (remaining <= 0) {
        break;
      }
    }
    const data = pieces.join('');
    return new TerminalOutputSlice(effectiveCursor, effectiveCursor + data.length,
      data, cursorWasTrimmed);
  }

  outputSnapshot(): TerminalOutputSnapshot {
    if (this.outputCheckpoint.length > 0 &&
      this.outputCheckpointCursor >= this.outputHistoryStartCursor &&
      this.outputCheckpointCursor <= this.outputCursor()) {
      const remaining = this.outputCursor() - this.outputCheckpointCursor;
      const delta = this.outputAfter(this.outputCheckpointCursor, remaining);
      if (!delta.cursorWasTrimmed) {
        return new TerminalOutputSnapshot(this.outputCheckpointCursor,
          delta.endCursor, this.outputCheckpoint + delta.data);
      }
    }
    return new TerminalOutputSnapshot(this.outputHistoryStartCursor,
      this.outputCursor(), this.outputHistoryText());
  }

  recordOutputCheckpoint(cursor: number, data: string): void {
    // MessagePort traffic and session memory remain bounded even when the user
    // configures an extremely large xterm scrollback value.
    const checkpointLimit = Math.min(OUTPUT_CHECKPOINT_MAX_LIMIT,
      Math.max(OUTPUT_HISTORY_MIN_LIMIT, Math.floor(this.outputHistoryLimit / 2)));
    if (data.length === 0 || data.length > checkpointLimit ||
      cursor < this.outputHistoryStartCursor || cursor > this.outputCursor() ||
      cursor < this.outputCheckpointCursor) {
      return;
    }
    this.outputCheckpointCursor = cursor;
    this.outputCheckpoint = data;
  }

  /** Atomically reserves a start generation so two ArkWeb views cannot spawn the same session. */
  beginNativeStart(): number {
    if (this.disposed || this.id > 0 || this.startInProgress || this.nativeStartCompleted) {
      return 0;
    }
    this.runtimeGeneration++;
    this.runtimePhase = SessionRuntimePhase.Starting;
    this.startInProgress = true;
    this.nativeStartedAt = Date.now();
    this.nativeExitedAt = 0;
    this.onRuntimeChanged();
    return this.runtimeGeneration;
  }

  isCurrentStart(generation: number): boolean {
    return !this.disposed && generation > 0 && generation === this.runtimeGeneration;
  }

  /** Completes a createSession call that may already have delivered early output/exit events. */
  completeNativeStart(generation: number, nativeId: number): NativeStartDisposition {
    if (!this.isCurrentStart(generation)) {
      return NativeStartDisposition.Stale;
    }
    if (this.runtimePhase === SessionRuntimePhase.Exited) {
      this.startInProgress = false;
      this.nativeStartCompleted = true;
      return NativeStartDisposition.AlreadyExited;
    }
    if (this.id > 0 && this.id !== nativeId) {
      this.droppedNativeEvents++;
      return NativeStartDisposition.Stale;
    }
    this.id = nativeId;
    this.alive = true;
    this.startInProgress = false;
    this.nativeStartCompleted = true;
    this.runtimePhase = SessionRuntimePhase.Running;
    this.onRuntimeChanged();
    return NativeStartDisposition.Accepted;
  }

  /** Validate generation and native id before any PTY event is allowed to mutate this session. */
  acceptNativeEvent(generation: number, event: SessionEvent): boolean {
    if (!this.isCurrentStart(generation) || event.id <= 0 ||
      this.runtimePhase === SessionRuntimePhase.Failed ||
      this.runtimePhase === SessionRuntimePhase.Disposed) {
      this.droppedNativeEvents++;
      return false;
    }
    if (this.id <= 0 && this.runtimePhase === SessionRuntimePhase.Starting) {
      // Native reader threads can publish output before createSession returns.
      this.id = event.id;
    }
    if (this.id !== event.id) {
      this.droppedNativeEvents++;
      return false;
    }
    this.lastNativeEventAt = Date.now();
    if (event.kind === 'exit') {
      this.runtimePhase = SessionRuntimePhase.Exited;
      this.nativeExitedAt = this.lastNativeEventAt;
      this.startInProgress = false;
      this.nativeStartCompleted = true;
    } else if (this.runtimePhase === SessionRuntimePhase.Starting) {
      this.runtimePhase = SessionRuntimePhase.Running;
      this.alive = true;
      this.nativeStartCompleted = true;
    }
    this.handleEvent(event);
    return true;
  }

  releaseExitedNativeId(generation: number, nativeId: number): void {
    if (generation === this.runtimeGeneration && this.id === nativeId) {
      this.id = -1;
      this.onRuntimeChanged();
    }
  }

  markStartFailure(generation: number, reason: string): void {
    if (!this.isCurrentStart(generation) || this.nativeStartCompleted) {
      return;
    }
    this.startInProgress = false;
    this.nativeStartCompleted = true;
    this.alive = false;
    this.exitCode = 127;
    this.runtimePhase = SessionRuntimePhase.Failed;
    this.nativeExitedAt = Date.now();
    const detail = reason.trim().length > 0 ? reason.trim() : '未知错误';
    const notice = '\r\n[terminAI] 无法启动会话：' + detail + '\r\n';
    this.appendOutputHistory(notice);
    this.emitOutput(notice);
    this.activityState = this.isAgentSession() ? AgentRunState.Exited : this.activityState;
    this.notifyStateChanged();
    this.onRuntimeChanged();
  }

  /** Reuse the logical session and renderer while starting a fresh PTY/SSH process. */
  prepareRestart(): boolean {
    if (this.disposed || this.id > 0 || this.startInProgress ||
      (this.runtimePhase !== SessionRuntimePhase.Exited &&
      this.runtimePhase !== SessionRuntimePhase.Failed)) {
      return false;
    }
    this.nativeStartCompleted = false;
    this.alive = false;
    this.exitCode = -1;
    this.exitNotificationSent = false;
    this.runtimePhase = SessionRuntimePhase.Created;
    this.explicitReturnedShell = false;
    this.observedAgentProcess = false;
    this.processSignalAvailable = false;
    this.foregroundCommand = '';
    this.foregroundIsShell = false;
    this.foregroundPid = -1;
    this.recentText = '';
    this.screenText = '';
    this.activityState = this.isAgentSession() ? AgentRunState.Unknown : this.activityState;
    const notice = '\r\n[terminAI] 正在重新连接会话…\r\n';
    this.appendOutputHistory(notice);
    this.emitOutput(notice);
    this.notifyStateChanged();
    this.onRuntimeChanged();
    return true;
  }

  /** Invalidates every callback before SessionManager removes this logical session. */
  disposeRuntime(): number {
    const nativeId = this.id;
    this.disposed = true;
    this.alive = false;
    this.startInProgress = false;
    this.nativeStartCompleted = true;
    this.runtimePhase = SessionRuntimePhase.Disposed;
    this.runtimeGeneration++;
    this.id = -1;
    return nativeId;
  }

  private setActivityState(next: AgentRunState): void {
    if (!this.isAgentSession() || this.activityState === next) {
      return;
    }
    this.activityState = next;
    this.notifyStateChanged();
  }

  private stripTerminalControls(value: string): string {
    return value
      .replace(/\x1B\][^\x07]*(\x07|\x1B\\)/g, '')
      .replace(/\x1B\[[0-?]*[ -\/]*[@-~]/g, '')
      .replace(/\r/g, '\n');
  }

  private containsInputPrompt(value: string): boolean {
    // Only inspect the visible tail. Matching prompt words anywhere in the
    // transcript (for example an agent quoting credential or choice prompts)
    // produces false notifications long after that text was printed.
    const tail = value.slice(-1600).replace(/[ \t]+$/g, '');
    const promptAtTail = /(waiting for input|needs your input|press (enter|return)|do you want to proceed|allow this action|would you like to|enter to confirm|what would you like|ask anything|type a message|是否继续|等待输入|请输入)[^\n]{0,180}$/i;
    const choiceAtTail = /(continue\?|\(y\/n\)|\[y\/n\])\s*$/i;
    return promptAtTail.test(tail) || choiceAtTail.test(tail) ||
      /(^|\n)\s*[›>] ?[^\n]{0,220}$/.test(tail);
  }

  private containsTraditionalShellPrompt(value: string): boolean {
    return /(^|\n)[^\n]{0,120}[$#%]\s*$/.test(value);
  }

  /** Parses terminAI-private OSC signals even when a marker spans PTY chunks. */
  private trackPrivateSignals(data: string): void {
    const marker = '\x1B]777;';
    let remaining = this.privateSignalTail + data;
    let start = remaining.indexOf(marker);
    while (start >= 0) {
      const end = remaining.indexOf('\x07', start + marker.length);
      if (end < 0) {
        remaining = remaining.substring(start);
        break;
      }
      const payload = remaining.substring(start + marker.length, end);
      if (payload.startsWith('terminai-cwd=') && this.sshTarget.length > 0) {
        const nextCwd = payload.substring('terminai-cwd='.length);
        if (nextCwd.length > 0 && nextCwd !== this.cwd) {
          this.cwd = nextCwd;
          this.onCwdChanged(nextCwd);
          this.notifyStateChanged();
        }
      } else if (payload === 'terminai-agent-returned' && this.isAgentSession()) {
        this.explicitReturnedShell = true;
        this.observedAgentProcess = true;
        this.setActivityState(AgentRunState.ReturnedShell);
      }
      remaining = remaining.substring(end + 1);
      start = remaining.indexOf(marker);
    }
    // Retain only a possible split marker prefix, not arbitrary terminal text.
    if (start < 0) {
      const escape = remaining.lastIndexOf('\x1B');
      remaining = escape >= 0 ? remaining.substring(escape) : '';
      if (remaining.length > marker.length || marker.indexOf(remaining) !== 0) {
        remaining = '';
      }
    }
    this.privateSignalTail = remaining.length > 4096 ?
      remaining.substring(remaining.length - 4096) : remaining;
  }

  private hasFreshInputPrompt(): boolean {
    if (this.lastInputAt === 0) {
      return this.containsInputPrompt(this.screenText + '\n' + this.recentText);
    }
    const freshScreen = this.lastScreenChangedAt > this.lastInputAt &&
      this.containsInputPrompt(this.screenText);
    const freshOutput = this.lastMeaningfulOutputAt > this.lastInputAt &&
      this.containsInputPrompt(this.recentText);
    return freshScreen || freshOutput;
  }

  recordInput(data: string): void {
    if (!this.isAgentSession()) {
      return;
    }
    this.lastInputAt = Date.now();
    // Input consumes the old prompt. Require new output or a changed snapshot
    // before classifying this session as waiting again.
    this.recentText = '';
    if (this.alive && !this.explicitReturnedShell) {
      this.setActivityState(AgentRunState.Silent);
    }
  }

  recordScreen(text: string): void {
    if (!this.isAgentSession()) {
      return;
    }
    const plain = this.stripTerminalControls(text);
    if (plain !== this.screenText) {
      this.screenText = plain;
      this.lastScreenChangedAt = Date.now();
    }
  }

  updateProcess(info: SessionProcessInfo): void {
    if (!this.isAgentSession()) {
      return;
    }
    this.processSignalAvailable = true;
    this.foregroundCommand = info.foregroundCommand;
    this.foregroundIsShell = info.foregroundIsShell;
    this.foregroundState = info.foregroundState;
    const now = Date.now();
    if (this.foregroundPid !== info.foregroundPid) {
      this.foregroundPid = info.foregroundPid;
      this.lastCpuTimeTicks = info.cpuTimeTicks;
      this.lastProcessActivityAt = now;
    } else if (info.cpuTimeTicks > this.lastCpuTimeTicks) {
      this.lastCpuTimeTicks = info.cpuTimeTicks;
      this.lastProcessActivityAt = now;
    }
    if (!info.foregroundIsShell && info.foregroundCommand.length > 0) {
      this.observedAgentProcess = true;
    }
    // Process inspection is advisory and can briefly miss a still-running PTY
    // while /proc changes. Only the generation-gated native exit event owns
    // `alive` and the Exited transition.
    if (!info.alive) {
      this.processSignalAvailable = false;
    }
  }

  updateActivity(now: number): void {
    if (!this.isAgentSession()) {
      return;
    }
    if (!this.alive) {
      this.setActivityState(AgentRunState.Exited);
      return;
    }
    if (this.explicitReturnedShell) {
      this.setActivityState(AgentRunState.ReturnedShell);
      return;
    }
    const activityAt = Math.max(this.lastMeaningfulOutputAt, this.lastScreenChangedAt);
    if (activityAt === 0) {
      this.setActivityState(this.processSignalAvailable && !this.foregroundIsShell ?
        AgentRunState.Silent : AgentRunState.Unknown);
      return;
    }
    const quietFor = now - activityAt;
    const screenStableFor = this.lastScreenChangedAt > 0 ? now - this.lastScreenChangedAt : 0;
    // The local foreground process is authoritative when it is available.
    if (this.foregroundIsShell && this.observedAgentProcess && quietFor >= 400) {
      this.setActivityState(AgentRunState.ReturnedShell);
      return;
    }
    // Delayed shell-prompt matching is only a fallback. Agent wrappers emit an
    // exact private marker on both local and remote sessions.
    if (this.sshTarget.length === 0 && !this.processSignalAvailable &&
      this.observedAgentProcess && quietFor >= 900 &&
      screenStableFor >= 600 &&
      this.containsTraditionalShellPrompt(this.screenText)) {
      this.setActivityState(AgentRunState.ReturnedShell);
      return;
    }
    if (quietFor >= 400 && screenStableFor >= 300 && this.hasFreshInputPrompt()) {
      this.setActivityState(AgentRunState.WaitingInput);
      return;
    }
    if (quietFor < 900) {
      this.setActivityState(AgentRunState.Outputting);
      return;
    }
    if (this.lastProcessActivityAt > 0 && now - this.lastProcessActivityAt < 800 &&
      !this.foregroundIsShell) {
      this.setActivityState(AgentRunState.Silent);
      return;
    }
    if (this.processSignalAvailable && !this.foregroundIsShell) {
      this.setActivityState(AgentRunState.Silent);
      return;
    }
    if (this.observedAgentProcess && quietFor < 120000) {
      this.setActivityState(AgentRunState.Silent);
      return;
    }
    this.setActivityState(AgentRunState.Unknown);
  }

  handleEvent(ev: SessionEvent): void {
    if (ev.kind === 'exit') {
      this.alive = false;
      this.startInProgress = false;
      this.exitCode = ev.exitCode;
      const exitNotice = ev.exitCode === 0 ?
        '\r\n[terminAI] 会话已结束（退出码 0）\r\n' :
        '\r\n[terminAI] 会话异常退出（退出码 ' + ev.exitCode.toString() +
          '），请检查启动命令、工作目录或 SSH 连接。\r\n';
      this.appendOutputHistory(exitNotice);
      this.emitOutput(exitNotice);
      this.activityState = this.isAgentSession() ? AgentRunState.Exited : this.activityState;
      this.notifyStateChanged();
      return;
    }
    if (ev.kind === 'cwd') {
      // The native child of a remote session is the local ssh process, so its
      // /proc cwd is not the remote cwd. Remote sessions use the private OSC
      // marker emitted by TerminalView's remote monitor instead.
      if (this.sshTarget.length > 0) {
        return;
      }
      if (ev.data.length > 0 && ev.data !== this.cwd) {
        this.cwd = ev.data;
        this.onCwdChanged(ev.data);
        this.notifyStateChanged();
      }
      return;
    }
    if (ev.kind === 'output') {
      this.trackTerminalTitles(ev.data);
      this.appendOutputHistory(ev.data);
      this.trackPrivateSignals(ev.data);
      this.lastOutputAt = Date.now();
      const plain = this.stripTerminalControls(ev.data);
      if (plain.trim().length > 0) {
        this.lastMeaningfulOutputAt = this.lastOutputAt;
        this.recentText = (this.recentText + plain).slice(-8000);
      }
      if (this.isAgentSession() && plain.trim().length > 0 && !this.explicitReturnedShell) {
        this.setActivityState(AgentRunState.Outputting);
      }
      this.emitOutput(ev.data);
    }
  }
}

/** One stable identity for local paths that render as the same space. */
export function canonicalSessionCwd(session: TerminalSession): string {
  let path = session.cwd.trim();
  if (path.length === 0) {
    path = '~';
  }
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (session.sshTarget.length === 0) {
    if (path === '~' || path === '/storage/Users/currentUser') {
      return '/storage/Users/currentUser';
    }
    if (path.startsWith('~/')) {
      return '/storage/Users/currentUser/' + path.substring(2);
    }
  }
  return path;
}

export class SessionManager {
  sessions: TerminalSession[] = [];
  private uidCounter: number = 0;
  /** UI observers may come and go; native event ownership stays in this manager. */
  onEvent: (session: TerminalSession, event: SessionEvent) => void = () => {};
  onRuntimeChanged: () => void = () => {};
  /** Backend ownership hooks; UI pages must not replace these callbacks. */
  onSessionAdded: (session: TerminalSession) => void = () => {};
  onSessionRemoving: (session: TerminalSession) => void = () => {};
  /** Called by a generation-bound native callback; never capture an evictable ArkUI component. */
  dispatchForSession(uid: number, generation: number, ev: SessionEvent): void {
    const session = this.sessions.find((item: TerminalSession) => item.uid === uid);
    if (session === undefined) {
      return;
    }
    if (!session.acceptNativeEvent(generation, ev)) {
      return;
    }
    if (ev.kind === 'exit') {
      const deadId = ev.id;
      session.releaseExitedNativeId(generation, deadId);
      libterminal.killSessionAsync(deadId)
        .catch((error: Error) => {
          console.error('TERMINAI async exited-session cleanup failed: ' + error.message);
        });
      this.onRuntimeChanged();
    }
    this.onEvent(session, ev);
  }

  /** Compatibility route for tests and legacy native callbacks that already own a native id. */
  dispatch: (ev: SessionEvent) => void = (ev: SessionEvent) => {
    const session = this.sessions.find((item: TerminalSession) => item.id === ev.id);
    if (session !== undefined) {
      this.dispatchForSession(session.uid, session.runtimeGeneration, ev);
    }
  };

  runtimeSnapshots(): SessionRuntimeSnapshot[] {
    return this.sessions.map((session: TerminalSession) => session.runtimeSnapshot());
  }

  private rebalanceOutputHistoryLimits(): void {
    if (this.sessions.length === 0) {
      return;
    }
    const perSession = Math.floor(OUTPUT_HISTORY_GLOBAL_BUDGET / this.sessions.length);
    for (const session of this.sessions) {
      session.setOutputHistoryLimit(perSession);
    }
  }

  private nextSequence(typeKey: string, preferredSequence: number): number {
    if (preferredSequence > 0 && !this.sessions.some((item: TerminalSession) =>
      item.typeKey === typeKey && item.sequence === preferredSequence)) {
      return preferredSequence;
    }
    let candidate = 1;
    while (this.sessions.some((item: TerminalSession) =>
      item.typeKey === typeKey && item.sequence === candidate)) {
      candidate++;
    }
    return candidate;
  }

  private capitalizeName(value: string): string {
    if (value.length === 0) {
      return value;
    }
    return value.substring(0, 1).toUpperCase() + value.substring(1);
  }

  newSession(startCwd: string = '~',
    cmd: string = '', label: string = '', iconKind: string = '', deviceId: string = 'local',
    deviceName: string = '本机', sshTarget: string = '', sshControlPath: string = '',
    sshKnownHostsPath: string = '', shellName: string = 'zsh',
    preferredSequence: number = 0): TerminalSession {
    this.uidCounter++;
    const base = label.length > 0 ? label : shellName;
    const counterKey = base.toLowerCase();
    const nextCount = this.nextSequence(counterKey, preferredSequence);
    const s = new TerminalSession(this.capitalizeName(base), nextCount);
    s.uid = this.uidCounter;
    s.typeKey = counterKey;
    s.cwd = startCwd;
    s.cmd = cmd;
    s.shellName = shellName;
    s.agentKind = label;
    s.agentIconKind = iconKind.length > 0 ? iconKind : label;
    s.deviceId = deviceId;
    s.deviceName = deviceName;
    s.sshTarget = sshTarget;
    s.sshControlPath = sshControlPath;
    s.sshKnownHostsPath = sshKnownHostsPath;
    s.onNativeEvent = (generation: number, event: SessionEvent) => {
      this.dispatchForSession(s.uid, generation, event);
    };
    s.onRuntimeChanged = () => { this.onRuntimeChanged(); };
    this.sessions.push(s);
    this.onSessionAdded(s);
    this.rebalanceOutputHistoryLimits();
    this.onRuntimeChanged();
    return s;
  }

  remove(s: TerminalSession): void {
    this.onSessionRemoving(s);
    const nativeId = s.disposeRuntime();
    if (nativeId > 0) {
      libterminal.killSessionAsync(nativeId)
        .catch((error: Error) => {
          console.error('TERMINAI async session cleanup failed: ' + error.message);
        });
    }
    const idx = this.sessions.indexOf(s);
    if (idx >= 0) this.sessions.splice(idx, 1);
    this.rebalanceOutputHistoryLimits();
    this.onRuntimeChanged();
  }

  removeAll(): void {
    for (const s of this.sessions) {
      this.onSessionRemoving(s);
      const nativeId = s.disposeRuntime();
      if (nativeId > 0) {
        libterminal.killSessionAsync(nativeId)
          .catch((error: Error) => {
            console.error('TERMINAI async session cleanup failed: ' + error.message);
          });
      }
    }
    this.sessions = [];
    this.onRuntimeChanged();
  }
}
