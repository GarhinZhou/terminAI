// Data model for one PTY terminal session.
import libterminal from 'libterminal.so';

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
  private observedAgentProcess: boolean = false;
  private explicitReturnedShell: boolean = false;
  /** Output that arrived before the Web terminal page finished loading. */
  pendingOutput: string[] = [];
  /** Set by TerminalView once the xterm.js page is ready. */
  termReady: boolean = false;
  /** TerminalView → Index: called when this session wants attention. */
  onStateChanged: () => void = () => {};
  /** TerminalView → native bridge callbacks, wired by TerminalView. */
  onOutput: (data: string) => void = () => {};
  /** Called when the shell's working directory changes. */
  onCwdChanged: (cwd: string) => void = () => {};

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
      this.exitCode = ev.exitCode;
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
      if (this.termReady) {
        this.onOutput(ev.data);
      } else {
        this.pendingOutput.push(ev.data);
      }
    }
  }

  flushPending(): void {
    if (this.pendingOutput.length > 0) {
      const joined = this.pendingOutput.join('');
      this.pendingOutput = [];
      this.onOutput(joined);
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

  private nextSequence(typeKey: string): number {
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
    sshKnownHostsPath: string = ''): TerminalSession {
    this.uidCounter++;
    const base = label.length > 0 ? label : 'zsh';
    const counterKey = base.toLowerCase();
    const nextCount = this.nextSequence(counterKey);
    const s = new TerminalSession(this.capitalizeName(base), nextCount);
    s.uid = this.uidCounter;
    s.typeKey = counterKey;
    s.cwd = startCwd;
    s.cmd = cmd;
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
    if (s.id > 0) {
      try { libterminal.killSession(s.id); } catch (e) {}
    }
    const idx = this.sessions.indexOf(s);
    if (idx >= 0) this.sessions.splice(idx, 1);
  }

  removeAll(): void {
    for (const s of this.sessions) {
      if (s.id > 0) {
        try { libterminal.killSession(s.id); } catch (e) {}
      }
    }
    this.sessions = [];
  }
}
