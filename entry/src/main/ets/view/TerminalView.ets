// Web-based terminal view: xterm.js inside ArkWeb, bridged to native PTY.
import libterminal from 'libterminal.so';
import { webview } from '@kit.ArkWeb';
import { pasteboard } from '@kit.BasicServicesKit';
import { TerminalSession, SessionEvent } from '../model/TerminalSession';
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
const RENDER_QUEUE_LIMIT = 1024 * 1024;
const OUTPUT_MESSAGE_CHUNK = 64 * 1024;
const OUTPUT_MESSAGE_LIVE = 'D';
const OUTPUT_MESSAGE_REPLAY_BEGIN = 'B';
const OUTPUT_MESSAGE_REPLAY_CHUNK = 'R';
const OUTPUT_MESSAGE_REPLAY_END = 'E';

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
  private ctrlDown: boolean = false;
  private shiftDown: boolean = false;
  private interceptedShortcutKeyCode: number = 0;
  private pageReady: boolean = false;
  private renderQueue: string = '';
  private renderScheduled: boolean = false;
  private replayNeeded: boolean = true;
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
  private liveWriteInFlight: boolean = false;
  private liveWriteGeneration: number = 0;

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
    const bold = this.fontBold ? 'true' : 'false';
    const dark = this.isDark ? 'true' : 'false';
    const cursor = JSON.stringify(this.cursorStyle);
    const scheme = JSON.stringify(this.colorScheme);
    this.controller.runJavaScript('window.termSetStyle(' + this.fontSize + ', ' + bold + ', '
      + dark + ', ' + (this.fontFamily.length > 0 ? JSON.stringify(this.fontFamily) : 'null')
      + ', ' + cursor + ', ' + scheme + ', ' + this.lineHeight + ')')
      .catch(() => {});
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
    this.controller.runJavaScript('window.termSetScrollback(' + this.scrollback + ')').catch(() => {});
  }

  onActiveChanged(): void {
    if (!this.active) {
      return;
    }
    if (this.rendererReloadNeeded) {
      this.rendererReloadNeeded = false;
      this.scheduleRendererReload();
      return;
    }
    if (this.pageReady) {
      // Hidden pages are frozen by ArkWeb: the output-port handshake or its
      // write acknowledgements may never have completed. Rebuild a port that
      // is not ready yet; either way force one authoritative history replay.
      if (!this.outputPortReady && !this.outputPortRetryScheduled) {
        if (!this.initializeOutputPort()) {
          this.scheduleOutputPortRecovery();
        }
      } else if (this.outputPortReady) {
        this.liveWriteInFlight = false;
        this.replayNeeded = true;
      }
      this.scheduleTerminalRender();
      this.controller.runJavaScript('window.termFitNow(); window.termFocus()').catch(() => {});
    }
  }

  private queueTerminalOutput(data: string): void {
    if (!this.pageReady || !this.outputPortReady) {
      this.renderQueue = '';
      this.replayNeeded = true;
      return;
    }
    if (!this.replayNeeded) {
      this.renderQueue += data;
      if (this.renderQueue.length > RENDER_QUEUE_LIMIT) {
        this.renderQueue = '';
        this.replayNeeded = true;
      }
    }
    this.scheduleTerminalRender();
  }

  private scheduleTerminalRender(): void {
    if (this.renderScheduled || !this.pageReady || !this.outputPortReady) {
      return;
    }
    this.renderScheduled = true;
    setTimeout(() => {
      this.renderScheduled = false;
      this.flushTerminalRender();
    }, RENDER_BATCH_DELAY);
  }

  private closeOutputPort(): void {
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
    this.liveWriteInFlight = false;
    this.liveWriteGeneration++;
  }

  private handleOutputPortMessage(message: webview.WebMessage): void {
    if (message === 'P') {
      this.outputPortReady = true;
      this.outputPortRetryCount = 0;
      this.replayNeeded = true;
      this.scheduleTerminalRender();
      return;
    }
    if (message === 'H') {
      this.replayInFlight = false;
      this.scheduleTerminalRender();
      return;
    }
    if (typeof message !== 'string' || !this.liveWriteInFlight ||
      message !== 'A' + this.liveWriteGeneration.toString()) {
      return;
    }
    this.liveWriteInFlight = false;
    this.scheduleTerminalRender();
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
    if (!this.pageReady || this.outputPortRetryScheduled) {
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
      if (!this.pageReady) {
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
    this.pageReady = false;
    this.renderQueue = '';
    this.renderScheduled = false;
    this.replayNeeded = true;
    this.outputPortRetryScheduled = false;
    this.closeOutputPort();
    console.error('TERMINAI terminal renderer unavailable: ' + reason);
    if (!this.active) {
      this.rendererReloadNeeded = true;
      return;
    }
    this.scheduleRendererReload();
  }

  private scheduleRendererReload(): void {
    if (this.rendererReloadScheduled || this.rendererReloadAttempts >= 3 ||
      this.session.disposed) {
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
    if (!this.pageReady || !this.outputPortReady || this.replayInFlight ||
      this.liveWriteInFlight) {
      return;
    }
    if (this.replayNeeded) {
      const history = this.session.outputHistoryText();
      this.renderQueue = '';
      if (!this.sendOutputMessage(OUTPUT_MESSAGE_REPLAY_BEGIN)) {
        return;
      }
      let offset = 0;
      while (offset < history.length) {
        const end = Math.min(offset + OUTPUT_MESSAGE_CHUNK, history.length);
        if (!this.sendOutputMessage(OUTPUT_MESSAGE_REPLAY_CHUNK, history.substring(offset, end))) {
          this.replayNeeded = true;
          return;
        }
        offset = end;
      }
      if (!this.sendOutputMessage(OUTPUT_MESSAGE_REPLAY_END)) {
        this.replayNeeded = true;
        return;
      }
      this.replayNeeded = false;
      this.replayInFlight = true;
      const portGeneration = this.outputPortGeneration;
      setTimeout(() => {
        if (this.pageReady && this.outputPortGeneration === portGeneration &&
          this.replayInFlight) {
          this.handleRendererFailure('终端历史恢复 12 秒内未完成');
        }
      }, 12000);
      return;
    }
    if (this.renderQueue.length === 0) {
      return;
    }
    const end = Math.min(OUTPUT_MESSAGE_CHUNK, this.renderQueue.length);
    const output = this.renderQueue.substring(0, end);
    this.liveWriteGeneration++;
    const generation = this.liveWriteGeneration;
    if (!this.sendOutputMessage(OUTPUT_MESSAGE_LIVE, generation.toString() + '\n' + output)) {
      // Session history is authoritative. Rebuild the renderer if a port is
      // recreated rather than silently losing this output burst.
      this.replayNeeded = true;
      return;
    }
    this.renderQueue = this.renderQueue.substring(end);
    this.liveWriteInFlight = true;
    setTimeout(() => {
      if (this.liveWriteInFlight && this.liveWriteGeneration === generation && this.pageReady) {
        this.handleRendererFailure('终端输出通道 12 秒内未确认');
      }
    }, 12000);
  }

  aboutToAppear(): void {
    this.session.onOutput = (data: string) => {
      this.queueTerminalOutput(data);
    };
  }


  aboutToDisappear(): void {
    this.pageReady = false;
    this.renderQueue = '';
    this.replayNeeded = true;
    this.renderScheduled = false;
    this.outputPortRetryScheduled = false;
    this.rendererReloadScheduled = false;
    this.closeOutputPort();
    this.session.onOutput = () => {};
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
            this.onEvent(ev);
          });
      } else {
        id = libterminal.createSession(cols, rows, nativeCwd, nativeCommand,
          (ev: SessionEvent) => {
            this.onEvent(ev);
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
      this.controller.runJavaScript('window.termFocus()').catch(() => {});
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
    Web({ src: $rawfile('terminal/terminal.html'), controller: this.controller })
      .javaScriptProxy({
        object: new TermBridge(this.session),
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
        this.rendererReloadNeeded = false;
        this.rendererReloadScheduled = false;
        const loadedPage = this.pageLoadCount;
        setTimeout(() => {
          if (this.pageReady && this.pageLoadCount === loadedPage) {
            this.rendererReloadAttempts = 0;
          }
        }, 5000);
        this.renderQueue = '';
        this.renderScheduled = false;
        this.replayNeeded = recoveringPage;
        this.outputPortRetryCount = 0;
        if (!this.initializeOutputPort()) {
          this.scheduleOutputPortRecovery();
        }
        this.pushStyle();
        if (this.session.id <= 0 && !this.session.nativeStartCompleted) {
          this.startNativeSession();
        } else {
          this.controller.runJavaScript('window.termFitNow()').catch(() => {});
        }
        this.scheduleTerminalRender();
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
      .onConsole((event) => {
        console.info('TERMINAI web console: ' + event.message.getMessage());
        return true;
      })
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.terminalBg(this.isDark))
      .bindContextMenu(this.termMenuBuilder, ResponseType.RightClick)
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
