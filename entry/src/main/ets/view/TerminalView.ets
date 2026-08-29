// Web-based terminal view: xterm.js inside ArkWeb, bridged to native PTY.
import libterminal from 'libterminal.so';
import { webview } from '@kit.ArkWeb';
import { pasteboard } from '@kit.BasicServicesKit';
import { TerminalSession, SessionEvent, TerminalOutputSlice,
  TerminalOutputSnapshot } from '../model/TerminalSession';
import { Theme } from '../common/Theme';
import { normalizedSshTarget } from '../model/ManagedDevice';
import { SshCredentialStore } from '../model/SshCredentialStore';
import { SshSecretValue } from '../model/RemoteSshState';

const KEYCODE_CTRL_LEFT = 2072;
const KEYCODE_CTRL_RIGHT = 2073;
const KEYCODE_SHIFT_LEFT = 2047;
const KEYCODE_SHIFT_RIGHT = 2048;
const KEYCODE_K = 2027;
const KEYCODE_T = 2036;
const KEYCODE_W = 2039;
const KEYCODE_B = 2018;
const KEYCODE_N = 2030;
const RENDER_BATCH_DELAY = 16;
const OUTPUT_MESSAGE_CHUNK = 32 * 1024;
const REPLAY_PROGRESS_TIMEOUT = 8000;
const OUTPUT_MESSAGE_LIVE = 'D';
const OUTPUT_MESSAGE_REPLAY_BEGIN = 'B';
const OUTPUT_MESSAGE_REPLAY_CHUNK = 'R';
const OUTPUT_MESSAGE_REPLAY_END = 'E';
const OUTPUT_MESSAGE_HEARTBEAT = 'Q';
const OUTPUT_MESSAGE_CHECKPOINT_REQUEST = 'S';
const RENDERER_HEARTBEAT_INTERVAL = 5000;
const RENDERER_HEARTBEAT_TIMEOUT = 3500;
const RENDERER_UNRESPONSIVE_GRACE = 2500;
const TERMINAL_CHECKPOINT_DELAY = 900;

// Bridge object exposed to JS as window.ohosBridge
class TermBridge {
  private session: TerminalSession;

  constructor(session: TerminalSession) {
    this.session = session;
  }

  onTermInput(data: string): void {
    this.session.recordInput(data);
    if (this.session.id > 0) {
      const ok = libterminal.writeSession(this.session.id, data);
      if (!ok) {
        console.error('TERMINAI terminal input write failed for session ' + this.session.id.toString());
      }
    } else {
      console.info('TERMINAI bridge onTermInput ignored (no session)');
    }
  }

  onTermSnapshot(text: string): void {
    this.session.recordScreen(text);
  }

  onTermTitle(title: string): void {
    this.session.updateTerminalTitle(title);
  }

  onTermResize(cols: number, rows: number): void {
    if (this.session.id > 0) {
      libterminal.resizeSession(this.session.id, cols, rows);
    }
  }
}

@Component
export struct TerminalView {
  @ObjectLink session: TerminalSession;
  @Prop @Watch('onActiveChanged') active: boolean = true;
  onEvent: (ev: SessionEvent) => void = () => {};
  onShortcut: (keyCode: number, shift: boolean) => void = () => {};
  // Style state mirrored from AppStorage; changes push into xterm.js.
  @StorageProp('fontSize') @Watch('onStyleChanged') fontSize: number = 14;
  @StorageProp('fontBold') @Watch('onStyleChanged') fontBold: boolean = false;
  @StorageProp('isDark') @Watch('onStyleChanged') isDark: boolean = true;
  @StorageProp('cursorStyle') @Watch('onStyleChanged') cursorStyle: string = 'block';
  @StorageProp('fontFamily') @Watch('onStyleChanged') fontFamily: string = '';
  @StorageProp('colorScheme') @Watch('onStyleChanged') colorScheme: string = 'default';
  @StorageProp('scrollback') @Watch('onScrollbackChanged') scrollback: number = 10000;
  @StorageProp('lineHeight') @Watch('onStyleChanged') lineHeight: number = 1.0;
  private controller: webview.WebviewController = new webview.WebviewController();
  private termBridge: TermBridge | null = null;
  private ctrlDown: boolean = false;
  private shiftDown: boolean = false;
  private interceptedShortcutKeyCode: number = 0;
  private pageReady: boolean = false;
  private renderScheduled: boolean = false;
  private replayNeeded: boolean = true;
  /** Absolute position in TerminalSession's output ring already parsed by this xterm instance. */
  private renderedCursor: number = 0;
  private liveWriteEndCursor: number = 0;
  private outputPorts: webview.WebMessagePort[] = [];
  private outputPort: webview.WebMessagePort | null = null;
  private outputPortReady: boolean = false;
  private pageLoadCount: number = 0;
  private outputPortRetryCount: number = 0;
  private outputPortRetryScheduled: boolean = false;
  private outputPortGeneration: number = 0;
  private rendererReloadNeeded: boolean = false;
  private rendererReloadAttempts: number = 0;
  private rendererReloadScheduled: boolean = false;
  private replayInFlight: boolean = false;
  private replayHistory: string = '';
  private replayOffset: number = 0;
  private replayToken: number = 0;
  private replayProgress: number = 0;
  private replayTargetCursor: number = 0;
  private liveWriteInFlight: boolean = false;
  private liveWriteGeneration: number = 0;
  private liveWriteWatchdogTimer: number = -1;
  private replayWatchdogTimer: number = -1;
  private rendererHeartbeatTimer: number = -1;
  private rendererHeartbeatTimeoutTimer: number = -1;
  private rendererHeartbeatGeneration: number = 0;
  private rendererHeartbeatAwaiting: boolean = false;
  private rendererUnresponsiveTimer: number = -1;
  private checkpointTimer: number = -1;
  private styleDirty: boolean = true;
  private scrollbackDirty: boolean = true;
  @State private rendererUnavailable: boolean = false;
  @State private rendererFailureReason: string = '';
  private outputOwner: TerminalSession | null = null;
  private outputHandler: (data: string) => void = (data: string) => {
    this.queueTerminalOutput(data);
  };

  private terminalBridge(): TermBridge {
    if (this.termBridge === null) {
      this.termBridge = new TermBridge(this.session);
    }
    return this.termBridge;
  }

  private isApplicationShortcut(keyCode: number): boolean {
    return keyCode === KEYCODE_K || keyCode === KEYCODE_T || keyCode === KEYCODE_W ||
      keyCode === KEYCODE_B || keyCode === KEYCODE_N;
  }

  /** Web does not support common onKeyEvent; intercept shortcuts before xterm consumes them. */
  private interceptKeyEvent(event: KeyEvent): boolean {
    if (event.keyCode === KEYCODE_CTRL_LEFT || event.keyCode === KEYCODE_CTRL_RIGHT) {
      this.ctrlDown = event.type === KeyType.Down;
      if (!this.ctrlDown) {
        this.interceptedShortcutKeyCode = 0;
      }
      // false = let ArkWeb/xterm consume the key. The previous implementation
      // returned true here and swallowed Ctrl, Ctrl+C/V and cursor keys.
      return false;
    }
    if (event.keyCode === KEYCODE_SHIFT_LEFT || event.keyCode === KEYCODE_SHIFT_RIGHT) {
      this.shiftDown = event.type === KeyType.Down;
      return false;
    }
    if (event.type === KeyType.Up && event.keyCode === this.interceptedShortcutKeyCode) {
      this.interceptedShortcutKeyCode = 0;
      return true;
    }
    if (event.type !== KeyType.Down || !this.ctrlDown ||
      !this.isApplicationShortcut(event.keyCode)) {
      return false;
    }
    if (this.interceptedShortcutKeyCode !== event.keyCode) {
      this.interceptedShortcutKeyCode = event.keyCode;
      this.onShortcut(event.keyCode, this.shiftDown);
    }
    // true = application consumed this shortcut, so xterm must not receive it.
    return true;
  }

  private pushStyle(): void {
    if (!this.active || !this.pageReady) {
      this.styleDirty = true;
      return;
    }
    const bold = this.fontBold ? 'true' : 'false';
    const dark = this.isDark ? 'true' : 'false';
    const cursor = JSON.stringify(this.cursorStyle);
    const scheme = JSON.stringify(this.colorScheme);
    this.styleDirty = false;
    this.controller.runJavaScript('window.termSetStyle(' + this.fontSize + ', ' + bold + ', '
      + dark + ', ' + (this.fontFamily.length > 0 ? JSON.stringify(this.fontFamily) : 'null')
      + ', ' + cursor + ', ' + scheme + ', ' + this.lineHeight + ')')
      .catch(() => { this.styleDirty = true; });
  }

  private shellQuote(value: string): string {
    return "'" + value.replace(/'/g, "'\"'\"'") + "'";
  }

  /** Remote working-directory command; expands ~ / ~/… against the remote home. */
  private remoteChangeDirectory(): string {
    const cwd = this.session.cwd.trim();
    if (cwd.length === 0 || cwd === '~') {
      return 'cd -- "$HOME"';
    }
    if (cwd.startsWith('~/')) {
      return 'cd -- "$HOME"/' + this.shellQuote(cwd.substring(2));
    }
    return 'cd -- ' + this.shellQuote(cwd);
  }

  /** Preserve the selected cwd after remote interactive-shell initialization. */
  private remoteInteractiveShell(changeDirectory: string): string {
    // Some developer images explicitly return to $HOME from .bashrc. Source
    // the real user config first, then apply terminAI's requested cwd last in
    // the same Bash process. This reads but never modifies the remote config.
    const bashStartup = 'if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi; ' +
      changeDirectory;
    return 'terminai_shell="${SHELL:-/bin/sh}"; ' +
      'terminai_shell_name="${terminai_shell##*/}"; ' +
      'if [ "$terminai_shell_name" = "bash" ]; then ' +
      'exec "$terminai_shell" --rcfile <(printf \'%s\\n\' ' + this.shellQuote(bashStartup) + ') -i ' +
      '|| exec /bin/sh -i; else exec "$terminai_shell" -i || exec /bin/sh -i; fi';
  }

  /** Build a real OpenSSH PTY command. Host input is validated when saved and quoted again here. */
  private remoteStartCommand(): string {
    const target = normalizedSshTarget(this.session.sshTarget);
    const changeDirectory = this.remoteChangeDirectory();
    // The local child is only `ssh`, so /proc/<child>/cwd cannot represent the
    // remote shell. A lightweight remote monitor follows the exec-stable shell
    // PID and emits a private OSC event whenever its directory changes.
    const directoryMonitor = 'terminai_pid=$$; (terminai_last=""; ' +
      'while kill -0 "$terminai_pid" 2>/dev/null; do ' +
      'terminai_cwd=$(readlink "/proc/$terminai_pid/cwd" 2>/dev/null); ' +
      'if [ -n "$terminai_cwd" ] && [ "$terminai_cwd" != "$terminai_last" ]; then ' +
      'printf \'\\033]777;terminai-cwd=%s\\007\' "$terminai_cwd"; terminai_last="$terminai_cwd"; fi; ' +
      'sleep 0.3; done) & ';
    // Run the directory change after login-shell initialization. Some remote
    // profiles call `cd` themselves, so changing directory before `shell -l`
    // can silently put the session back in $HOME.
    let sessionScript = changeDirectory + ' || { ' +
      'printf "terminAI: 无法进入远端空间 %s\\n" ' + this.shellQuote(this.session.cwd.trim()) +
      ' >&2; exit 72; }; ' + directoryMonitor;
    const interactiveShell = this.remoteInteractiveShell(changeDirectory);
    if (this.session.cmd.length > 0) {
      sessionScript += 'clear; (' + this.session.cmd +
        '); printf \'\\033]777;terminai-agent-returned\\007\'; ' + interactiveShell;
    } else {
      sessionScript += 'clear; ' + interactiveShell;
    }
    const remoteScript = 'exec "${SHELL:-/bin/sh}" -lc ' + this.shellQuote(sessionScript);
    return '/usr/bin/ssh -tt -o BatchMode=no -o ConnectTimeout=10 ' +
      '-o ServerAliveInterval=15 -o ServerAliveCountMax=3 ' +
      '-o StrictHostKeyChecking=accept-new -o ' +
      this.shellQuote('UserKnownHostsFile=' + this.session.sshKnownHostsPath) + ' ' +
      '-o PasswordAuthentication=yes -o KbdInteractiveAuthentication=yes ' +
      '-o PreferredAuthentications=publickey,password,keyboard-interactive ' +
      '-o NumberOfPasswordPrompts=1 -- ' +
      this.shellQuote(target) + ' ' + this.shellQuote(remoteScript);
  }

  private localStartCommand(): string {
    if (!this.session.isAgentSession() || this.session.cmd.length === 0) {
      return this.session.cmd;
    }
    // Preserve a usable local terminal after a CLI agent exits. The native
    // foreground-process signal then changes from the agent back to zsh. The
    // marker also gives remote/local detection one exact shared signal.
    return '(' + this.session.cmd +
      '); printf \'\\033]777;terminai-agent-returned\\007\'; ' +
      'exec /usr/bin/zsh -l || exec /bin/sh -l';
  }

  onStyleChanged(): void {
    this.pushStyle();
  }

  onScrollbackChanged(): void {
    if (!this.active || !this.pageReady) {
      this.scrollbackDirty = true;
      return;
    }
    this.scrollbackDirty = false;
    this.controller.runJavaScript('window.termSetScrollback(' + this.scrollback + ')')
      .catch(() => { this.scrollbackDirty = true; });
  }

  private terminalFocusId(): string {
    return 'terminal_web_' + this.session.uid.toString();
  }

  private focusTerminalInput(): void {
    if (!this.active || !this.pageReady) return;
    try {
      this.getUIContext().getFocusController().requestFocus(this.terminalFocusId());
    } catch (error) {
      console.error('TERMINAI focus terminal Web failed: ' + JSON.stringify(error));
    }
    this.controller.runJavaScript('window.termFitNow(); window.termFocus()').catch(() => {});
  }

  private scheduleTerminalFocus(): void {
    if (!this.active || !this.pageReady) return;
    setTimeout(() => { this.focusTerminalInput(); }, 0);
  }

  private updateRendererActivity(): void {
    if (!this.pageReady) {
      return;
    }
    try {
      if (this.active) {
        this.controller.onActive();
      } else {
        this.controller.onInactive();
      }
    } catch (error) {
      console.error('TERMINAI update ArkWeb activity failed: ' + JSON.stringify(error));
    }
  }

  onActiveChanged(): void {
    this.updateRendererActivity();
    if (!this.active) {
      this.clearLiveWriteWatchdog();
      this.clearReplayWatchdog();
      this.clearRendererHeartbeat();
      this.clearRendererUnresponsiveTimer();
      return;
    }
    if (this.rendererReloadNeeded) {
      this.rendererReloadNeeded = false;
      this.rendererReloadAttempts = 0;
      this.rendererUnavailable = false;
      this.scheduleRendererReload();
      return;
    }
    if (this.pageReady) {
      if (this.styleDirty) {
        this.pushStyle();
      }
      if (this.scrollbackDirty) {
        this.onScrollbackChanged();
      }
      // Hidden pages can be frozen by ArkWeb, so a port handshake may not have
      // completed. Rebuild only a port that is not ready; preserve a healthy
      // xterm buffer and its incremental output position.
      if (!this.outputPortReady && !this.outputPortRetryScheduled) {
        if (!this.initializeOutputPort()) {
          this.scheduleOutputPortRecovery();
        }
      }
      // A hidden ArkWeb can pause JavaScript, but its xterm buffer is still
      // valid. Keep the output accumulated while hidden and append only that
      // delta instead of resetting and replaying the entire PTY history.
      this.scheduleTerminalRender(0);
      if (this.replayInFlight) {
        this.watchReplayProgress(this.replayToken, this.replayProgress,
          this.outputPortGeneration);
      }
      if (this.liveWriteInFlight) {
        this.watchLiveWriteCompletion(this.liveWriteGeneration);
      }
      this.scheduleTerminalFocus();
      this.scheduleRendererHeartbeat();
    }
  }

  private queueTerminalOutput(_data: string): void {
    if (!this.pageReady || !this.outputPortReady) {
      this.replayNeeded = true;
      return;
    }
    // Visibility.Hidden may freeze ArkWeb. Do not start a write that cannot
    // acknowledge; TerminalSession already keeps the authoritative history.
    if (this.active) {
      this.scheduleTerminalRender();
    }
  }

  private scheduleTerminalRender(delay: number = RENDER_BATCH_DELAY): void {
    if (this.renderScheduled || !this.active || !this.pageReady || !this.outputPortReady) {
      return;
    }
    this.renderScheduled = true;
    setTimeout(() => {
      this.renderScheduled = false;
      this.flushTerminalRender();
    }, delay);
  }

  private clearLiveWriteWatchdog(): void {
    if (this.liveWriteWatchdogTimer >= 0) {
      clearTimeout(this.liveWriteWatchdogTimer);
      this.liveWriteWatchdogTimer = -1;
    }
  }

  private clearReplayWatchdog(): void {
    if (this.replayWatchdogTimer >= 0) {
      clearTimeout(this.replayWatchdogTimer);
      this.replayWatchdogTimer = -1;
    }
  }

  private clearRendererHeartbeat(): void {
    if (this.rendererHeartbeatTimer >= 0) {
      clearTimeout(this.rendererHeartbeatTimer);
      this.rendererHeartbeatTimer = -1;
    }
    if (this.rendererHeartbeatTimeoutTimer >= 0) {
      clearTimeout(this.rendererHeartbeatTimeoutTimer);
      this.rendererHeartbeatTimeoutTimer = -1;
    }
    this.rendererHeartbeatAwaiting = false;
  }

  private clearRendererUnresponsiveTimer(): void {
    if (this.rendererUnresponsiveTimer >= 0) {
      clearTimeout(this.rendererUnresponsiveTimer);
      this.rendererUnresponsiveTimer = -1;
    }
  }

  private clearCheckpointTimer(): void {
    if (this.checkpointTimer >= 0) {
      clearTimeout(this.checkpointTimer);
      this.checkpointTimer = -1;
    }
  }

  private scheduleTerminalCheckpoint(): void {
    this.clearCheckpointTimer();
    if (!this.active || !this.pageReady || !this.outputPortReady || this.session.disposed) {
      return;
    }
    this.checkpointTimer = setTimeout(() => {
      this.checkpointTimer = -1;
      if (!this.active || !this.pageReady || !this.outputPortReady || this.session.disposed) {
        return;
      }
      if (this.liveWriteInFlight || this.replayInFlight ||
        this.renderedCursor < this.session.outputCursor()) {
        this.scheduleTerminalCheckpoint();
        return;
      }
      this.sendOutputMessage(OUTPUT_MESSAGE_CHECKPOINT_REQUEST, this.renderedCursor.toString());
    }, TERMINAL_CHECKPOINT_DELAY);
  }

  private markRendererResponsive(): void {
    if (this.rendererHeartbeatTimeoutTimer >= 0) {
      clearTimeout(this.rendererHeartbeatTimeoutTimer);
      this.rendererHeartbeatTimeoutTimer = -1;
    }
    this.rendererHeartbeatAwaiting = false;
    this.scheduleRendererHeartbeat();
  }

  private scheduleRendererHeartbeat(delay: number = RENDERER_HEARTBEAT_INTERVAL): void {
    if (this.rendererHeartbeatTimer >= 0) {
      clearTimeout(this.rendererHeartbeatTimer);
      this.rendererHeartbeatTimer = -1;
    }
    if (!this.active || !this.pageReady || !this.outputPortReady || this.session.disposed) {
      return;
    }
    this.rendererHeartbeatTimer = setTimeout(() => {
      this.rendererHeartbeatTimer = -1;
      if (!this.active || !this.pageReady || !this.outputPortReady || this.session.disposed) {
        return;
      }
      // Live/replay acknowledgements already prove renderer health. Avoid adding
      // a heartbeat message while xterm is applying a large output batch.
      if (this.liveWriteInFlight || this.replayInFlight) {
        this.scheduleRendererHeartbeat(1500);
        return;
      }
      this.rendererHeartbeatGeneration++;
      const generation = this.rendererHeartbeatGeneration;
      this.rendererHeartbeatAwaiting = true;
      if (!this.sendOutputMessage(OUTPUT_MESSAGE_HEARTBEAT, generation.toString())) {
        this.rendererHeartbeatAwaiting = false;
        return;
      }
      if (this.rendererHeartbeatTimeoutTimer >= 0) {
        clearTimeout(this.rendererHeartbeatTimeoutTimer);
      }
      this.rendererHeartbeatTimeoutTimer = setTimeout(() => {
        this.rendererHeartbeatTimeoutTimer = -1;
        if (this.active && this.pageReady && this.rendererHeartbeatAwaiting &&
          this.rendererHeartbeatGeneration === generation) {
          this.handleRendererFailure('终端渲染器心跳超时');
        }
      }, RENDERER_HEARTBEAT_TIMEOUT);
    }, delay);
  }

  private handleRendererNotResponding(reason: string): void {
    if (!this.active || this.rendererUnresponsiveTimer >= 0) {
      return;
    }
    this.rendererUnresponsiveTimer = setTimeout(() => {
      this.rendererUnresponsiveTimer = -1;
      if (this.active && this.pageReady) {
        this.handleRendererFailure(reason);
      }
    }, RENDERER_UNRESPONSIVE_GRACE);
  }

  private closeOutputPort(): void {
    this.clearLiveWriteWatchdog();
    this.clearReplayWatchdog();
    this.clearRendererHeartbeat();
    this.clearCheckpointTimer();
    if (this.outputPort !== null) {
      try {
        this.outputPort.close();
      } catch (error) {
        console.error('TERMINAI close output port failed: ' + JSON.stringify(error));
      }
    }
    this.outputPort = null;
    this.outputPorts = [];
    this.outputPortReady = false;
    this.outputPortGeneration++;
    this.replayInFlight = false;
    this.replayHistory = '';
    this.replayOffset = 0;
    this.replayToken++;
    this.replayProgress = 0;
    this.replayTargetCursor = this.renderedCursor;
    this.liveWriteInFlight = false;
    this.liveWriteEndCursor = this.renderedCursor;
    this.liveWriteGeneration++;
  }

  private handleOutputPortMessage(message: webview.WebMessage): void {
    if (message === 'P') {
      this.outputPortReady = true;
      this.outputPortRetryCount = 0;
      this.replayNeeded = true;
      this.scheduleTerminalRender(0);
      this.scheduleRendererHeartbeat();
      return;
    }
    if (typeof message !== 'string') {
      return;
    }
    if (message === 'R' + this.replayToken.toString() && this.replayInFlight) {
      this.clearReplayWatchdog();
      this.markRendererResponsive();
      this.replayProgress++;
      this.scheduleReplayChunk();
      return;
    }
    if (message === 'H' + this.replayToken.toString() && this.replayInFlight) {
      this.clearReplayWatchdog();
      this.markRendererResponsive();
      this.replayInFlight = false;
      this.renderedCursor = Math.max(this.renderedCursor, this.replayTargetCursor);
      this.replayHistory = '';
      this.replayOffset = 0;
      this.scheduleTerminalRender(0);
      this.scheduleTerminalCheckpoint();
      return;
    }
    if (message === 'q' + this.rendererHeartbeatGeneration.toString() &&
      this.rendererHeartbeatAwaiting) {
      this.markRendererResponsive();
      return;
    }
    if (message.startsWith('C')) {
      const separator = message.indexOf('\n');
      if (separator > 1) {
        const cursor = parseInt(message.substring(1, separator));
        if (cursor >= 0) {
          this.session.recordOutputCheckpoint(cursor, message.substring(separator + 1));
        }
      }
      return;
    }
    if (!this.liveWriteInFlight ||
      message !== 'A' + this.liveWriteGeneration.toString()) {
      return;
    }
    this.clearLiveWriteWatchdog();
    this.markRendererResponsive();
    this.liveWriteInFlight = false;
    this.renderedCursor = Math.max(this.renderedCursor, this.liveWriteEndCursor);
    this.scheduleTerminalRender(0);
    this.scheduleTerminalCheckpoint();
  }

  private initializeOutputPort(): boolean {
    this.closeOutputPort();
    const portGeneration = this.outputPortGeneration;
    try {
      const ports = this.controller.createWebMessagePorts();
      if (ports.length < 2) {
        console.error('TERMINAI output port creation returned too few ports');
        return false;
      }
      // ArkWeb requires a receiver to be registered before this endpoint can
      // send. Terminal input still uses the existing JavaScript proxy.
      ports[1].onMessageEvent((message: webview.WebMessage) => {
        this.handleOutputPortMessage(message);
      });
      this.controller.postMessage('__terminai_output_port__', [ports[0]], '*');
      this.outputPorts = ports;
      this.outputPort = ports[1];
      // Wait for the HTML side to acknowledge the transferred endpoint. A
      // successfully created native port does not prove that the renderer has
      // received it; treating it as ready can leave only a blinking cursor.
      setTimeout(() => {
        if (this.pageReady && this.outputPortGeneration === portGeneration &&
          !this.outputPortReady) {
          if (!this.active) {
            return;
          }
          console.error('TERMINAI terminal output port handshake timed out');
          this.closeOutputPort();
          this.scheduleOutputPortRecovery();
        }
      }, 1500);
      return true;
    } catch (error) {
      console.error('TERMINAI initialize output port failed: ' + JSON.stringify(error));
      this.closeOutputPort();
      return false;
    }
  }

  private sendOutputMessage(kind: string, data: string = ''): boolean {
    if (!this.outputPortReady || this.outputPort === null) {
      return false;
    }
    try {
      this.outputPort.postMessageEvent(kind + data);
      return true;
    } catch (error) {
      console.error('TERMINAI output port send failed: ' + JSON.stringify(error));
      this.closeOutputPort();
      this.scheduleOutputPortRecovery();
      return false;
    }
  }

  private scheduleOutputPortRecovery(): void {
    if (!this.active || !this.pageReady || this.outputPortRetryScheduled) {
      return;
    }
    if (this.outputPortRetryCount >= 3) {
      this.handleRendererFailure('终端输出通道连续 3 次建立失败');
      return;
    }
    this.outputPortRetryScheduled = true;
    this.outputPortRetryCount++;
    const delay = this.outputPortRetryCount * 100;
    setTimeout(() => {
      this.outputPortRetryScheduled = false;
      if (!this.active || !this.pageReady) {
        return;
      }
      if (this.initializeOutputPort()) {
        this.replayNeeded = true;
        this.scheduleTerminalRender();
      } else {
        this.scheduleOutputPortRecovery();
      }
    }, delay);
  }

  private handleRendererFailure(reason: string): void {
    this.clearRendererUnresponsiveTimer();
    this.pageReady = false;
    this.renderScheduled = false;
    this.replayNeeded = true;
    this.outputPortRetryScheduled = false;
    this.closeOutputPort();
    this.rendererFailureReason = reason;
    console.error('TERMINAI terminal renderer unavailable: ' + reason);
    if (!this.active) {
      this.rendererReloadNeeded = true;
      return;
    }
    this.scheduleRendererReload();
  }

  private scheduleRendererReload(): void {
    if (this.rendererReloadScheduled || this.session.disposed) {
      return;
    }
    if (this.rendererReloadAttempts >= 3) {
      // Do not leave an invisible Web as the only UI. Preserve the PTY and
      // expose an explicit recovery action; switching away/back also retries.
      this.rendererUnavailable = true;
      this.rendererReloadNeeded = true;
      return;
    }
    this.rendererReloadScheduled = true;
    this.rendererReloadAttempts++;
    const delay = this.rendererReloadAttempts * 150;
    setTimeout(() => {
      this.rendererReloadScheduled = false;
      if (this.session.disposed) {
        return;
      }
      if (!this.active) {
        this.rendererReloadNeeded = true;
        return;
      }
      try {
        this.controller.refresh();
      } catch (error) {
        console.error('TERMINAI terminal renderer reload failed: ' + JSON.stringify(error));
        this.scheduleRendererReload();
      }
    }, delay);
  }

  private flushTerminalRender(): void {
    if (!this.active || !this.pageReady || !this.outputPortReady || this.replayInFlight ||
      this.liveWriteInFlight) {
      return;
    }
    if (this.replayNeeded) {
      const snapshot: TerminalOutputSnapshot = this.session.outputSnapshot();
      this.replayHistory = snapshot.data;
      this.replayOffset = 0;
      this.replayTargetCursor = snapshot.endCursor;
      this.replayToken++;
      this.replayProgress = 0;
      const token = this.replayToken;
      this.replayInFlight = true;
      if (!this.sendOutputMessage(OUTPUT_MESSAGE_REPLAY_BEGIN, token.toString())) {
        this.replayInFlight = false;
        return;
      }
      this.replayNeeded = false;
      this.scheduleReplayChunk();
      this.watchReplayProgress(token, this.replayProgress, this.outputPortGeneration);
      return;
    }
    const output: TerminalOutputSlice = this.session.outputAfter(this.renderedCursor,
      OUTPUT_MESSAGE_CHUNK);
    if (output.cursorWasTrimmed) {
      // This renderer fell farther behind than the bounded session ring. One
      // checkpoint replay is required; never fabricate a partial ANSI stream.
      this.replayNeeded = true;
      this.scheduleTerminalRender(0);
      return;
    }
    if (output.data.length === 0) {
      return;
    }
    this.liveWriteGeneration++;
    const generation = this.liveWriteGeneration;
    if (!this.sendOutputMessage(OUTPUT_MESSAGE_LIVE,
      generation.toString() + '\n' + output.data)) {
      // Session history is authoritative. Rebuild the renderer if a port is
      // recreated rather than silently losing this output burst.
      this.replayNeeded = true;
      return;
    }
    this.liveWriteEndCursor = output.endCursor;
    this.liveWriteInFlight = true;
    this.watchLiveWriteCompletion(generation);
  }

  private scheduleReplayChunk(): void {
    const token = this.replayToken;
    const portGeneration = this.outputPortGeneration;
    setTimeout(() => {
      if (!this.active || !this.pageReady || !this.outputPortReady ||
        !this.replayInFlight || this.replayToken !== token ||
        this.outputPortGeneration !== portGeneration) {
        return;
      }
      if (this.replayOffset >= this.replayHistory.length) {
        if (!this.sendOutputMessage(OUTPUT_MESSAGE_REPLAY_END, token.toString())) {
          this.replayNeeded = true;
          return;
        }
        this.watchReplayProgress(token, this.replayProgress, portGeneration);
        return;
      }
      const end = Math.min(this.replayOffset + OUTPUT_MESSAGE_CHUNK, this.replayHistory.length);
      const output = this.replayHistory.substring(this.replayOffset, end);
      if (!this.sendOutputMessage(OUTPUT_MESSAGE_REPLAY_CHUNK,
        token.toString() + '\n' + output)) {
        this.replayNeeded = true;
        return;
      }
      this.replayOffset = end;
      this.watchReplayProgress(token, this.replayProgress, portGeneration);
    }, 0);
  }

  private watchReplayProgress(token: number, progress: number, portGeneration: number): void {
    this.clearReplayWatchdog();
    this.replayWatchdogTimer = setTimeout(() => {
      this.replayWatchdogTimer = -1;
      if (this.active && this.pageReady && this.outputPortGeneration === portGeneration &&
        this.replayInFlight && this.replayToken === token && this.replayProgress === progress) {
        this.handleRendererFailure('终端历史恢复连续 8 秒无进展');
      }
    }, REPLAY_PROGRESS_TIMEOUT);
  }

  private retryRenderer(): void {
    if (this.session.disposed) {
      return;
    }
    this.rendererUnavailable = false;
    this.rendererFailureReason = '';
    this.rendererReloadNeeded = false;
    this.rendererReloadAttempts = 0;
    this.pageReady = false;
    this.closeOutputPort();
    this.scheduleRendererReload();
  }

  private watchLiveWriteCompletion(generation: number): void {
    this.clearLiveWriteWatchdog();
    this.liveWriteWatchdogTimer = setTimeout(() => {
      this.liveWriteWatchdogTimer = -1;
      if (this.active && this.liveWriteInFlight && this.liveWriteGeneration === generation &&
        this.pageReady) {
        this.handleRendererFailure('终端输出通道 12 秒内未确认');
      }
    }, 12000);
  }

  aboutToAppear(): void {
    this.terminalBridge();
    this.outputOwner = this.session;
    this.outputOwner.onOutput = this.outputHandler;
  }


  aboutToDisappear(): void {
    this.clearRendererUnresponsiveTimer();
    this.pageReady = false;
    this.replayNeeded = true;
    this.renderScheduled = false;
    this.outputPortRetryScheduled = false;
    this.rendererReloadScheduled = false;
    this.closeOutputPort();
    // A replacement view may already own this session while ArkUI disposes
    // the old Web node. Never let the old node detach the new output route.
    if (this.outputOwner !== null && this.outputOwner.onOutput === this.outputHandler) {
      this.outputOwner.onOutput = () => {};
    }
    this.outputOwner = null;
  }
  private async createNativeSession(cols: number, rows: number, nativeCwd: string,
    nativeCommand: string): Promise<void> {
    const remote = this.session.sshTarget.length > 0;
    const secret = new SshSecretValue(remote ? await SshCredentialStore.load(this.session.deviceId) : '');
    let id = -1;
    if (this.session.disposed) {
      secret.value = '';
      this.session.startInProgress = false;
      return;
    }
    try {
      if (remote) {
        id = libterminal.createSessionWithSecret(cols, rows, nativeCwd, nativeCommand, secret.value,
          (ev: SessionEvent) => {
            this.session.onNativeEvent(ev);
          });
      } else {
        id = libterminal.createSession(cols, rows, nativeCwd, nativeCommand,
          (ev: SessionEvent) => {
            this.session.onNativeEvent(ev);
          });
      }
      secret.value = '';
    } catch (e) {
      secret.value = '';
      this.session.startInProgress = false;
      console.error('TERMINAI native session creation threw: ' + JSON.stringify(e));
      throw new Error('无法创建终端会话');
    }
    if (id <= 0) {
      this.session.startInProgress = false;
      throw new Error('原生终端返回了无效会话');
    }
    this.session.id = id;
    this.session.alive = true;
    this.session.nativeStartCompleted = true;
    this.session.startInProgress = false;
    console.info('TERMINAI startNativeSession: session created id=' + id);
    if (this.active) {
      this.scheduleTerminalFocus();
    }
  }

  private createNativeSessionAtSize(cols: number, rows: number): void {
    if (this.session.disposed || this.session.nativeStartCompleted) {
      this.session.startInProgress = false;
      return;
    }
    try {
      const nativeCwd = this.session.sshTarget.length > 0 ? '~' : this.session.cwd;
      const nativeCommand = this.session.sshTarget.length > 0 ? this.remoteStartCommand() :
        this.localStartCommand();
      this.createNativeSession(cols, rows, nativeCwd, nativeCommand)
        .catch((error: Error) => {
          this.session.startInProgress = false;
          console.error('TERMINAI session create failed: ' + error.message);
        });
    } catch (error) {
      this.session.startInProgress = false;
      console.error('TERMINAI session command failed: ' + JSON.stringify(error));
    }
  }

  private startNativeSession(): void {
    if (this.session.id > 0 || this.session.startInProgress ||
      this.session.nativeStartCompleted || this.session.disposed) {
      return;
    }
    this.session.startInProgress = true;
    // Ask the page for the real terminal size, then spawn the shell.
    console.info('TERMINAI startNativeSession: querying page size');
    this.controller.runJavaScript('window.getTermSize()')
      .then((sizeStr: string) => {
        if (this.session.disposed || this.session.nativeStartCompleted) {
          this.session.startInProgress = false;
          return;
        }
        let cols = 80;
        let rows = 24;
        // runJavaScript returns a JSON-encoded string (may include quotes)
        const cleaned = sizeStr.replace(/"/g, '');
        const parts = cleaned.split(',');
        if (parts.length === 2) {
          const c = parseInt(parts[0]);
          const r = parseInt(parts[1]);
          if (c > 0 && r > 0) {
            cols = c;
            rows = r;
          }
        }
        console.info('TERMINAI startNativeSession: page size=' + sizeStr + ' -> ' + cols + 'x' + rows);
        this.createNativeSessionAtSize(cols, rows);
      })
      .catch((e: Error) => {
        // A page can reject this query while recovering. Starting at a safe
        // default size is preferable to leaving a permanently blank session.
        console.error('TERMINAI getTermSize failed, using 80x24: ' + e.message);
        this.createNativeSessionAtSize(80, 24);
      });
  }

  /** Read clipboard only after PasteButton grants this user-initiated operation. */
  private pasteFromSecurityButton(): void {
    pasteboard.getSystemPasteboard().getData()
      .then((pasteData: pasteboard.PasteData) => {
        const text = pasteData.getPrimaryText();
        if (text.length === 0) {
          return;
        }
        this.controller.runJavaScript('window.termPaste(' + JSON.stringify(text) + '); window.termFocus()')
          .catch((error: Error) => console.error('TERMINAI context paste failed: ' + error.message));
      })
      .catch((error: Error) => console.error('TERMINAI clipboard read failed: ' + error.message));
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Web({ src: $rawfile('terminal/terminal.html'), controller: this.controller })
        .javaScriptProxy({
          object: this.terminalBridge(),
          name: 'ohosBridge',
          methodList: ['onTermInput', 'onTermResize', 'onTermSnapshot', 'onTermTitle'],
          controller: this.controller
        })
        .domStorageAccess(true)
        .onInterceptKeyEvent((event: KeyEvent) => this.interceptKeyEvent(event))
        .onPageEnd(() => {
          console.info('TERMINAI onPageEnd fired');
          const recoveringPage = this.pageLoadCount > 0 || this.session.nativeStartCompleted ||
            this.session.outputVersion > 0;
          this.pageLoadCount++;
          this.pageReady = true;
          this.updateRendererActivity();
          this.rendererUnavailable = false;
          this.rendererFailureReason = '';
          this.rendererReloadNeeded = false;
          this.rendererReloadScheduled = false;
          const loadedPage = this.pageLoadCount;
          setTimeout(() => {
            if (this.pageReady && this.pageLoadCount === loadedPage) {
              this.rendererReloadAttempts = 0;
            }
          }, 5000);
          this.renderScheduled = false;
          this.replayNeeded = recoveringPage;
          this.outputPortRetryCount = 0;
          if (!this.initializeOutputPort()) {
            this.scheduleOutputPortRecovery();
          }
          this.pushStyle();
          this.onScrollbackChanged();
          if (this.session.id <= 0 && !this.session.nativeStartCompleted) {
            this.startNativeSession();
          } else {
            this.controller.runJavaScript('window.termFitNow()').catch(() => {});
          }
          this.scheduleTerminalRender();
          this.scheduleRendererHeartbeat();
          if (this.active) this.scheduleTerminalFocus();
        })
        .onErrorReceive((e) => {
          if (!e.request.isMainFrame()) {
            console.error('TERMINAI terminal subresource error: ' + JSON.stringify(e));
            return;
          }
          this.handleRendererFailure('主页面加载失败 ' + JSON.stringify(e));
        })
        .onRenderExited((event) => {
          if (event) {
            this.handleRendererFailure('ArkWeb 渲染进程退出，原因 ' + event.renderExitReason.toString());
          } else {
            this.handleRendererFailure('ArkWeb 渲染进程退出');
          }
        })
        .onRenderProcessNotResponding((data: RenderProcessNotRespondingData) => {
          this.handleRendererNotResponding('ArkWeb 渲染进程无响应，原因 ' + data.reason.toString());
        })
        .onRenderProcessResponding(() => {
          this.clearRendererUnresponsiveTimer();
          this.markRendererResponsive();
        })
        .onConsole((event) => {
          console.info('TERMINAI web console: ' + event.message.getMessage());
          return true;
        })
        .width('100%')
        .id(this.terminalFocusId())
        .focusable(true)
        .focusOnTouch(true)
        .onVisibleAreaChange([1.0], (isVisible: boolean) => {
          if (isVisible && this.active) this.scheduleTerminalFocus();
        })
        .height('100%')
        .backgroundColor(Theme.terminalBg(this.isDark))
        .bindContextMenu(this.termMenuBuilder, ResponseType.RightClick)

      if (this.rendererUnavailable) {
        Column() {
          Text('终端显示暂时不可用')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
          Text(this.rendererFailureReason)
            .fontSize(12)
            .fontColor(Theme.tertiary(this.isDark))
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .margin({ top: 7, bottom: 14 })
          Button('重新加载终端')
            .height(34)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor(Theme.accent(this.isDark))
            .borderRadius(8)
            .onClick(() => { this.retryRenderer(); })
        }
        .width(320)
        .padding({ left: 22, right: 22, top: 20, bottom: 20 })
        .backgroundColor(Theme.card(this.isDark))
        .border({ width: 1, color: Theme.border(this.isDark), radius: 12 })
        .borderRadius(12)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.terminalBg(this.isDark))
  }

  @Builder
  termMenuBuilder() {
    Menu() {
      MenuItem({ content: '复制' })
        .height(36)
        .onClick(() => {
          this.controller.runJavaScript('window.termCopySelection()').catch(() => {});
        })
      MenuItem(this.pasteMenuItemBuilder)
        .height(36)
        .padding(0)
      MenuItem({ content: '全选' })
        .height(36)
        .onClick(() => {
          this.controller.runJavaScript('window.termSelectAll()').catch(() => {});
        })
    }
    .width(140)
    .font({ size: 14 })
    .fontColor(Theme.text(this.isDark))
    .backgroundColor(Theme.card(this.isDark))
    .borderRadius(8)
  }

  @Builder
  pasteMenuItemBuilder() {
    PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
      .fontSize(14)
      .fontWeight(FontWeight.Normal)
      .fontColor(Theme.text(this.isDark))
      .backgroundColor(Theme.card(this.isDark))
      .borderWidth(0)
      .borderRadius(4)
      .padding({ left: 12, right: 12, top: 0, bottom: 0 })
      .width('100%')
      .height(36)
      .align(Alignment.Start)
      .maxLines(1)
      .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
        if (result === PasteButtonOnClickResult.SUCCESS) {
          this.pasteFromSecurityButton();
        } else {
          console.error('TERMINAI clipboard temporary authorization failed');
        }
      })
  }
}
