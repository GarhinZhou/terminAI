// Main page: sidebar + terminal stack + Ctrl+K palette.
import libterminal from 'libterminal.so';
import { preferences } from '@kit.ArkData';
import { canonicalSessionCwd, TerminalSession, SessionManager, SessionEvent,
  SessionProcessInfo } from '../model/TerminalSession';
import { TerminalView } from '../view/TerminalView';
import { SidebarView } from '../view/SidebarView';
import { SearchView } from '../view/SearchView';
import { NewAgentDialog } from '../view/NewAgentDialog';
import { NewSpaceDialog } from '../view/NewSpaceDialog';
import { SettingsView } from '../view/SettingsView';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { BrandIcon } from '../common/BrandIcon';
import { IconName, UiIcon } from '../common/Icons';
import { SessionNumberBadge } from '../common/SessionNumberBadge';
import { DeviceManagerDialog } from '../view/DeviceManagerDialog';
import { ManagedDevice, decodeDevices, LOCAL_DEVICE_ID, localDevice, normalizedSshTarget } from '../model/ManagedDevice';
import { migrateAgentOverrides } from '../model/AgentOverrides';
import { SshCredentialStore } from '../model/SshCredentialStore';
import { PendingRemoteSession, RemoteAgentInfo, SshConnectionState, SshRuntimeConnection,
  SshSecretValue, encodeConnectionStates, removeRemoteAgents,
  replaceRemoteAgents } from '../model/RemoteSshState';

const SSH_CONNECTED_MARKER = '__TERMINAI_SSH_CONNECTED__';


class RemoteAgentCandidate {
  name: string = '';
  iconKind: string = '';

  constructor(name: string, iconKind: string) {
    this.name = name;
    this.iconKind = iconKind;
  }
}

const DOMAIN = 0x0000;
const KEYCODE_CTRL_LEFT = 2072;
const KEYCODE_CTRL_RIGHT = 2073;
const KEYCODE_SHIFT_LEFT = 2047;
const KEYCODE_SHIFT_RIGHT = 2048;
const KEYCODE_K = 2027;
const KEYCODE_T = 2036;
const KEYCODE_W = 2039;
const KEYCODE_B = 2018;
const KEYCODE_N = 2030;
const KEYCODE_ESCAPE = 2070;
const PREF_NAME = 'terminai_settings';
const PREF_DEFAULT_CWD = 'defaultCwd';
const DEFAULT_CWD = '~';
const LEGACY_HOME_CWD = '/storage/Users/currentUser';
const LEGACY_AICODING_CWD = '/storage/Users/currentUser/AICoding';
const PREF_FONT_SIZE = 'fontSize';
const PREF_FONT_BOLD = 'fontBold';
const PREF_THEME_MODE = 'themeMode';  // "system" | "dark" | "light"
const PREF_ACCENT = 'accent';         // "" = theme default, else hex like #8ab4f8
const PREF_CURSOR_STYLE = 'cursorStyle';   // "block" | "underline" | "bar"
const PREF_COLOR_SCHEME = 'colorScheme';   // "default" | "solarized" | ...
const PREF_SCROLLBACK = 'scrollback';      // lines, default 10000
const PREF_PROGRAM_ORDER = 'programOrder'; // comma-separated program names
const PREF_DEFAULT_PROGRAM = 'defaultProgram'; // program name, "" = zsh
const PREF_NOTIFY_ENABLED = 'notifyEnabled';
const PREF_AUTO_NEW_SESSION = 'autoNewSession';
const PREF_AUTO_CONNECT_SSH = 'autoConnectSsh';   // auto-connect saved SSH hosts on startup
const PREF_RECENT_PATHS = 'recentPaths';   // JSON array, newest first, max 5
const PREF_LINE_HEIGHT = 'lineHeight';
const PREF_FONT_FAMILY = 'fontFamily';
const PREF_AGENT_OVERRIDES = 'agentOverrides';   // JSON {kind: binaryPath}
const PREF_CUSTOM_AGENTS = 'customAgents';       // URI-encoded custom agent records
const PREF_DEVICES = 'sshDevices';                // URI-encoded ManagedDevice records
const PREF_SELECTED_DEVICE = 'selectedDevice';   // empty = all devices
const PREF_REMOTE_AGENTS = 'remoteAgents';       // per-device scanned executable catalog
const PREF_REMOTE_SHELLS = 'remoteShells';        // JSON {deviceId: loginShell}

@Entry
@Component
struct Index {
  @State sessions: TerminalSession[] = [];
  @State currentIdx: number = -1;
  @State sidebarCollapsed: boolean = false;
  @State sidebarWidth: number = 280;
  @State defaultCwd: string = DEFAULT_CWD;
  // Global style state mirrored in AppStorage so every view stays in sync.
  @StorageProp('fontSize') @Watch('onStyleChanged') fontSize: number = 14;
  @StorageProp('fontBold') @Watch('onStyleChanged') fontBold: boolean = false;
  @StorageProp('themeMode') @Watch('onThemeModeChanged') themeMode: string = 'system';
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('accent') @Watch('onStyleChanged') accent: string = '';
  @StorageProp('cursorStyle') @Watch('onStyleChanged') cursorStyle: string = 'block';
  @StorageProp('colorScheme') @Watch('onStyleChanged') colorScheme: string = 'default';
  @StorageProp('scrollback') @Watch('onStyleChanged') scrollback: number = 10000;
  @StorageProp('programOrder') programOrder: string = '';
  @StorageProp('defaultProgram') defaultProgram: string = '';
  @StorageProp('notifyEnabled') @Watch('onStyleChanged') notifyEnabled: boolean = true;
  @StorageProp('autoNewSession') @Watch('onStyleChanged') autoNewSession: boolean = true;
  @StorageProp('autoConnectSsh') autoConnectSsh: boolean = false;
  @StorageProp('lineHeight') @Watch('onStyleChanged') lineHeight: number = 1.0;
  @StorageProp('fontFamily') @Watch('onStyleChanged') fontFamily: string = '';
  @StorageProp('agentOverrides') @Watch('onStyleChanged') agentOverrides: string = '';
  @StorageProp('customAgents') @Watch('onStyleChanged') customAgents: string = '';
  @StorageProp('devicesEncoded') devicesEncoded: string = '';
  @StorageProp('selectedDeviceId') selectedDeviceId: string = '';
  @StorageProp('remoteAgentsEncoded') remoteAgentsEncoded: string = '';
  @StorageProp('sshConnectionStates') sshConnectionStates: string = '';
  @StorageProp('recentPaths') recentPaths: string[] = [];
  // System color scheme, published by EntryAbility (onCreate + onConfigurationUpdate).
  @StorageProp('sysDark') @Watch('onThemeModeChanged') sysDark: boolean = true;
  @StorageProp('titleButtonInset') titleButtonInset: number = 0;
  private ctrlDown: boolean = false;
  private shiftDown: boolean = false;
  /** Prevent @Watch callbacks from writing default values over preferences while they are loading. */
  private loadingStylePrefs: boolean = false;
  private titleTouchDown: boolean = false;
  private titleMoving: boolean = false;
  private activityTimer: number = -1;
  private mgr: SessionManager = new SessionManager();
  private sshConnections: SshRuntimeConnection[] = [];
  private mainWindow: window.Window | undefined = AppStorage.get<window.Window>('mainWindow');
  // Standard modal dialogs.
  private newDialogCtrl: CustomDialogController = new CustomDialogController({
    builder: NewAgentDialog({
      onConfirm: (cwd: string, cmd: string, label: string, iconKind: string, deviceId: string) => {
        const device = decodeDevices(this.devicesEncoded).find((item: ManagedDevice) =>
          item.id === deviceId) ?? localDevice();
        if (device.isLocal()) {
          this.pushRecentPath(cwd);
        }
        this.newSession(cwd, cmd, label, iconKind, device);
      }
    }),
    customStyle: true,
    alignment: DialogAlignment.Center,
    autoCancel: true
  });
  private settingsCtrl: CustomDialogController = new CustomDialogController({
    builder: SettingsView({
      onCustomAgentsChanged: (value: string) => {
        this.customAgents = value;
        AppStorage.setOrCreate('customAgents', value);
        this.saveCustomAgents(value);
      }
    }),
    customStyle: true,
    alignment: DialogAlignment.Center,
    autoCancel: true
  });
  private newSpaceCtrl: CustomDialogController = new CustomDialogController({
    builder: NewSpaceDialog({
      onConfirm: (cwd: string) => {
        const device = this.activeDevice();
        if (device.isLocal()) {
          this.pushRecentPath(cwd);
        }
        this.newSession(cwd, '', '', '', device);
      }
    }),
    customStyle: true,
    alignment: DialogAlignment.Center,
    autoCancel: true
  });
  private paletteCtrl: CustomDialogController = new CustomDialogController({
    builder: SearchView({
      getSessions: () => this.sessions,
      onPick: (idx: number) => { this.currentIdx = idx; },
      onPickSpace: (cwd: string, deviceId: string) => {
        this.selectDevice(deviceId);
        AppStorage.setOrCreate('selectedSpace', deviceId + '\t' + cwd);
      }
    }),
    customStyle: true,
    alignment: DialogAlignment.Center,
    autoCancel: true
  });
  private deviceCtrl: CustomDialogController = new CustomDialogController({
    builder: DeviceManagerDialog({
      getDeviceStatus: (id: string) => this.deviceStatus(id),
      onSelect: (id: string) => { this.selectDevice(id); },
      onDevicesChanged: (value: string) => { this.updateDevices(value); },
      onDeviceSaved: (device: ManagedDevice, password: string, isNew: boolean) => {
        return this.handleDeviceSaved(device, password, isNew);
      },
      onDeviceRemoved: (device: ManagedDevice) => { this.handleDeviceRemoved(device); },
      onConnect: (device: ManagedDevice) => { this.connectAndOpenTerminal(device); }
    }),
    customStyle: true,
    alignment: DialogAlignment.Center,
    autoCancel: true
  });

  aboutToAppear(): void {
    this.loadDefaultCwd();
    this.loadStylePrefs();
    this.applyIsDark();
    // Route native events to the right session.
    this.mgr.dispatch = (ev: SessionEvent) => {
      const s = this.sessions.find((it) => it.id === ev.id);
      if (s) {
        s.handleEvent(ev);
        if (ev.kind === 'cwd') {
          // Working directory changed: refresh sidebar grouping.
          this.sessions = [...this.sessions];
        }
        if (ev.kind === 'exit' && s.id > 0) {
          // Reap native resources. Deferred: the exit event is delivered from
          // the native waiter thread via TSFN; joining that thread from within
          // its own callback would deadlock, so clean up on a later tick.
          const deadId = s.id;
          setTimeout(() => {
            try { libterminal.killSession(deadId); } catch (e) {}
          }, 200);
          s.id = -1;
        }
      }
    };
    if (this.autoNewSession) {
      this.newSession();
    }
    // Auto-connect saved SSH hosts (best-effort, no password prompts).
    if (this.autoConnectSsh) {
      this.autoConnectSavedDevices();
    }
    this.activityTimer = setInterval(() => {
      this.refreshActivityStates();
    }, 400);
  }

  private autoConnectSavedDevices(): void {
    for (const device of decodeDevices(this.devicesEncoded)) {
      if (!device.isLocal()) {
        this.connectDevice(device, false).catch(() => {});
      }
    }
  }

  private loadDefaultCwd(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        AppStorage.setOrCreate('defaultCwd', this.defaultCwd);
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      const saved = store.getSync(PREF_DEFAULT_CWD, DEFAULT_CWD) as string;
      const trimmed = saved.trim();
      // Older builds could persist the developer workspace as the startup
      // directory. Migrate those defaults to a portable home-directory token.
      if (trimmed.length === 0 || trimmed === LEGACY_HOME_CWD || trimmed === LEGACY_AICODING_CWD ||
        trimmed === '~/AICoding') {
        this.defaultCwd = DEFAULT_CWD;
        store.putSync(PREF_DEFAULT_CWD, DEFAULT_CWD);
        store.flush();
      } else {
        this.defaultCwd = trimmed;
      }
      AppStorage.setOrCreate('defaultCwd', this.defaultCwd);
    } catch (e) {
      console.error('TERMINAI load default cwd failed: ' + JSON.stringify(e));
    }
  }

  private saveDefaultCwd(cwd: string): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      store.putSync(PREF_DEFAULT_CWD, cwd);
      store.flush();
      this.defaultCwd = cwd;
      AppStorage.setOrCreate('defaultCwd', cwd);
    } catch (e) {
      console.error('TERMINAI save default cwd failed: ' + JSON.stringify(e));
    }
  }

  aboutToDisappear(): void {
    if (this.activityTimer >= 0) {
      clearInterval(this.activityTimer);
      this.activityTimer = -1;
    }
    this.saveStylePrefs();
    for (const connection of [...this.sshConnections]) {
      this.disconnectDevice(connection.deviceId, true);
    }
    this.mgr.removeAll();
  }

  private refreshActivityStates(): void {
    const now = Date.now();
    for (const session of this.sessions) {
      if (!session.isAgentSession()) {
        continue;
      }
      if (session.id > 0) {
        try {
          const process = libterminal.inspectSession(session.id) as SessionProcessInfo;
          session.updateProcess(process);
        } catch (e) {
          session.processSignalAvailable = false;
        }
      }
      session.updateActivity(now);
    }
    this.sessions = [...this.sessions];
  }

  private saveCustomAgents(value: string): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      store.putSync(PREF_CUSTOM_AGENTS, value);
      store.flush((error: BusinessError) => {
        if (error) {
          console.error('TERMINAI save custom agents failed: ' + JSON.stringify(error));
        }
      });
    } catch (e) {
      console.error('TERMINAI save custom agents failed: ' + JSON.stringify(e));
    }
  }

  private activeDevice(): ManagedDevice {
    if (this.selectedDeviceId.length > 0) {
      const found = decodeDevices(this.devicesEncoded).find((item: ManagedDevice) =>
        item.id === this.selectedDeviceId);
      if (found !== undefined) {
        return found;
      }
    }
    return localDevice();
  }

  private publishSelectedDevice(device: ManagedDevice): void {
    AppStorage.setOrCreate('selectedDeviceName', device.name);
    AppStorage.setOrCreate('selectedDeviceTarget', device.sshTarget);
  }

  private selectDevice(id: string): void {
    this.selectedDeviceId = id;
    AppStorage.setOrCreate('selectedDeviceId', id);
    AppStorage.setOrCreate('selectedSpace', '');
    this.publishSelectedDevice(this.activeDevice());
    try {
      const context = this.getUIContext().getHostContext();
      if (context !== undefined) {
        const store = preferences.getPreferencesSync(context, { name: PREF_NAME });
        store.putSync(PREF_SELECTED_DEVICE, id);
        store.flush();
      }
    } catch (e) {
      console.error('TERMINAI save selected device failed: ' + JSON.stringify(e));
    }
  }

  private updateDevices(value: string): void {
    const validDevices = decodeDevices(value);
    const sessionsToClose = this.sessions.filter((session: TerminalSession) => {
      if (session.deviceId === LOCAL_DEVICE_ID) {
        return false;
      }
      const current = validDevices.find((item: ManagedDevice) => item.id === session.deviceId);
      return current === undefined || session.sshTarget !== current.sshTarget;
    });
    for (const session of sessionsToClose) {
      this.closeSession(session);
    }
    this.devicesEncoded = value;
    AppStorage.setOrCreate('devicesEncoded', value);
    if (this.selectedDeviceId.length > 0 &&
      !validDevices.some((item: ManagedDevice) => item.id === this.selectedDeviceId)) {
      this.selectedDeviceId = '';
      AppStorage.setOrCreate('selectedDeviceId', '');
    }
    this.publishSelectedDevice(this.activeDevice());
    try {
      const context = this.getUIContext().getHostContext();
      if (context !== undefined) {
        const store = preferences.getPreferencesSync(context, { name: PREF_NAME });
        store.putSync(PREF_DEVICES, value);
        store.putSync(PREF_SELECTED_DEVICE, this.selectedDeviceId);
        store.flush();
      }
    } catch (e) {
      console.error('TERMINAI save devices failed: ' + JSON.stringify(e));
    }
  }

  private sshConnection(deviceId: string): SshRuntimeConnection | null {
    const found = this.sshConnections.find((item: SshRuntimeConnection) => item.deviceId === deviceId);
    return found === undefined ? null : found;
  }

  private publishSshStates(): void {
    this.sshConnectionStates = encodeConnectionStates(this.sshConnections);
    AppStorage.setOrCreate('sshConnectionStates', this.sshConnectionStates);
  }

  private setConnectionState(connection: SshRuntimeConnection, state: SshConnectionState): void {
    connection.state = state;
    this.publishSshStates();
  }

  private deviceStatus(id: string): string {
    if (id === LOCAL_DEVICE_ID) {
      return '可用';
    }
    const connection = this.sshConnection(id);
    if (connection !== null) {
      return connection.state;
    }
    const scoped = this.sessions.filter((session: TerminalSession) => session.deviceId === id);
    if (scoped.some((session: TerminalSession) => session.alive)) {
      return '已连接';
    }
    if (scoped.some((session: TerminalSession) => session.exitCode === 255)) {
      return '连接失败';
    }
    if (scoped.length > 0) {
      return '已断开';
    }
    return '未连接';
  }

  private shellQuote(value: string): string {
    return "'" + value.replace(/'/g, "'\"'\"'") + "'";
  }

  private connectionFilePath(deviceId: string, suffix: string): string {
    const context = this.getUIContext().getHostContext();
    const base = context === undefined ? '/storage/Users/currentUser' : context.filesDir;
    let hash = 0;
    for (let index = 0; index < deviceId.length; index++) {
      hash = ((hash << 5) - hash + deviceId.charCodeAt(index)) | 0;
    }
    return base + '/terminai-ssh-' + Math.abs(hash).toString() + suffix;
  }

  private cleanupNativeSession(id: number): void {
    if (id <= 0) {
      return;
    }
    setTimeout(() => {
      try {
        libterminal.killSession(id);
      } catch (e) {
      }
    }, 200);
  }

  private disconnectDevice(deviceId: string, removeRuntime: boolean = false): void {
    const connection = this.sshConnection(deviceId);
    if (connection === null) {
      return;
    }
    const masterId = connection.masterId;
    const scanId = connection.scanId;
    connection.masterId = -1;
    connection.scanId = -1;
    connection.pendingSessions = [];
    connection.openTerminalOnReady = false;
    this.setConnectionState(connection, SshConnectionState.Disconnected);
    this.cleanupNativeSession(scanId);
    this.cleanupNativeSession(masterId);
    if (removeRuntime) {
      this.sshConnections = this.sshConnections.filter((item: SshRuntimeConnection) =>
        item.deviceId !== deviceId);
      this.publishSshStates();
    }
  }

  private async handleDeviceSaved(device: ManagedDevice, password: string, isNew: boolean): Promise<boolean> {
    if (password.length > 0) {
      const saved = await SshCredentialStore.save(device.id, password);
      if (!saved) {
        try {
          this.getUIContext().getPromptAction().showToast({ message: 'SSH 密码保存失败，请重试' });
        } catch (e) {
        }
        return false;
      }
    } else if (isNew) {
      await SshCredentialStore.remove(device.id);
    }
    this.selectDevice(device.id);
    this.disconnectDevice(device.id);
    await this.connectDevice(device, false);
    return true;
  }

  private handleDeviceRemoved(device: ManagedDevice): void {
    this.disconnectDevice(device.id, true);
    SshCredentialStore.remove(device.id).catch(() => {});
    this.remoteAgentsEncoded = removeRemoteAgents(this.remoteAgentsEncoded, device.id);
    AppStorage.setOrCreate('remoteAgentsEncoded', this.remoteAgentsEncoded);
    this.saveRemoteAgents();
  }

  private connectAndOpenTerminal(device: ManagedDevice): void {
    this.selectDevice(device.id);
    const connection = this.sshConnection(device.id);
    if (connection !== null && connection.isReady()) {
      this.openOrFocusConnectionTerminal(device);
      return;
    }
    if (connection !== null) {
      connection.openTerminalOnReady = true;
    }
    this.connectDevice(device, true).catch(() => {});
  }

  private openOrFocusConnectionTerminal(device: ManagedDevice): void {
    const existing = this.sessions.find((session: TerminalSession) =>
      session.deviceId === device.id && session.cmd.length === 0 && session.alive);
    if (existing !== undefined) {
      this.currentIdx = this.sessions.indexOf(existing);
      return;
    }
    const connection = this.sshConnection(device.id);
    const shellName = connection !== null && connection.remoteShell.length > 0 ?
      connection.remoteShell : 'sh';
    this.newSession('', '', '', '', device, shellName);
  }

  private buildMasterCommand(connection: SshRuntimeConnection): string {
    const target = normalizedSshTarget(connection.target);
    const knownHosts = this.connectionFilePath(connection.deviceId, '-known-hosts');
    // HarmonyOS user/app data filesystems do not reliably support OpenSSH's
    // Unix-domain ControlPath socket. Keep one lightweight validation
    // connection, while terminals authenticate independently from Asset Store.
    return '/usr/bin/ssh -N -o BatchMode=no -o ConnectTimeout=10 -o ServerAliveInterval=15 ' +
      '-o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new ' +
      '-o PasswordAuthentication=yes -o KbdInteractiveAuthentication=yes ' +
      '-o PreferredAuthentications=publickey,password,keyboard-interactive ' +
      '-o NumberOfPasswordPrompts=1 ' +
      '-o PermitLocalCommand=yes -o ' + this.shellQuote('LocalCommand=printf ' + SSH_CONNECTED_MARKER) +
      ' -o ' + this.shellQuote('UserKnownHostsFile=' + knownHosts) +
      ' -- ' + this.shellQuote(target);
  }

  private async connectDevice(device: ManagedDevice, openTerminal: boolean): Promise<void> {
    if (device.isLocal()) {
      return;
    }
    let connection = this.sshConnection(device.id);
    if (connection !== null && connection.target !== device.sshTarget) {
      this.disconnectDevice(device.id, true);
      connection = null;
    }
    if (connection === null) {
      connection = new SshRuntimeConnection(device.id, device.sshTarget);
      this.sshConnections.push(connection);
    }
    if (openTerminal) {
      connection.openTerminalOnReady = true;
    }
    if (connection.isReady()) {
      if (connection.openTerminalOnReady) {
        connection.openTerminalOnReady = false;
        this.openOrFocusConnectionTerminal(device);
      }
      return;
    }
    if (connection.isBusy()) {
      return;
    }

    connection.target = device.sshTarget;
    connection.controlPath = '';
    connection.passwordSent = false;
    connection.connectedMarkerSeen = false;
    connection.authOutput = '';
    connection.scanOutput = '';
    this.setConnectionState(connection, SshConnectionState.Connecting);

    const secret = new SshSecretValue(await SshCredentialStore.load(device.id));
    if (connection.state !== SshConnectionState.Connecting) {
      secret.value = '';
      return;
    }
    try {
      const command = this.buildMasterCommand(connection);
      const activeConnection: SshRuntimeConnection = connection;
      connection.passwordSent = secret.value.length > 0;
      connection.masterId = libterminal.createSessionWithSecret(80, 24, '~', command, secret.value,
        (event: SessionEvent) => {
          this.handleMasterEvent(activeConnection, event);
        });
      secret.value = '';
    } catch (e) {
      secret.value = '';
      connection.masterId = -1;
      this.setConnectionState(connection, SshConnectionState.Failed);
    }
  }

  private failConnection(connection: SshRuntimeConnection, state: SshConnectionState): void {
    const masterId = connection.masterId;
    connection.masterId = -1;
    connection.connectedMarkerSeen = false;
    this.setConnectionState(connection, state);
    this.cleanupNativeSession(masterId);
  }

  private handleMasterEvent(connection: SshRuntimeConnection, event: SessionEvent): void {
    if (event.kind === 'output') {
      connection.authOutput = (connection.authOutput + event.data).slice(-8000);
      const lower = connection.authOutput.toLowerCase();
      if (connection.authOutput.indexOf(SSH_CONNECTED_MARKER) >= 0 && !connection.connectedMarkerSeen) {
        connection.connectedMarkerSeen = true;
        this.startRemoteAgentScan(connection).catch(() => {
          this.finishRemoteScan(connection, false);
        });
        return;
      }
      if (lower.indexOf('password:') >= 0) {
        // Stored passwords are injected by the native PTY reader before this
        // asynchronous UI callback runs. No saved secret means user action is
        // required instead of exposing a terminal password prompt.
        if (!connection.passwordSent) {
          this.failConnection(connection, SshConnectionState.NeedsPassword);
        }
        return;
      }
      if (lower.indexOf('permission denied') >= 0) {
        this.failConnection(connection, SshConnectionState.AuthFailed);
      } else if (lower.indexOf('host key verification failed') >= 0 ||
        lower.indexOf('connection refused') >= 0 || lower.indexOf('no route to host') >= 0) {
        this.failConnection(connection, SshConnectionState.Failed);
      }
      return;
    }
    if (event.kind === 'exit') {
      this.cleanupNativeSession(event.id);
      if (connection.masterId !== event.id) {
        return;
      }
      connection.masterId = -1;
      if (connection.connectedMarkerSeen) {
        this.setConnectionState(connection, SshConnectionState.Disconnected);
      } else if (connection.state === SshConnectionState.Connecting) {
        const lower = connection.authOutput.toLowerCase();
        this.setConnectionState(connection, lower.indexOf('permission denied') >= 0 ?
          SshConnectionState.AuthFailed : SshConnectionState.Failed);
      }
    }
  }

  private remoteAgentCandidates(): RemoteAgentCandidate[] {
    return [
      new RemoteAgentCandidate('claude', 'claude'),
      new RemoteAgentCandidate('codex', 'codex'),
      new RemoteAgentCandidate('kimi', 'kimi'),
      new RemoteAgentCandidate('gemini', 'gemini'),
      new RemoteAgentCandidate('grok', 'grok'),
      new RemoteAgentCandidate('opencode', 'opencode'),
      new RemoteAgentCandidate('copilot', 'copilot'),
      new RemoteAgentCandidate('qwen', 'qwen'),
      new RemoteAgentCandidate('codebuddy', 'codebuddy'),
      new RemoteAgentCandidate('aider', 'aider')
    ];
  }

  private buildRemoteScanCommand(connection: SshRuntimeConnection): string {
    const names = this.remoteAgentCandidates().map((item: RemoteAgentCandidate) => item.name).join(' ');
    const scanScript = 'for terminai_name in ' + names + '; do ' +
      'terminai_path=$(command -v "$terminai_name" 2>/dev/null) || continue; ' +
      'printf "__TERMINAI_AGENT__\\t%s\\t%s\\n" "$terminai_name" "$terminai_path"; done; ' +
      // Detect the real login shell: getent (Linux) or dscl (macOS), falling
      // back to $SHELL. Non-interactive ssh starts commands in /bin/sh without
      // SHELL set to the login shell, so $SHELL alone is unreliable.
      'terminai_shell=""; ' +
      'if command -v getent >/dev/null 2>&1; then ' +
      'terminai_shell=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7); fi; ' +
      'if [ -z "$terminai_shell" ] && command -v dscl >/dev/null 2>&1; then ' +
      'terminai_shell=$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | sed "s/^.* //"); fi; ' +
      'if [ -z "$terminai_shell" ]; then terminai_shell="${SHELL:-/bin/sh}"; fi; ' +
      'printf "__TERMINAI_SHELL__\\t%s\\n" "$(basename "$terminai_shell")";';
    const remoteScript = 'exec "${SHELL:-/bin/sh}" -lc ' + this.shellQuote(scanScript);
    const knownHosts = this.connectionFilePath(connection.deviceId, '-known-hosts');
    return '/usr/bin/ssh -T -o BatchMode=no -o ConnectTimeout=10 ' +
      '-o StrictHostKeyChecking=accept-new -o ' +
      this.shellQuote('UserKnownHostsFile=' + knownHosts) + ' ' +
      '-o PasswordAuthentication=yes -o KbdInteractiveAuthentication=yes ' +
      '-o PreferredAuthentications=publickey,password,keyboard-interactive ' +
      '-o NumberOfPasswordPrompts=1 -- ' +
      this.shellQuote(normalizedSshTarget(connection.target)) + ' ' + this.shellQuote(remoteScript);
  }

  private async startRemoteAgentScan(connection: SshRuntimeConnection): Promise<void> {
    if (connection.scanId > 0) {
      return;
    }
    connection.scanOutput = '';
    this.setConnectionState(connection, SshConnectionState.Scanning);
    const secret = new SshSecretValue(await SshCredentialStore.load(connection.deviceId));
    if (connection.state !== SshConnectionState.Scanning) {
      secret.value = '';
      return;
    }
    try {
      const command = this.buildRemoteScanCommand(connection);
      connection.scanId = libterminal.createSessionWithSecret(80, 24, '~', command, secret.value,
        (event: SessionEvent) => {
          this.handleRemoteScanEvent(connection, event);
        });
      secret.value = '';
    } catch (e) {
      secret.value = '';
      this.finishRemoteScan(connection, false);
    }
  }

  private parseRemoteShell(connection: SshRuntimeConnection): string {
    for (const rawLine of connection.scanOutput.split('\n')) {
      const line = rawLine.replace(/\r/g, '');
      if (!line.startsWith('__TERMINAI_SHELL__\t')) {
        continue;
      }
      const fields = line.split('\t');
      if (fields.length === 2 && fields[1].length > 0) {
        return fields[1];
      }
    }
    return '';
  }

  private parseRemoteAgents(connection: SshRuntimeConnection): RemoteAgentInfo[] {    const agents: RemoteAgentInfo[] = [];
    const candidates = this.remoteAgentCandidates();
    for (const rawLine of connection.scanOutput.split('\n')) {
      const line = rawLine.replace(/\r/g, '');
      if (!line.startsWith('__TERMINAI_AGENT__\t')) {
        continue;
      }
      const fields = line.split('\t');
      if (fields.length !== 3 || fields[1].length === 0 || fields[2].length === 0) {
        continue;
      }
      const candidate = candidates.find((item: RemoteAgentCandidate) => item.name === fields[1]);
      const iconKind = candidate === undefined ? fields[1] : candidate.iconKind;
      if (!agents.some((item: RemoteAgentInfo) => item.name === fields[1])) {
        agents.push(new RemoteAgentInfo(connection.deviceId, fields[1], fields[2], iconKind));
      }
    }
    return agents;
  }

  private handleRemoteScanEvent(connection: SshRuntimeConnection, event: SessionEvent): void {
    if (event.kind === 'output') {
      connection.scanOutput += event.data;
      return;
    }
    if (event.kind === 'exit') {
      this.cleanupNativeSession(event.id);
      if (connection.scanId !== event.id) {
        return;
      }
      connection.scanId = -1;
      this.finishRemoteScan(connection, event.exitCode === 0);
    }
  }

  private finishRemoteScan(connection: SshRuntimeConnection, success: boolean): void {
    if (success) {
      const agents = this.parseRemoteAgents(connection);
      connection.remoteShell = this.parseRemoteShell(connection);
      AppStorage.setOrCreate('remoteShell_' + connection.deviceId, connection.remoteShell);
      this.saveRemoteShell(connection.deviceId, connection.remoteShell);
      this.remoteAgentsEncoded = replaceRemoteAgents(this.remoteAgentsEncoded, connection.deviceId, agents);
      AppStorage.setOrCreate('remoteAgentsEncoded', this.remoteAgentsEncoded);
      this.saveRemoteAgents();
      this.setConnectionState(connection, SshConnectionState.Connected);
    } else {
      this.setConnectionState(connection, SshConnectionState.ConnectedScanFailed);
    }
    this.flushPendingRemoteSessions(connection);
  }

  private flushPendingRemoteSessions(connection: SshRuntimeConnection): void {
    const device = decodeDevices(this.devicesEncoded).find((item: ManagedDevice) =>
      item.id === connection.deviceId);
    if (device === undefined) {
      connection.pendingSessions = [];
      connection.openTerminalOnReady = false;
      return;
    }
    const pending = connection.pendingSessions;
    connection.pendingSessions = [];
    for (const request of pending) {
      const shellName = (request.cmd.length === 0 && request.label.length === 0) ?
        (connection.remoteShell.length > 0 ? connection.remoteShell : 'sh') : 'zsh';
      this.newSession(request.cwd, request.cmd, request.label, request.iconKind, device, shellName);
    }
    if (connection.openTerminalOnReady) {
      connection.openTerminalOnReady = false;
      this.openOrFocusConnectionTerminal(device);
    }
  }

  private saveRemoteAgents(): void {
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(context, { name: PREF_NAME });
      store.putSync(PREF_REMOTE_AGENTS, this.remoteAgentsEncoded);
      store.flush();
    } catch (e) {
      console.error('TERMINAI save remote agents failed: ' + JSON.stringify(e));
    }
  }

  /** Persist the detected remote login shell so it survives app restarts. */
  private saveRemoteShell(deviceId: string, shell: string): void {
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined || shell.length === 0) {
        return;
      }
      const store = preferences.getPreferencesSync(context, { name: PREF_NAME });
      let map: Record<string, string> = {};
      try {
        map = JSON.parse(store.getSync(PREF_REMOTE_SHELLS, '{}') as string) as Record<string, string>;
      } catch (e) {
        map = {};
      }
      map[deviceId] = shell;
      store.putSync(PREF_REMOTE_SHELLS, JSON.stringify(map));
      store.flush();
    } catch (e) {
      console.error('TERMINAI save remote shell failed: ' + JSON.stringify(e));
    }
  }

  private startMovingWindow(): void {
    if (this.mainWindow === undefined) {
      return;
    }
    this.mainWindow.startMoving().catch((error: BusinessError) => {
      // Maximized/full-screen windows cannot be moved; keep this best-effort.
      hilog.debug(DOMAIN, 'terminAI', 'startMoving ignored: %{public}s', JSON.stringify(error));
    });
  }

  private handleTitleTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.titleTouchDown = true;
      this.titleMoving = false;
      return;
    }
    if (event.type === TouchType.Move && this.titleTouchDown && !this.titleMoving) {
      this.titleMoving = true;
      this.startMovingWindow();
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.titleTouchDown = false;
      this.titleMoving = false;
    }
  }


  private loadStylePrefs(): void {
    this.loadingStylePrefs = true;
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      const size = store.getSync(PREF_FONT_SIZE, 14) as number;
      const bold = store.getSync(PREF_FONT_BOLD, false) as boolean;
      const mode = store.getSync(PREF_THEME_MODE, 'system') as string;
      const accent = store.getSync(PREF_ACCENT, '') as string;
      const savedCustomAgents = store.getSync(PREF_CUSTOM_AGENTS, '') as string;
      const savedDevices = store.getSync(PREF_DEVICES, '') as string;
      const savedRemoteAgents = store.getSync(PREF_REMOTE_AGENTS, '') as string;
      let savedDeviceId = store.getSync(PREF_SELECTED_DEVICE, '') as string;
      if (savedDeviceId.length > 0 && !decodeDevices(savedDevices).some((item: ManagedDevice) =>
        item.id === savedDeviceId)) {
        savedDeviceId = '';
      }
      AppStorage.setOrCreate('fontSize', size);
      AppStorage.setOrCreate('fontBold', bold);
      AppStorage.setOrCreate('themeMode', mode);
      AppStorage.setOrCreate('accent', accent);
      AppStorage.setOrCreate('cursorStyle', store.getSync(PREF_CURSOR_STYLE, 'block') as string);
      AppStorage.setOrCreate('colorScheme', store.getSync(PREF_COLOR_SCHEME, 'default') as string);
      AppStorage.setOrCreate('scrollback', store.getSync(PREF_SCROLLBACK, 10000) as number);
      AppStorage.setOrCreate('programOrder', store.getSync(PREF_PROGRAM_ORDER, '') as string);
      AppStorage.setOrCreate('defaultProgram', store.getSync(PREF_DEFAULT_PROGRAM, '') as string);
      AppStorage.setOrCreate('notifyEnabled', store.getSync(PREF_NOTIFY_ENABLED, true) as boolean);
      AppStorage.setOrCreate('autoNewSession', store.getSync(PREF_AUTO_NEW_SESSION, true) as boolean);
      AppStorage.setOrCreate('autoConnectSsh', store.getSync(PREF_AUTO_CONNECT_SSH, false) as boolean);
      AppStorage.setOrCreate('lineHeight', store.getSync(PREF_LINE_HEIGHT, 1.0) as number);
      AppStorage.setOrCreate('fontFamily', store.getSync(PREF_FONT_FAMILY, '') as string);
      AppStorage.setOrCreate('agentOverrides',
        migrateAgentOverrides(store.getSync(PREF_AGENT_OVERRIDES, '') as string));
      AppStorage.setOrCreate('customAgents', savedCustomAgents);
      AppStorage.setOrCreate('devicesEncoded', savedDevices);
      AppStorage.setOrCreate('selectedDeviceId', savedDeviceId);
      AppStorage.setOrCreate('remoteAgentsEncoded', savedRemoteAgents);
      // Restore persisted remote login shells (detected on first connection).
      try {
        const savedShells = store.getSync(PREF_REMOTE_SHELLS, '{}') as string;
        const shellMap = JSON.parse(savedShells) as Record<string, string>;
        Object.keys(shellMap).forEach((id: string) => {
          AppStorage.setOrCreate('remoteShell_' + id, shellMap[id]);
        });
      } catch (e) {
        console.error('TERMINAI restore remote shells failed: ' + JSON.stringify(e));
      }
      AppStorage.setOrCreate('sshConnectionStates', '');
      this.devicesEncoded = savedDevices;
      this.selectedDeviceId = savedDeviceId;
      this.remoteAgentsEncoded = savedRemoteAgents;
      this.sshConnectionStates = '';
      this.publishSelectedDevice(this.activeDevice());
      const recents = store.getSync(PREF_RECENT_PATHS, '[]') as string;
      try {
        AppStorage.setOrCreate('recentPaths', JSON.parse(recents) as string[]);
      } catch (e) {
        AppStorage.setOrCreate('recentPaths', []);
      }
    } catch (e) {
      console.error('TERMINAI load style prefs failed: ' + JSON.stringify(e));
    } finally {
      this.loadingStylePrefs = false;
    }
  }

  private saveStylePrefs(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      store.putSync(PREF_FONT_SIZE, this.fontSize);
      store.putSync(PREF_FONT_BOLD, this.fontBold);
      store.putSync(PREF_THEME_MODE, this.themeMode);
      store.putSync(PREF_ACCENT, this.accent);
      store.putSync(PREF_CURSOR_STYLE, this.cursorStyle);
      store.putSync(PREF_COLOR_SCHEME, this.colorScheme);
      store.putSync(PREF_SCROLLBACK, this.scrollback);
      store.putSync(PREF_PROGRAM_ORDER, this.programOrder);
      store.putSync(PREF_DEFAULT_PROGRAM, this.defaultProgram);
      store.putSync(PREF_NOTIFY_ENABLED, this.notifyEnabled);
      store.putSync(PREF_AUTO_NEW_SESSION, this.autoNewSession);
      store.putSync(PREF_AUTO_CONNECT_SSH, this.autoConnectSsh);
      store.putSync(PREF_LINE_HEIGHT, this.lineHeight);
      store.putSync(PREF_FONT_FAMILY, this.fontFamily);
      store.putSync(PREF_AGENT_OVERRIDES, this.agentOverrides);
      store.putSync(PREF_CUSTOM_AGENTS, this.customAgents);
      store.putSync(PREF_DEVICES, this.devicesEncoded);
      store.putSync(PREF_SELECTED_DEVICE, this.selectedDeviceId);
      store.putSync(PREF_REMOTE_AGENTS, this.remoteAgentsEncoded);
      store.flush();
    } catch (e) {
      console.error('TERMINAI save style prefs failed: ' + JSON.stringify(e));
    }
  }

  /** Resolve the effective dark flag from themeMode (+ system scheme). */
  private applyIsDark(): void {
    if (this.themeMode === 'dark') {
      AppStorage.setOrCreate('isDark', true);
    } else if (this.themeMode === 'light') {
      AppStorage.setOrCreate('isDark', false);
    } else {
      // Follow the system scheme published by EntryAbility.
      AppStorage.setOrCreate('isDark', this.sysDark);
    }
    this.isDark = AppStorage.get<boolean>('isDark') ?? true;
  }

  onThemeModeChanged(): void {
    this.applyIsDark();
  }

  onStyleChanged(): void {
    if (this.loadingStylePrefs) {
      return;
    }
    this.saveStylePrefs();
  }

  /** Record a successfully used start path (newest first, max 5). */
  private pushRecentPath(path: string): void {
    const list = this.recentPaths.filter((p: string) => p !== path);
    list.unshift(path);
    while (list.length > 5) {
      list.pop();
    }
    this.recentPaths = list;
    AppStorage.setOrCreate('recentPaths', list);
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      store.putSync(PREF_RECENT_PATHS, JSON.stringify(list));
      store.flush();
    } catch (e) {
      console.error('TERMINAI save recents failed: ' + JSON.stringify(e));
    }
  }

  private notifyExit(s: TerminalSession): void {
    if (!this.notifyEnabled) {
      return;
    }
    try {
      const req: notificationManager.NotificationRequest = {
        id: s.id,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'terminAI 会话已退出',
            text: s.displayName() + '（退出码 ' + s.exitCode + '）'
          }
        }
      };
      notificationManager.publish(req).catch(() => {});
    } catch (e) {}
  }

  private newSession(startCwd: string = '', cmd: string = '', label: string = '',
    iconKind: string = '', device: ManagedDevice = localDevice(), shellName: string = ''): void {
    const cwd = startCwd.length > 0 ? startCwd : (device.isLocal() ? this.defaultCwd : '~');
    let finalShell = shellName.length > 0 ? shellName : (device.isLocal() ? 'zsh' : 'sh');
    // For remote terminals the login shell is the host's $SHELL (e.g. bash);
    // prefer the value detected during the connection scan.
    if (!device.isLocal() && (shellName.length === 0 || shellName === 'sh')) {
      const connection = this.sshConnection(device.id);
      if (connection !== null && connection.remoteShell.length > 0) {
        finalShell = connection.remoteShell;
      }
    }
    let controlPath = '';
    let knownHostsPath = '';
    if (!device.isLocal()) {
      let connection = this.sshConnection(device.id);
      if (connection === null) {
        connection = new SshRuntimeConnection(device.id, device.sshTarget);
        this.sshConnections.push(connection);
        this.publishSshStates();
      }
      if (!connection.isReady()) {
        connection.pendingSessions.push(new PendingRemoteSession(cwd, cmd, label, iconKind));
        this.connectDevice(device, false).catch(() => {});
        return;
      }
      controlPath = connection.controlPath;
      knownHostsPath = this.connectionFilePath(device.id, '-known-hosts');
    }
    const s = this.mgr.newSession(cwd, cmd, label, iconKind, device.id, device.name,
      device.sshTarget, controlPath, knownHostsPath, finalShell);
    s.onStateChanged = () => {
      if (!s.alive) {
        // session exited: notify only if user isn't looking at it
        const idx = this.sessions.indexOf(s);
        if (idx !== this.currentIdx && !s.exitNotificationSent) {
          this.notifyExit(s);
          s.exitNotificationSent = true;
        }
      }
      // Keep exited sessions visible until the user closes them so the
      // "会话已退出" state remains truthful and recoverable.
      this.sessions = [...this.sessions];
    };
    s.onCwdChanged = () => {
      this.sessions = [...this.sessions];
    };
    this.sessions = [...this.mgr.sessions];
    this.currentIdx = this.sessions.length - 1;
  }

  private closeSession(s: TerminalSession): void {
    const idx = this.sessions.indexOf(s);
    this.mgr.remove(s);
    this.sessions = [...this.mgr.sessions];
    if (this.sessions.length === 0) {
      this.currentIdx = -1;
    } else if (idx >= this.sessions.length) {
      this.currentIdx = this.sessions.length - 1;
    }
  }

  private programLabel(s: TerminalSession): string {
    if (s.agentKind.length > 0) {
      return s.agentKind;
    }
    if (s.cmd.length === 0) {
      return s.shellName;
    }
    const parts = s.cmd.split('/');
    return parts.length > 0 ? parts[parts.length - 1] : s.cmd;
  }

  private programIconKind(s: TerminalSession): string {
    return s.agentIconKind.length > 0 ? s.agentIconKind : this.programLabel(s);
  }

  private displayCwd(path: string): string {
    if (path === '/storage/Users/currentUser') return '~';
    if (path.startsWith('/storage/Users/currentUser/')) {
      return '~/' + path.substring('/storage/Users/currentUser/'.length);
    }
    return path;
  }

  private capitalizeSessionName(value: string): string {
    if (value.length === 0) {
      return value;
    }
    return value.substring(0, 1).toUpperCase() + value.substring(1);
  }

  /** herdrm DetailView titlebar: status glyph, title, badge · space, pill. */
  private currentSession(): TerminalSession | null {
    if (this.currentIdx >= 0 && this.currentIdx < this.sessions.length) {
      return this.sessions[this.currentIdx];
    }
    return null;
  }

  @Builder
  detailTitlebar() {
    Row() {
      Row() {
        if (this.currentSession() !== null) {
          if (this.currentSession()!.cmd.length === 0) {
            UiIcon({ name: IconName.Terminal, iconSize: 14, color: Theme.tertiary(this.isDark) })
          } else {
            BrandIcon({
              kind: this.programIconKind(this.currentSession()!),
              iconSize: 14,
              color: Theme.tertiary(this.isDark),
              isDark: this.isDark
            })
          }
          Text(this.currentSession()!.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
            .maxLines(1)
            .margin({ left: 7 })
          SessionNumberBadge({ value: this.currentSession()!.sequence, isDark: this.isDark })
            .margin({ left: 6 })
          Blank()
          Text(this.displayCwd(this.currentSession()!.cwd))
            .fontSize(12)
            .fontColor(Theme.tertiary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 260 })
        } else {
          UiIcon({ name: IconName.Terminal, iconSize: 14, color: Theme.tertiary(this.isDark) })
          Text('可新建会话')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.tertiary(this.isDark))
            .margin({ left: 7 })
          Blank()
        }
      }
      .height('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 10 })
      .onTouch((event: TouchEvent) => {
        this.handleTitleTouch(event);
      })
    }
    .width('100%')
    .height(40)
    .padding({ right: this.titleButtonInset })
    .backgroundColor(Theme.windowBg(this.isDark))
  }

  @Builder
  emptyState() {
    Column() {
      Column() {
        UiIcon({ name: IconName.EmptyTerminal, iconSize: 42, color: Theme.tertiary(this.isDark) })
      }
      .width(72)
      .height(72)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.card(this.isDark))
      .border({ width: 1, color: Theme.border(this.isDark), radius: 18 })
      .borderRadius(18)

      Text('开始本地编程会话')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text(this.isDark))
        .margin({ top: 18 })

      Text('在任意项目文件夹中启动智能体或普通终端。')
        .fontSize(14)
        .fontColor(Theme.tertiary(this.isDark))
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })

      Row({ space: 10 }) {
        Row() {
          UiIcon({ name: IconName.NewAgent, iconSize: 15, color: Theme.onAccent(this.isDark) })
          Text('新建智能体')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.onAccent(this.isDark))
            .margin({ left: 7 })
        }
        .height(36)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Theme.accent(this.isDark))
        .borderRadius(8)
        .onClick(() => { this.newDialogCtrl.open(); })
        .accessibilityText('新建智能体')

        Row() {
          UiIcon({ name: IconName.Terminal, iconSize: 15, color: Theme.text(this.isDark) })
          Text('新建终端')
            .fontSize(14)
            .fontColor(Theme.text(this.isDark))
            .margin({ left: 7 })
        }
        .height(36)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Theme.button(this.isDark))
        .border({ width: 1, color: Theme.border(this.isDark), radius: 8 })
        .borderRadius(8)
        .onClick(() => { this.newSession('', '', '', '', this.activeDevice()); })
        .accessibilityText('新建终端')
      }
      .margin({ top: 20 })
    }
    .width(420)
  }

  private handleAppShortcut(keyCode: number, shift: boolean): void {
    switch (keyCode) {
      case KEYCODE_K:
        this.paletteCtrl.open();
        break;
      case KEYCODE_B:
        this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut },
          () => { this.sidebarCollapsed = !this.sidebarCollapsed; });
        break;
      case KEYCODE_N:
        if (shift) {
          this.newSpaceCtrl.open();
        } else {
          this.newDialogCtrl.open();
        }
        break;
      case KEYCODE_T:
        this.newDialogCtrl.open();
        break;
      case KEYCODE_W:
        if (this.currentIdx >= 0 && this.currentIdx < this.sessions.length) {
          this.closeSession(this.sessions[this.currentIdx]);
        }
        break;
      default:
        break;
    }
  }

  build() {
    Stack() {
      // Built-in sidebar container: drag the divider to resize (200..420).
      // Collapsed = fully hidden (showSideBar false).
      SideBarContainer(SideBarContainerType.Embed) {
        SidebarView({
          sidebarWidth: this.sidebarWidth,
          sessions: $sessions,
          currentId: $currentIdx,
          onNewAgent: () => { this.newDialogCtrl.open(); },
          onNewAgentIn: (cwd: string, deviceId: string) => {
            this.selectDevice(deviceId);
            AppStorage.setOrCreate('pendingNewCwd', cwd);
            this.newDialogCtrl.open();
          },
          onSelectSpace: (deviceId: string, cwd: string) => {
            // Under "All Devices" keep showing everything; only switch the
            // device filter when a specific device is already selected.
            if (this.selectedDeviceId.length > 0) {
              this.selectDevice(deviceId);
            }
            const idx = this.sessions.findIndex((it: TerminalSession) =>
              it.deviceId === deviceId && canonicalSessionCwd(it) === cwd);
            if (idx >= 0) {
              this.currentIdx = idx;
            }
          },
          onCloseSpace: (cwd: string, deviceId: string) => {
            for (const s of this.sessions.filter((it: TerminalSession) =>
              canonicalSessionCwd(it) === cwd && it.deviceId === deviceId)) {
              this.closeSession(s);
            }
          },
          onNewSpace: () => { this.newSpaceCtrl.open(); },
          onSearch: () => { this.paletteCtrl.open(); },
          onCloseSession: (s: TerminalSession) => this.closeSession(s),
          onRenameSession: (s: TerminalSession, name: string) => {
            s.name = this.capitalizeSessionName(name);
            this.sessions = [...this.sessions];
          },
          onOpenSettings: () => { this.settingsCtrl.open(); },
          onOpenDevices: () => { this.deviceCtrl.open(); },
          onCollapse: () => {
            this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut },
              () => { this.sidebarCollapsed = true; });
          },
          onTitleTouch: (event: TouchEvent) => { this.handleTitleTouch(event); }
        })

        // Detail area: titlebar strip + terminal (herdrm DetailView).
        Column() {
          this.detailTitlebar()

          Divider()
            .color(Theme.divider(this.isDark))
            .strokeWidth(1)

          // Terminal stack: all sessions mounted, only current visible.
          // BottomStart alignment anchors the expand button; other children
          // are full-size so the alignment does not affect them.
          Stack({ alignContent: Alignment.BottomStart }) {
            ForEach(this.sessions, (s: TerminalSession, idx: number) => {
              Column() {
                TerminalView({
                  session: s,
                  onEvent: (ev: SessionEvent) => this.mgr.dispatch(ev),
                  onShortcut: (keyCode: number, shift: boolean) => {
                    this.handleAppShortcut(keyCode, shift);
                  }
                })
              }
              .width('100%')
              .height('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .visibility(idx === this.currentIdx ? Visibility.Visible : Visibility.Hidden)
            }, (s: TerminalSession, idx: number) => 'term_' + s.uid)

            if (this.sessions.length === 0) {
              Column() {
                this.emptyState()
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .backgroundColor(Theme.terminalBg(this.isDark))
            }

            // Toggle shown only while the sidebar is hidden: expands from the
            // screen bottom-left corner.
            if (this.sidebarCollapsed) {
              Row() {
                UiIcon({
                  name: IconName.SidebarShow,
                  iconSize: 17,
                  color: Theme.subText(this.isDark)
                })
              }
                .width(36)
                .height(36)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(Theme.button(this.isDark))
                .border({ width: 1, color: Theme.border(this.isDark), radius: 10 })
                .borderRadius(10)
                .margin({ left: 14, bottom: 14 })
                .onClick(() => {
                  this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut },
                    () => { this.sidebarCollapsed = false; });
                })
                .accessibilityText('显示侧边栏')
            }
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(Theme.terminalBg(this.isDark))
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.terminalBg(this.isDark))
      }
      .showSideBar(!this.sidebarCollapsed)
      .autoHide(false)
      .showControlButton(false)
      .sideBarPosition(SideBarPosition.Start)
      .sideBarWidth(this.sidebarWidth)
      .minSideBarWidth(220)
      .maxSideBarWidth(420)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.windowBg(this.isDark))
    .focusable(true)
    .onKeyEvent((event: KeyEvent) => {
      // Track Ctrl/Shift state manually (KeyEvent exposes no modifier flags).
      if (event.keyCode === KEYCODE_CTRL_LEFT || event.keyCode === KEYCODE_CTRL_RIGHT) {
        this.ctrlDown = (event.type === KeyType.Down);
        return;
      }
      if (event.keyCode === KEYCODE_SHIFT_LEFT || event.keyCode === KEYCODE_SHIFT_RIGHT) {
        this.shiftDown = (event.type === KeyType.Down);
        return;
      }
      if (event.type !== KeyType.Down) return;
      if (!this.ctrlDown) {
        return;
      }
      this.handleAppShortcut(event.keyCode, this.shiftDown);
    })
  }
}
