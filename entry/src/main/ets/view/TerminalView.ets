// Web-based terminal view: xterm.js inside ArkWeb, bridged to native PTY.
import libterminal from 'libterminal.so';
import { webview } from '@kit.ArkWeb';
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
      console.info('TERMINAI bridge onTermInput len=' + data.length + ' ok=' + ok);
    } else {
      console.info('TERMINAI bridge onTermInput ignored (no session)');
    }
  }

  onTermSnapshot(text: string): void {
    this.session.recordScreen(text);
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
    const cwd = this.session.cwd;
    if (cwd.length === 0 || cwd === '~') {
      return 'cd -- "$HOME"';
    }
    if (cwd.startsWith('~/')) {
      return 'cd -- "$HOME/' + cwd.substring(2) + '"';
    }
    return 'cd -- ' + this.shellQuote(cwd);
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
    let remoteScript = changeDirectory + ' && ' + directoryMonitor;
    if (this.session.cmd.length > 0) {
      // Clear the connection/auth banner once, then run the agent inside the
      // remote login shell so its PATH matches an interactive login.
      remoteScript += 'clear; "${SHELL:-/bin/sh}" -lc ' + this.shellQuote(this.session.cmd) +
        '; printf \'\\033]777;terminai-agent-returned\\007\'; exec "${SHELL:-/bin/sh}" -l';
    } else {
      remoteScript += 'clear; exec "${SHELL:-/bin/sh}" -l';
    }
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
      '); printf \'\\033]777;terminai-agent-returned\\007\'; exec /usr/bin/zsh -l';
  }

  onStyleChanged(): void {
    this.pushStyle();
  }

  onScrollbackChanged(): void {
    this.controller.runJavaScript('window.termSetScrollback(' + this.scrollback + ')').catch(() => {});
  }

  aboutToAppear(): void {
    // Wire session output → xterm.js
    this.session.onOutput = (data: string) => {
      console.info('TERMINAI view onOutput len=' + data.length);
      this.controller.runJavaScript('window.termWrite(' + JSON.stringify(data) + ')')
        .catch((e: Error) => console.error('TERMINAI runJavaScript failed: ' + e.message));
    };
  }

  private async createNativeSession(cols: number, rows: number, nativeCwd: string,
    nativeCommand: string): Promise<void> {
    const remote = this.session.sshTarget.length > 0;
    const secret = new SshSecretValue(remote ? await SshCredentialStore.load(this.session.deviceId) : '');
    let id = -1;
    try {
      if (remote) {
        id = libterminal.createSessionWithSecret(cols, rows, nativeCwd, nativeCommand, secret.value,
          (ev: SessionEvent) => {
            console.info('TERMINAI native event: kind=' + ev.kind + ' len=' + ev.data.length);
            this.onEvent(ev);
          });
      } else {
        id = libterminal.createSession(cols, rows, nativeCwd, nativeCommand,
          (ev: SessionEvent) => {
            console.info('TERMINAI native event: kind=' + ev.kind + ' len=' + ev.data.length);
            this.onEvent(ev);
          });
      }
      secret.value = '';
    } catch (e) {
      secret.value = '';
      console.error('TERMINAI native session creation threw: ' + JSON.stringify(e));
      throw new Error('无法创建终端会话');
    }
    this.session.id = id;
    this.session.alive = true;
    this.session.termReady = true;
    this.session.flushPending();
    console.info('TERMINAI startNativeSession: session created id=' + id);
    this.controller.runJavaScript('window.termFocus()').catch(() => {});
  }

  private startNativeSession(): void {
    // Ask the page for the real terminal size, then spawn the shell.
    console.info('TERMINAI startNativeSession: querying page size');
    this.controller.runJavaScript('window.getTermSize()')
      .then((sizeStr: string) => {
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
        const nativeCwd = this.session.sshTarget.length > 0 ? '~' : this.session.cwd;
        const nativeCommand = this.session.sshTarget.length > 0 ? this.remoteStartCommand() :
          this.localStartCommand();
        this.createNativeSession(cols, rows, nativeCwd, nativeCommand)
          .catch((error: Error) => console.error('TERMINAI session create failed: ' + error.message));
      })
      .catch((e: Error) => console.error('TERMINAI getTermSize failed: ' + e.message));
  }

  build() {
    Web({ src: $rawfile('terminal/terminal.html'), controller: this.controller })
      .javaScriptProxy({
        object: new TermBridge(this.session),
        name: 'ohosBridge',
        methodList: ['onTermInput', 'onTermResize', 'onTermSnapshot'],
        controller: this.controller
      })
      .domStorageAccess(true)
      .onInterceptKeyEvent((event: KeyEvent) => this.interceptKeyEvent(event))
      .onPageEnd(() => {
        console.info('TERMINAI onPageEnd fired');
        this.session.termReady = true;
        this.pushStyle();
        if (this.session.id <= 0) {
          this.startNativeSession();
        } else {
          // Page reloaded but native session alive: just refit.
          this.controller.runJavaScript('window.termFitNow()').catch(() => {});
        }
      })
      .onErrorReceive((e) => {
        console.error('TERMINAI web error: ' + JSON.stringify(e));
      })
      .onConsole((event) => {
        console.info('TERMINAI web console: ' + event.message.getMessage());
        return true;
      })
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.terminalBg(this.isDark))
  }
}
