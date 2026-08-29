// Data model for one PTY terminal session.
import libterminal from 'libterminal.so';

const OUTPUT_HISTORY_LIMIT = 2 * 1024 * 1024;
const OUTPUT_HISTORY_CHUNK_LIMIT = 64 * 1024;

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
  /** Explicit sidebar renames take precedence over agent-provided terminal titles. */
  manualTitle: boolean = false;
  /** TerminalView → Index: called when this session wants attention. */
  onStateChanged: () => void = () => {};
  /** Persisted metadata changed (title, cwd, etc.); activity-only changes do not use this callback. */
  onMetadataChanged: () => void = () => {};
  /** TerminalView → native bridge callbacks, wired by TerminalView. */
  onOutput: (data: string) => void = () => {};
  /** Native TSFN events are owned by the session, never by an evictable ArkWeb view. */
  onNativeEvent: (event: SessionEvent) => void = () => {};
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
      this.onStateChanged();
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
    let historyTrimmed = false;
    while (this.outputHistoryLength > OUTPUT_HISTORY_LIMIT &&
      this.outputHistoryChunks.length > 1) {
      const removed = this.outputHistoryChunks[0];
      this.outputHistoryChunks.splice(0, 1);
      this.outputHistoryLength -= removed.length;
      this.outputHistoryStartCursor += removed.length;
      historyTrimmed = true;
    }
    if (this.outputHistoryLength > OUTPUT_HISTORY_LIMIT &&
      this.outputHistoryChunks.length === 1) {
      const only = this.outputHistoryChunks[0];
      const removedLength = only.length - OUTPUT_HISTORY_LIMIT;
      this.outputHistoryChunks[0] = only.substring(removedLength);
      this.outputHistoryLength = this.outputHistoryChunks[0].length;
      this.outputHistoryStartCursor += removedLength;
      historyTrimmed = true;
    }
    if (historyTrimmed) {
      this.outputHistoryTruncated = true;
      // Start a recovery replay at a complete output line instead of in the
      // middle of a CSI/OSC sequence or a UTF-16 surrogate pair.
      const first = this.outputHistoryChunks[0];
      const lineBoundary = first.indexOf('\n');
      if (lineBoundary >= 0 && lineBoundary < 8192) {
        const removedLength = lineBoundary + 1;
        this.outputHistoryChunks[0] = first.substring(removedLength);
        this.outputHistoryLength -= removedLength;
        this.outputHistoryStartCursor += removedLength;
      }
    }
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
    if (data.length === 0 || data.length > 1024 * 1024 ||
      cursor < this.outputHistoryStartCursor || cursor > this.outputCursor() ||
      cursor < this.outputCheckpointCursor) {
      return;
    }
    this.outputCheckpointCursor = cursor;
    this.outputCheckpoint = data;
  }

  private setActivityState(next: AgentRunState): void {
    if (!this.isAgentSession() || this.activityState === next) {
      return;
    }
    this.activityState = next;
    this.onStateChanged();
  }

  private stripTerminalControls(value: string): string {
    return value
      .replace(/\x1B\][^\x07]*(\x07|\x1B\\)/g, '')
      .replace(/\x1B\[[0-?]*[ -\/]*[@-~]/g, '')
      .replace(/\r/g, '\n');
  }

  private containsInputPrompt(value: string): boolean {
    const text = value.toLowerCase();
    return text.indexOf('waiting for input') >= 0 ||
      text.indexOf('needs your input') >= 0 ||
      text.indexOf('press enter') >= 0 ||
      text.indexOf('press return') >= 0 ||
      text.indexOf('do you want to proceed') >= 0 ||
      text.indexOf('allow this action') >= 0 ||
      text.indexOf('would you like to') >= 0 ||
      text.indexOf('enter to confirm') >= 0 ||
      text.indexOf('password:') >= 0 ||
      text.indexOf('are you sure you want to continue connecting') >= 0 ||
      text.indexOf('continue?') >= 0 ||
      text.indexOf('(y/n)') >= 0 ||
      text.indexOf('[y/n]') >= 0 ||
      text.indexOf('是否继续') >= 0 ||
      text.indexOf('等待输入') >= 0 ||
      text.indexOf('请输入') >= 0 ||
      text.indexOf('what would you like') >= 0 ||
      text.indexOf('ask anything') >= 0 ||
      text.indexOf('type a message') >= 0 ||
      /(^|\n)\s*[›>] ?[^\n]*$/.test(value);
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
          this.onStateChanged();
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
    if (!info.alive) {
      this.alive = false;
      this.setActivityState(AgentRunState.Exited);
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
    if (!this.processSignalAvailable && this.observedAgentProcess && quietFor >= 900 &&
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
      this.onOutput(exitNotice);
      this.activityState = this.isAgentSession() ? AgentRunState.Exited : this.activityState;
      this.onStateChanged();
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
      this.onOutput(ev.data);
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
  /** Called from native TSFN. Must find session and dispatch. */
  dispatch: (ev: SessionEvent) => void = () => {};

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
    this.sessions.push(s);
    return s;
  }

  remove(s: TerminalSession): void {
    s.disposed = true;
    s.startInProgress = false;
    if (s.id > 0) {
      libterminal.killSessionAsync(s.id)
        .catch((error: Error) => {
          console.error('TERMINAI async session cleanup failed: ' + error.message);
        });
    }
    const idx = this.sessions.indexOf(s);
    if (idx >= 0) this.sessions.splice(idx, 1);
  }

  removeAll(): void {
    for (const s of this.sessions) {
      s.disposed = true;
      s.startInProgress = false;
      if (s.id > 0) {
        libterminal.killSessionAsync(s.id)
          .catch((error: Error) => {
            console.error('TERMINAI async session cleanup failed: ' + error.message);
          });
      }
    }
    this.sessions = [];
  }
}
