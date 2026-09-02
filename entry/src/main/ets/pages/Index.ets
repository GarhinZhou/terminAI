// Main page: sidebar + terminal stack + Ctrl+K palette.
import libterminal from 'libterminal.so';
import { canonicalSessionCwd, TerminalSession, SessionManager, SessionEvent } from '../model/TerminalSession';
import { TerminalView } from '../view/TerminalView';
import { SidebarView } from '../view/SidebarView';
import { SearchView } from '../view/SearchView';
import { NewAgentDialog } from '../view/NewAgentDialog';
import { NewSpaceDialog } from '../view/NewSpaceDialog';
import { SettingsView } from '../view/SettingsView';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { pointer } from '@kit.InputKit';
import { Theme } from '../common/Theme';
import { BrandIcon } from '../common/BrandIcon';
import { IconName, UiIcon } from '../common/Icons';
import { SessionNumberBadge } from '../common/SessionNumberBadge';
import { DeviceManagerDialog } from '../view/DeviceManagerDialog';
import { ManagedDevice, decodeDevices, LOCAL_DEVICE_ID, localDevice, normalizedSshTarget,
  sshAuthenticationArguments } from '../model/ManagedDevice';
import { migrateAgentOverrides } from '../model/AgentOverrides';
import { SshCredentialStore } from '../model/SshCredentialStore';
import { SshIdentityStore } from '../model/SshIdentityStore';
import { PendingRemoteSession, RemoteAgentInfo, SshConnectionState, SshRuntimeConnection,
  SshSecretValue, encodeConnectionStates, removeRemoteAgents,
  replaceRemoteAgents } from '../model/RemoteSshState';
import { decodeSavedSessions } from '../model/SessionPersistence';
import { SessionNotificationService } from '../model/SessionNotificationService';
import { BackgroundSessionService } from '../model/BackgroundSessionService';
import { ResidentSessionBackend } from '../model/ResidentSessionBackend';
import { TerminaiPreferences } from '../model/TerminaiPreferences';

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
const KEYCODE_D = 2020;
const KEYCODE_ALT_LEFT = 2045;
const KEYCODE_ALT_RIGHT = 2046;
const KEYCODE_N = 2030;
const KEYCODE_ESCAPE = 2070;
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
const PREF_LAST_PROGRAMS = 'lastProgramsByDevice';
const PREF_SAVED_SESSIONS = 'savedSessions';
const PREF_CURRENT_SESSION = 'currentSessionIndex';
const RENDERER_POOL_LIMIT = 3;
const STYLE_SAVE_DELAY = 350;

@Entry
@Component
struct Index {
  @State sessions: TerminalSession[] = [];
  @State @Watch('onCurrentSessionChanged') currentIdx: number = -1;
  /** Rebuilt snapshot driving the primary pane ForEach (reliable diff). */
  @State private primaryPaneSessions: TerminalSession[] = [];
  @State sidebarCollapsed: boolean = false;
  @State sidebarWidth: number = 280;
  /** Current plus two recent ArkWeb renderers; PTY sessions continue independently when evicted. */
  @State @Watch('refreshPrimaryPane') private renderedSessionUids: number[] = [];
  /** herdrm-style temporary shell shown beside the selected agent. */
  @State @Watch('refreshPrimaryPane') private splitSessionUid: number = -1;
  /** Live split-pane session object; read directly in @Builder so ArkUI diffing is reliable. */
  @State private splitPaneSession: TerminalSession | null = null;
  /** Explicit reactive mirror for the split titlebar's live working directory. */
  @State private splitPaneCwd: string = '';
  /** true stacks panes top-to-bottom; false arranges them left-to-right. */
  @State private splitHorizontal: boolean = false;
  /** Keyboard focus belongs to the split pane while true. */
  @State private splitFocused: boolean = false;
  /** Main-pane share (0.2..0.8); the divider drag updates it. */
  @State private splitRatio: number = 0.5;
  @State private splitDragging: boolean = false;
  @State private splitDividerHovered: boolean = false;
  @State private splitDragStartX: number = 0;
  @State private splitDragStartY: number = 0;
  @State private splitDragStartRatio: number = 0.5;
  @State private workspaceWidth: number = 0;
  @State private workspaceHeight: number = 0;
  @State private terminalFocusRequest: number = 0;
  /** Explicit fit request sent to both active terminal panes after split layout commits. */
  @State private terminalLayoutRefreshRequest: number = 0;
  @State defaultCwd: string = DEFAULT_CWD;
  @State private titleSidebarHovered: boolean = false;
  @State private titleSidebarPressed: boolean = false;
  @State private titleSidebarFocused: boolean = false;
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
  @StorageProp('notifyEnabled') @Watch('onNotifyEnabledChanged') notifyEnabled: boolean = false;
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
  @StorageProp('lastProgramsByDevice') @Watch('onStyleChanged') lastProgramsByDevice: string = '';
  @StorageProp('sysDark') @Watch('onThemeModeChanged') sysDark: boolean = true;
  @StorageProp('titleButtonInset') titleButtonInset: number = 0;
  @StorageProp('appForeground') @Watch('onAppForegroundChanged') appForeground: boolean = true;
  @StorageProp('notificationSessionRequest') @Watch('onNotificationSessionRequestChanged')
  notificationSessionRequest: string = '';
  private ctrlDown: boolean = false;
  private shiftDown: boolean = false;
  private altDown: boolean = false;
  /** Prevent @Watch callbacks from writing default values over preferences while they are loading. */
  private loadingStylePrefs: boolean = false;
  private titleTouchDown: boolean = false;
  private titleMoving: boolean = false;
  private backend: ResidentSessionBackend = ResidentSessionBackend.shared();
  private mgr: SessionManager = this.backend.sessionManager;
  private sshConnections: SshRuntimeConnection[] = this.backend.sshConnections;
  private mainWindow: window.Window | undefined = AppStorage.get<window.Window>('mainWindow');
  // Standard modal dialogs.
  private styleSaveTimer: number = -1;
  private restoringSessions: boolean = false;
  private savedSessionsEncoded: string = '';
  private savedCurrentSessionIndex: number = -1;
  private newDialogCtrl: CustomDialogController = new CustomDialogController({
    builder: NewAgentDialog({
      onConfirm: (cwd: string, cmd: string, label: string, iconKind: string, deviceId: string) => {
        const device = decodeDevices(this.devicesEncoded).find((item: ManagedDevice) =>
          item.id === deviceId) ?? localDevice();
        if (device.isLocal()) {
          this.pushRecentPath(cwd);
        }
        this.newSession(cwd, cmd, label, iconKind, device);
      },
      onOpenCustomAgentSettings: (deviceId: string) => {
        this.openCustomAgentSettings(deviceId);
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
      onPick: (uid: number) => {
        if (uid === this.splitSessionUid) {
          // Keep the split arrangement; just hand the pane focus.
          this.splitFocused = true;
          this.terminalFocusRequest++;
          return;
        }
        const index = this.sessions.findIndex((session: TerminalSession) => session.uid === uid);
        if (index >= 0) {
          this.currentIdx = index;
          this.splitFocused = false;
        }
      },
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
      onDeviceSaved: (device: ManagedDevice, credential: string, isNew: boolean) => {
        return this.handleDeviceSaved(device, credential, isNew);
      },
      onDeviceCommitted: (device: ManagedDevice) => { this.handleDeviceCommitted(device); },
      onDeviceRemoved: (device: ManagedDevice) => { this.handleDeviceRemoved(device); },
      onConnect: (device: ManagedDevice) => { this.connectAndOpenTerminal(device); }
    }),
    customStyle: true,
    alignment: DialogAlignment.Center,
    autoCancel: true
  });
  private openSettings(): void {
    AppStorage.setOrCreate('settingsTargetCustomAgent', false);
    this.settingsCtrl.open();
  }

  private openCustomAgentSettings(deviceId: string): void {
    AppStorage.setOrCreate('settingsTargetDevice', deviceId);
    AppStorage.setOrCreate('settingsTargetCustomAgent', true);
    setTimeout(() => { this.settingsCtrl.open(); }, 80);
  }

  onCurrentSessionChanged(): void {
    this.saveSessionsSoon();
    const session = this.currentIdx >= 0 && this.currentIdx < this.sessions.length ?
      this.sessions[this.currentIdx] : null;
    if (session === null) {
      this.backend.setSelectedSessionUid(-1);
      return;
    }
    this.backend.setSelectedSessionUid(session.uid);
    SessionNotificationService.cancelSession(session.uid);
    this.touchRenderedSession(session.uid);
    // TerminalView requests focus after its ArkWeb is mounted, visible and
    // ready. Requesting it here races the renderer-pool update and can target
    // a component that is still hidden or does not exist yet.
  }

  private touchRenderedSession(uid: number): void {
    const next: number[] = [uid];
    for (const existing of this.renderedSessionUids) {
      if (existing !== uid && this.sessions.some((session: TerminalSession) => session.uid === existing)) {
        next.push(existing);
      }
      if (next.length >= RENDERER_POOL_LIMIT) {
        break;
      }
    }
    this.renderedSessionUids = next;
  }

  /** Rebuild the primary-pane list from the renderer pool + current session. */
  private refreshPrimaryPane(): void {
    this.primaryPaneSessions = this.renderedSessions()
      .filter((session: TerminalSession) => session.uid !== this.splitSessionUid);
  }

  private renderedSessions(): TerminalSession[] {
    const current = this.currentSession();
    return this.sessions.filter((session: TerminalSession) =>
      session.uid === (current === null ? -1 : current.uid) ||
      this.renderedSessionUids.some((uid: number) => uid === session.uid));
  }

  /** A pane's ArkWeb node gained focus: that pane owns keyboard shortcuts. */
  private onPaneFocused(uid: number): void {
    if (this.splitSessionUid < 0) {
      return;
    }
    const focusedSplit = uid === this.splitSessionUid;
    if (focusedSplit !== this.splitFocused) {
      this.splitFocused = focusedSplit;
    }
  }

  private splitSession(): TerminalSession | null {
    const session = this.sessions.find((item: TerminalSession) => item.uid === this.splitSessionUid);
    return session === undefined ? null : session;
  }

  private deviceForSession(session: TerminalSession): ManagedDevice {
    const saved = decodeDevices(this.devicesEncoded).find((device: ManagedDevice) =>
      device.id === session.deviceId);
    return saved === undefined ?
      new ManagedDevice(session.deviceId, session.deviceName, session.sshTarget) : saved;
  }

  private showMessage(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
      console.error('TERMINAI show split message failed: ' + JSON.stringify(error));
    }
  }

  /** Wait one task so ArkUI has applied the new split geometry before xterm measures it. */
  private scheduleSplitLayoutRefresh(): void {
    const expectedSplitUid = this.splitSessionUid;
    setTimeout(() => {
      if (expectedSplitUid > 0 && this.splitSessionUid === expectedSplitUid) {
        this.terminalLayoutRefreshRequest++;
      }
    }, 0);
  }

  private openSplit(horizontal: boolean): void {
    const current = this.currentSession();
    if (current === null) {
      this.showMessage('请先选择一个会话再打开分屏');
      return;
    }
    if (this.splitSession() !== null) {
      if (this.splitHorizontal === horizontal) {
        this.closeSplit();
        return;
      }
      this.splitHorizontal = horizontal;
      this.scheduleSplitLayoutRefresh();
      return;
    }
    const device = this.deviceForSession(current);
    if (!device.isLocal()) {
      const connection = this.sshConnection(device.id);
      if (connection === null || !connection.isReady()) {
        this.showMessage('远程设备连接完成后才能打开分屏');
        this.connectDevice(device, false).catch(() => {});
        return;
      }
    }
    const shell = this.newSession(current.cwd, '', '', '', device,
      current.sshTarget.length > 0 ? current.shellName : 'zsh', '', false, 0, false);
    if (shell === null) {
      this.showMessage('远程设备连接完成后才能打开分屏');
      return;
    }
    this.splitHorizontal = horizontal;
    this.splitSessionUid = shell.uid;
    this.splitPaneSession = shell;
    this.splitPaneCwd = shell.cwd;
    this.splitRatio = 0.5;
    this.splitFocused = true;
    this.terminalFocusRequest++;
    this.scheduleSplitLayoutRefresh();
  }

  private closeSplit(removeShell: boolean = true): void {
    const shell = this.splitSession();
    this.splitSessionUid = -1;
    this.splitPaneSession = null;
    this.splitPaneCwd = '';
    this.splitFocused = false;
    this.terminalFocusRequest++;
    if (removeShell && shell !== null) {
      this.closeSession(shell);
    }
  }

  private saveSessionsSoon(): void {
    if (this.restoringSessions) return;
    this.backend.schedulePersistence();
  }

  private saveSessionsNow(): void {
    if (this.restoringSessions) return;
    this.backend.flushPersistence();
  }

  private restoreSavedSessions(): boolean {
    const items = decodeSavedSessions(this.savedSessionsEncoded);
    if (items.length === 0) return false;
    const devices = decodeDevices(this.devicesEncoded);
    let restored = 0;
    this.restoringSessions = true;
    for (let index = 0; index < items.length; index++) {
      const item = items[index];
      const device = devices.find((candidate: ManagedDevice) => candidate.id === item.deviceId);
      if (device === undefined) continue;
      this.newSession(item.cwd, item.cmd, item.agentKind, item.iconKind, device,
        item.shellName, item.title, item.manualTitle, item.sequence,
        index === this.savedCurrentSessionIndex);
      restored++;
    }
    this.restoringSessions = false;
    if (restored > 0) this.saveSessionsSoon();
    return restored > 0;
  }


  aboutToAppear(): void {
    this.loadDefaultCwd();
    this.loadStylePrefs();
    this.applyIsDark();
    // Native dispatch is process-owned. This observer only refreshes the
    // currently attached page and can be replaced without touching PTYs.
    this.mgr.onEvent = (session: TerminalSession, ev: SessionEvent) => {
      if (ev.kind === 'cwd' || ev.kind === 'exit') {
        this.sessions = [...this.mgr.sessions];
      }
    };
    let restoredSessions = false;
    if (this.backend.hasRuntimeSessions()) {
      for (const session of this.mgr.sessions) {
        this.bindSessionCallbacks(session);
      }
      this.sessions = [...this.mgr.sessions];
      const selectedUid = this.backend.selectedSession();
      const selectedIndex = this.sessions.findIndex((session: TerminalSession) =>
        session.uid === selectedUid);
      this.currentIdx = selectedIndex >= 0 ? selectedIndex : this.sessions.length - 1;
      restoredSessions = true;
    } else {
      restoredSessions = this.restoreSavedSessions();
    }
    if (!restoredSessions && this.autoNewSession) {
      this.newSession();
    }
    this.publishSshStates();
    BackgroundSessionService.setLiveSessionCount(this.backend.liveSessionCount());
    this.routeNotificationSelection();
    // Auto-connect saved SSH hosts (best-effort, no password prompts).
    if (this.autoConnectSsh) {
      this.autoConnectSavedDevices();
    }
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
      const store = TerminaiPreferences.get(ctx);
      const saved = store.getSync(PREF_DEFAULT_CWD, DEFAULT_CWD) as string;
      const trimmed = saved.trim();
      // Older builds could persist the developer workspace as the startup
      // directory. Migrate those defaults to a portable home-directory token.
      if (trimmed.length === 0 || trimmed === LEGACY_HOME_CWD || trimmed === LEGACY_AICODING_CWD ||
        trimmed === '~/AICoding') {
        this.defaultCwd = DEFAULT_CWD;
        store.putSync(PREF_DEFAULT_CWD, DEFAULT_CWD);
        store.flushSync();
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
      const store = TerminaiPreferences.get(ctx);
      store.putSync(PREF_DEFAULT_CWD, cwd);
      store.flushSync();
      this.defaultCwd = cwd;
      AppStorage.setOrCreate('defaultCwd', cwd);
    } catch (e) {
      console.error('TERMINAI save default cwd failed: ' + JSON.stringify(e));
    }
  }

  aboutToDisappear(): void {
    this.saveStylePrefs();
    if (this.styleSaveTimer >= 0) {
      clearTimeout(this.styleSaveTimer);
      this.styleSaveTimer = -1;
    }
    this.saveSessionsNow();
    // Detach only the ArkUI observers. EntryAbility owns the explicit shutdown
    // path; a page/window rebuild must leave PTY and SSH sessions running.
    this.mgr.onEvent = () => {};
    for (const session of this.mgr.sessions) {
      session.onStateChanged = () => {};
      session.onMetadataChanged = () => {};
      session.onCwdChanged = () => {};
    }
  }

  private saveCustomAgents(value: string): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = TerminaiPreferences.get(ctx);
      store.putSync(PREF_CUSTOM_AGENTS, value);
      store.flushSync();
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
        const store = TerminaiPreferences.get(context);
        store.putSync(PREF_SELECTED_DEVICE, id);
        store.flushSync();
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
        const store = TerminaiPreferences.get(context);
        store.putSync(PREF_DEVICES, value);
        store.putSync(PREF_SELECTED_DEVICE, this.selectedDeviceId);
        store.flushSync();
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
    libterminal.killSessionAsync(id)
      .catch((error: Error) => {
        console.error('TERMINAI async native session cleanup failed: ' + error.message);
      });
  }

  private disconnectDevice(deviceId: string, removeRuntime: boolean = false): void {
    const connection = this.sshConnection(deviceId);
    if (connection === null) {
      return;
    }
    const masterId = connection.masterId;
    const scanId = connection.scanId;
    connection.invalidate(true);
    connection.masterId = -1;
    connection.scanId = -1;
    connection.pendingSessions = [];
    connection.openTerminalOnReady = false;
    this.setConnectionState(connection, SshConnectionState.Disconnected);
    this.cleanupNativeSession(scanId);
    this.cleanupNativeSession(masterId);
    if (removeRuntime) {
      this.backend.removeSshConnection(connection);
      this.publishSshStates();
    }
  }

  private async handleDeviceSaved(device: ManagedDevice, credential: string,
    isNew: boolean): Promise<boolean> {
    const credentialKind = SshCredentialStore.kindForDevice(device);
    if (credential.length > 0) {
      const saved = await SshCredentialStore.save(device.id, credential, credentialKind);
      if (!saved) {
        try {
          this.getUIContext().getPromptAction().showToast({ message: 'SSH 登录凭据保存失败，请重试' });
        } catch (e) {
        }
        return false;
      }
    } else if (isNew) {
      await SshCredentialStore.remove(device.id, credentialKind);
    }
    return true;
  }

  private handleDeviceCommitted(device: ManagedDevice): void {
    this.selectDevice(device.id);
    this.disconnectDevice(device.id);
    this.connectDevice(device, false).catch((error: Error) => {
      console.error('TERMINAI connect committed SSH device failed: ' + error.message);
    });
  }

  private handleDeviceRemoved(device: ManagedDevice): void {
    this.disconnectDevice(device.id, true);
    SshCredentialStore.removeAll(device.id).catch(() => {});
    const context = this.getUIContext().getHostContext();
    if (context !== undefined) {
      SshIdentityStore.removeManaged(context.filesDir, device.identityFile).catch(() => {});
    }
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

  private buildMasterCommand(connection: SshRuntimeConnection, device: ManagedDevice): string {
    const target = normalizedSshTarget(connection.target);
    const knownHosts = this.connectionFilePath(connection.deviceId, '-known-hosts');
    // HarmonyOS user/app data filesystems do not reliably support OpenSSH's
    // Unix-domain ControlPath socket. Keep one lightweight validation
    // connection, while terminals authenticate independently from Asset Store.
    return '/usr/bin/ssh -N -o ConnectTimeout=10 -o ServerAliveInterval=15 ' +
      '-o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new ' +
      sshAuthenticationArguments(device) + ' ' +
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

    const generation = connection.beginAttempt();
    connection.target = device.sshTarget;
    connection.controlPath = '';
    connection.credentialAvailable = false;
    connection.connectedMarkerSeen = false;
    connection.authOutput = '';
    connection.scanOutput = '';
    this.setConnectionState(connection, SshConnectionState.Connecting);

    const secret = new SshSecretValue(await SshCredentialStore.loadForDevice(device));
    if (!connection.isCurrentAttempt(generation) ||
      connection.state !== SshConnectionState.Connecting) {
      secret.value = '';
      return;
    }
    try {
      const command = this.buildMasterCommand(connection, device);
      const activeConnection: SshRuntimeConnection = connection;
      connection.credentialAvailable = secret.value.length > 0;
      const nativeId = libterminal.createSessionWithSecret(80, 24, '~', command, secret.value,
        (event: SessionEvent) => {
          this.handleMasterEvent(activeConnection, generation, event);
        });
      secret.value = '';
      if (!connection.completeMasterStart(generation, nativeId) &&
        !connection.isCurrentAttempt(generation)) {
        this.cleanupNativeSession(nativeId);
      }
    } catch (e) {
      secret.value = '';
      if (connection.isCurrentAttempt(generation)) {
        this.failConnection(connection, generation, SshConnectionState.Failed,
          '无法创建 SSH 连接进程', false);
      }
    }
  }

  private failConnection(connection: SshRuntimeConnection, generation: number,
    state: SshConnectionState, reason: string, retryable: boolean): void {
    if (!connection.isCurrentAttempt(generation)) {
      return;
    }
    const masterId = connection.masterId;
    connection.markMasterExited(generation);
    connection.connectedMarkerSeen = false;
    connection.lastError = reason;
    this.setConnectionState(connection, state);
    this.cleanupNativeSession(masterId);
    if (retryable) {
      this.scheduleConnectionRetry(connection, reason);
    } else {
      this.cancelPendingRemoteSessions(connection, reason);
    }
  }

  /**
   * A credential or host-key failure cannot recover through backoff. Pending
   * requests must not remain in savedSessions and unexpectedly open after a
   * later successful login.
   */
  private cancelPendingRemoteSessions(connection: SshRuntimeConnection, reason: string): void {
    const count = connection.pendingSessions.length;
    connection.pendingSessions = [];
    connection.openTerminalOnReady = false;
    this.backend.schedulePersistence();
    if (count <= 0) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showToast({
        message: reason + '，已取消 ' + count.toString() + ' 个待创建会话'
      });
    } catch (error) {
      console.error('TERMINAI show cancelled pending sessions failed: ' + JSON.stringify(error));
    }
  }

  private scheduleConnectionRetry(connection: SshRuntimeConnection, reason: string): void {
    if (connection.manualDisconnect) {
      return;
    }
    const scanId = connection.scanId;
    if (scanId > 0) {
      connection.markScanExited(connection.attemptGeneration);
      this.cleanupNativeSession(scanId);
    }
    const device = decodeDevices(this.devicesEncoded).find((item: ManagedDevice) =>
      item.id === connection.deviceId);
    if (device === undefined) {
      this.setConnectionState(connection, SshConnectionState.Disconnected);
      return;
    }
    connection.clearRetryTimer();
    const delay = connection.nextRetryDelay();
    connection.lastError = reason;
    connection.nextRetryAt = Date.now() + delay;
    this.setConnectionState(connection, SshConnectionState.Reconnecting);
    connection.retryTimer = setTimeout(() => {
      connection.retryTimer = -1;
      connection.nextRetryAt = 0;
      if (connection.manualDisconnect) {
        return;
      }
      this.connectDevice(device, false).catch(() => {
        if (!connection.manualDisconnect && connection.state !== SshConnectionState.Reconnecting) {
          this.scheduleConnectionRetry(connection, 'SSH 自动重连失败');
        }
      });
    }, delay);
  }

  private handleMasterEvent(connection: SshRuntimeConnection, generation: number,
    event: SessionEvent): void {
    if (!connection.acceptMasterEvent(generation, event.id)) {
      return;
    }
    if (event.kind === 'output') {
      // Classify the complete incoming chunk before bounding retained output.
      // Otherwise a large login banner can push an error at the beginning of
      // the same native event outside a small rolling window.
      const combinedAuthOutput = connection.authOutput + event.data;
      const lower = combinedAuthOutput.toLowerCase();
      connection.authOutput = combinedAuthOutput.slice(-65536);
      if (combinedAuthOutput.indexOf(SSH_CONNECTED_MARKER) >= 0 && !connection.connectedMarkerSeen) {
        connection.connectedMarkerSeen = true;
        connection.markConnected();
        this.startRemoteAgentScan(connection, generation).catch(() => {
          this.finishRemoteScan(connection, generation, false);
        });
        return;
      }
      if (lower.indexOf('permission denied') >= 0) {
        this.failConnection(connection, generation, SshConnectionState.AuthFailed,
          'SSH 登录凭据被拒绝', false);
      } else if (lower.indexOf('host key verification failed') >= 0 ||
        lower.indexOf('remote host identification has changed') >= 0) {
        this.failConnection(connection, generation, SshConnectionState.HostKeyFailed,
          'SSH 主机密钥校验失败', false);
      } else if (lower.indexOf('connection refused') >= 0 ||
        lower.indexOf('no route to host') >= 0 || lower.indexOf('connection timed out') >= 0 ||
        lower.indexOf('operation timed out') >= 0) {
        this.failConnection(connection, generation, SshConnectionState.NetworkFailed,
          'SSH 主机暂时不可达', true);
      } else if (this.hasSshCredentialPrompt(lower)) {
        // The native PTY reader injects a stored password or key passphrase
        // before this asynchronous UI callback runs. Check fatal errors first
        // because a single PTY chunk may contain both prompt and rejection.
        if (!connection.credentialAvailable) {
          this.failConnection(connection, generation, SshConnectionState.NeedsCredential,
            'SSH 主机要求登录凭据', false);
        }
      }
      return;
    }
    if (event.kind === 'exit') {
      this.cleanupNativeSession(event.id);
      connection.markMasterExited(generation);
      if (connection.connectedMarkerSeen) {
        connection.connectedMarkerSeen = false;
        this.scheduleConnectionRetry(connection, 'SSH 连接已中断');
      } else if (connection.state === SshConnectionState.Connecting) {
        const lower = connection.authOutput.toLowerCase();
        if (lower.indexOf('permission denied') >= 0) {
          this.setConnectionState(connection, SshConnectionState.AuthFailed);
          this.cancelPendingRemoteSessions(connection, 'SSH 登录凭据被拒绝');
        } else {
          connection.lastError = 'SSH 连接在认证完成前退出';
          this.scheduleConnectionRetry(connection, connection.lastError);
        }
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

  private hasSshCredentialPrompt(lowerOutput: string): boolean {
    return lowerOutput.indexOf('password:') >= 0 ||
      lowerOutput.indexOf('enter passphrase for key') >= 0 ||
      lowerOutput.indexOf('passphrase:') >= 0;
  }

  private buildRemoteScanCommand(connection: SshRuntimeConnection, device: ManagedDevice): string {
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
    return '/usr/bin/ssh -T -o ConnectTimeout=10 ' +
      '-o StrictHostKeyChecking=accept-new -o ' +
      this.shellQuote('UserKnownHostsFile=' + knownHosts) + ' ' +
      sshAuthenticationArguments(device) + ' -- ' +
      this.shellQuote(normalizedSshTarget(connection.target)) + ' ' + this.shellQuote(remoteScript);
  }

  private async startRemoteAgentScan(connection: SshRuntimeConnection,
    generation: number): Promise<void> {
    if (!connection.isCurrentAttempt(generation)) {
      return;
    }
    if (connection.scanId > 0) {
      return;
    }
    connection.scanOutput = '';
    this.setConnectionState(connection, SshConnectionState.Scanning);
    const device = decodeDevices(this.devicesEncoded).find((item: ManagedDevice) =>
      item.id === connection.deviceId);
    if (device === undefined) {
      this.finishRemoteScan(connection, generation, false);
      return;
    }
    const secret = new SshSecretValue(await SshCredentialStore.loadForDevice(device));
    if (!connection.isCurrentAttempt(generation) ||
      connection.state !== SshConnectionState.Scanning) {
      secret.value = '';
      return;
    }
    try {
      const command = this.buildRemoteScanCommand(connection, device);
      const nativeId = libterminal.createSessionWithSecret(80, 24, '~', command, secret.value,
        (event: SessionEvent) => {
          this.handleRemoteScanEvent(connection, generation, event);
        });
      secret.value = '';
      if (!connection.completeScanStart(generation, nativeId) &&
        !connection.isCurrentAttempt(generation)) {
        this.cleanupNativeSession(nativeId);
      }
    } catch (e) {
      secret.value = '';
      this.finishRemoteScan(connection, generation, false);
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

  private parseRemoteAgents(connection: SshRuntimeConnection): RemoteAgentInfo[] {
    const agents: RemoteAgentInfo[] = [];
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

  private handleRemoteScanEvent(connection: SshRuntimeConnection, generation: number,
    event: SessionEvent): void {
    if (!connection.acceptScanEvent(generation, event.id)) {
      return;
    }
    if (event.kind === 'output') {
      connection.scanOutput += event.data;
      return;
    }
    if (event.kind === 'exit') {
      this.cleanupNativeSession(event.id);
      connection.markScanExited(generation);
      this.finishRemoteScan(connection, generation, event.exitCode === 0);
    }
  }

  private finishRemoteScan(connection: SshRuntimeConnection, generation: number,
    success: boolean): void {
    if (!connection.isCurrentAttempt(generation) || connection.masterId <= 0) {
      return;
    }
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
    while (connection.pendingSessions.length > 0) {
      const request = connection.pendingSessions[0];
      connection.pendingSessions.splice(0, 1);
      const detectedShell = (request.cmd.length === 0 && request.label.length === 0) ?
        (connection.remoteShell.length > 0 ? connection.remoteShell : 'sh') : 'zsh';
      const shellName = request.shellName.length > 0 ? request.shellName : detectedShell;
      this.newSession(request.cwd, request.cmd, request.label, request.iconKind, device, shellName,
        request.title, request.manualTitle, request.sequence, request.focusSession);
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
      const store = TerminaiPreferences.get(context);
      store.putSync(PREF_REMOTE_AGENTS, this.remoteAgentsEncoded);
      store.flushSync();
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
      const store = TerminaiPreferences.get(context);
      let map: Record<string, string> = {};
      try {
        map = JSON.parse(store.getSync(PREF_REMOTE_SHELLS, '{}') as string) as Record<string, string>;
      } catch (e) {
        map = {};
      }
      map[deviceId] = shell;
      store.putSync(PREF_REMOTE_SHELLS, JSON.stringify(map));
      store.flushSync();
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
      const store = TerminaiPreferences.get(ctx);
      const size = store.getSync(PREF_FONT_SIZE, 14) as number;
      const bold = store.getSync(PREF_FONT_BOLD, false) as boolean;
      const mode = store.getSync(PREF_THEME_MODE, 'system') as string;
      const accent = store.getSync(PREF_ACCENT, '') as string;
      const savedCustomAgents = store.getSync(PREF_CUSTOM_AGENTS, '') as string;
      const savedDevices = store.getSync(PREF_DEVICES, '') as string;
      const savedRemoteAgents = store.getSync(PREF_REMOTE_AGENTS, '') as string;
      const savedLastPrograms = store.getSync(PREF_LAST_PROGRAMS, '') as string;
      this.savedSessionsEncoded = store.getSync(PREF_SAVED_SESSIONS, '') as string;
      this.savedCurrentSessionIndex = store.getSync(PREF_CURRENT_SESSION, -1) as number;
      console.info('TERMINAI session snapshot loaded count=' +
        decodeSavedSessions(this.savedSessionsEncoded).length.toString() +
        ' selected=' + this.savedCurrentSessionIndex.toString());
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
      AppStorage.setOrCreate('notifyEnabled', store.getSync(PREF_NOTIFY_ENABLED, false) as boolean);
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
      AppStorage.setOrCreate('lastProgramsByDevice', savedLastPrograms);
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
      const store = TerminaiPreferences.get(ctx);
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
      store.putSync(PREF_LAST_PROGRAMS, this.lastProgramsByDevice);
      // Device, credential catalog and custom-agent writes have dedicated
      // commit paths. Do not rewrite those keys from this debounce, otherwise
      // two snapshots can race during process termination.
      store.flushSync();
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
    this.scheduleStylePrefsSave();
  }

  onStyleChanged(): void {
    if (this.loadingStylePrefs) {
      return;
    }
    this.scheduleStylePrefsSave();
  }

  onNotifyEnabledChanged(): void {
    this.onStyleChanged();
    if (!this.notifyEnabled) {
      SessionNotificationService.cancelAll();
    }
  }

  onAppForegroundChanged(): void {
    if (!this.appForeground) {
      return;
    }
    const current = this.currentSession();
    if (current !== null) {
      this.backend.setSelectedSessionUid(current.uid);
      SessionNotificationService.cancelSession(current.uid);
    }
  }

  onNotificationSessionRequestChanged(): void {
    this.routeNotificationSelection();
  }

  private routeNotificationSelection(): void {
    const separator = this.notificationSessionRequest.indexOf(':');
    const uidText = separator >= 0 ?
      this.notificationSessionRequest.substring(0, separator) : this.notificationSessionRequest;
    const uid = Number.parseInt(uidText);
    if (!Number.isFinite(uid) || uid <= 0) {
      return;
    }
    const index = this.sessions.findIndex((session: TerminalSession) => session.uid === uid);
    if (index >= 0) {
      const target = this.sessions[index];
      if (this.selectedDeviceId.length > 0 && this.selectedDeviceId !== target.deviceId) {
        this.selectDevice(target.deviceId);
      }
      this.currentIdx = index;
      SessionNotificationService.cancelSession(uid);
    }
  }

  private scheduleStylePrefsSave(): void {
    if (this.loadingStylePrefs) {
      return;
    }
    if (this.styleSaveTimer >= 0) {
      clearTimeout(this.styleSaveTimer);
    }
    this.styleSaveTimer = setTimeout(() => {
      this.styleSaveTimer = -1;
      this.saveStylePrefs();
    }, STYLE_SAVE_DELAY);
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
      const store = TerminaiPreferences.get(ctx);
      store.putSync(PREF_RECENT_PATHS, JSON.stringify(list));
      store.flushSync();
    } catch (e) {
      console.error('TERMINAI save recents failed: ' + JSON.stringify(e));
    }
  }

  private newSession(startCwd: string = '', cmd: string = '', label: string = '',
    iconKind: string = '', device: ManagedDevice = localDevice(), shellName: string = '',
    restoredTitle: string = '', restoredManualTitle: boolean = false,
    preferredSequence: number = 0, focusSession: boolean = true): TerminalSession | null {
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
        connection.pendingSessions.push(new PendingRemoteSession(cwd, cmd, label, iconKind,
          restoredTitle, restoredManualTitle, preferredSequence, finalShell, focusSession));
        this.saveSessionsSoon();
        this.connectDevice(device, false).catch(() => {});
        return null;
      }
      controlPath = connection.controlPath;
      knownHostsPath = this.connectionFilePath(device.id, '-known-hosts');
    }
    const s = this.mgr.newSession(cwd, cmd, label, iconKind, device.id, device.name,
      device.sshTarget, controlPath, knownHostsPath, finalShell, preferredSequence);
    if (restoredTitle.length > 0) {
      s.name = restoredTitle;
      s.manualTitle = restoredManualTitle;
    }
    this.bindSessionCallbacks(s);
    this.sessions = [...this.mgr.sessions];
    if (focusSession || this.currentIdx < 0) {
      this.currentIdx = this.sessions.length - 1;
    }
    this.saveSessionsSoon();
    return s;
  }

  private bindSessionCallbacks(s: TerminalSession): void {
    s.onStateChanged = () => {
      // Keep exited sessions visible until the user closes them so the
      // "会话已退出" state remains truthful and recoverable.
      this.sessions = [...this.sessions];
      if (s.uid === this.splitSessionUid && !s.alive && s.nativeStartCompleted &&
        !s.startInProgress) {
        this.splitSessionUid = -1;
        this.splitPaneSession = null;
        this.splitPaneCwd = '';
        this.splitFocused = false;
        this.terminalFocusRequest++;
        setTimeout(() => {
          if (this.mgr.sessions.some((session: TerminalSession) => session.uid === s.uid)) {
            this.closeSession(s);
          }
        }, 0);
      }
    };
    s.onMetadataChanged = () => { this.saveSessionsSoon(); };
    s.onCwdChanged = () => {
      this.sessions = [...this.sessions];
      if (s.uid === this.splitSessionUid) {
        this.splitPaneCwd = s.cwd;
      }
      this.saveSessionsSoon();
    };
  }

  private closeSession(s: TerminalSession): void {
    const closingIndex = this.sessions.indexOf(s);
    if (closingIndex < 0) {
      return;
    }
    const selected = this.currentSession();
    const selectedUid = selected === null ? -1 : selected.uid;
    const promotedUid = selectedUid === s.uid && this.splitSessionUid > 0 &&
      this.splitSessionUid !== s.uid ? this.splitSessionUid : -1;
    if (s.uid === this.splitSessionUid || promotedUid > 0) {
      this.splitSessionUid = -1;
      this.splitPaneSession = null;
      this.splitPaneCwd = '';
      this.terminalFocusRequest++;
    }
    this.mgr.remove(s);
    SessionNotificationService.cancelSession(s.uid);
    this.sessions = [...this.mgr.sessions];
    this.renderedSessionUids = this.renderedSessionUids.filter((uid: number) => uid !== s.uid);
    if (this.sessions.length === 0) {
      this.currentIdx = -1;
    } else if (promotedUid > 0) {
      const promotedIndex = this.sessions.findIndex((item: TerminalSession) => item.uid === promotedUid);
      this.currentIdx = promotedIndex >= 0 ? promotedIndex : Math.min(closingIndex, this.sessions.length - 1);
    } else if (selectedUid >= 0 && selectedUid !== s.uid) {
      const preservedIndex = this.sessions.findIndex((item: TerminalSession) => item.uid === selectedUid);
      if (preservedIndex >= 0) {
        this.currentIdx = preservedIndex;
      } else {
        this.currentIdx = Math.min(closingIndex, this.sessions.length - 1);
      }
    } else {
      // When the selected session is closed, prefer the item that moved into
      // the same position, or the previous item when the last one was closed.
      this.currentIdx = Math.min(closingIndex, this.sessions.length - 1);
    }
    this.saveSessionsSoon();
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

  /** Compare by stable identity; array indexes shift whenever a preceding session closes. */
  private isCurrentSession(session: TerminalSession): boolean {
    const current = this.currentSession();
    return current !== null && current.uid === session.uid;
  }

  private titleSidebarBackground(): string {
    if (this.titleSidebarPressed) {
      return Theme.pressed(this.isDark);
    }
    if (this.titleSidebarHovered) {
      return Theme.hover(this.isDark);
    }
    return '#00000000';
  }

  private showSidebar(): void {
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut },
      () => { this.sidebarCollapsed = false; });
  }

  /**
   * Flex weights expressed in measured vp values keep the title divider at
   * the same x-coordinate as the terminal divider. The system title-button
   * inset belongs inside the trailing title segment; removing it from the
   * parent width would shift the divider left and break alignment.
   */
  private sharedTitlePrimaryWeight(): number {
    const flexibleWidth = this.workspaceWidth - 1;
    if (flexibleWidth <= 2) {
      return this.splitRatio;
    }
    const target = this.workspaceWidth * this.splitRatio;
    return Math.max(1, Math.min(flexibleWidth - 1, target));
  }

  private sharedTitleSecondaryWeight(): number {
    const flexibleWidth = this.workspaceWidth - 1;
    if (flexibleWidth <= 2) {
      return 1 - this.splitRatio;
    }
    return Math.max(1, flexibleWidth - this.sharedTitlePrimaryWeight());
  }

  @Builder
  titleSidebarButton() {
    Row() {
      UiIcon({
        name: IconName.SidebarShow,
        iconSize: 16,
        color: Theme.subText(this.isDark)
      })
    }
    .width(30)
    .height(28)
    .justifyContent(FlexAlign.Center)
    .margin({ left: 8, right: 2 })
    .backgroundColor(this.titleSidebarBackground())
    .border({
      width: this.titleSidebarFocused ? 2 : 0,
      color: Theme.accent(this.isDark),
      radius: 7
    })
    .borderRadius(7)
    .scale({
      x: this.titleSidebarPressed ? 0.96 : 1,
      y: this.titleSidebarPressed ? 0.96 : 1
    })
    .focusable(true)
    .focusOnTouch(true)
    .onFocus(() => { this.titleSidebarFocused = true; })
    .onBlur(() => { this.titleSidebarFocused = false; })
    .onHover((isHover: boolean) => {
      this.titleSidebarHovered = isHover;
      if (!isHover) {
        this.titleSidebarPressed = false;
      }
    })
    .onMouse((event: MouseEvent) => {
      if (event.button === MouseButton.Left) {
        this.titleSidebarPressed = event.action === MouseAction.Press;
      }
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.titleSidebarPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.titleSidebarPressed = false;
      }
    })
    .onClick(() => { this.showSidebar(); })
    .accessibilityText('显示侧边栏')
  }

  @Builder
  detailTitlebar() {
    Row() {
      if (this.sidebarCollapsed) {
        this.titleSidebarButton()
      }
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
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({
              maxWidth: this.splitPaneSession === null || this.splitHorizontal ? 360 : 220
            })
            .margin({ left: 7 })
          SessionNumberBadge({ value: this.currentSession()!.sequence, isDark: this.isDark })
            .margin({ left: 6 })
          Blank()
          Text(this.displayCwd(this.currentSession()!.cwd))
            .fontSize(12)
            .fontColor(Theme.tertiary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({
              maxWidth: this.splitPaneSession === null || this.splitHorizontal ? 260 : 160
            })
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
      .layoutWeight(this.splitPaneSession !== null && !this.splitHorizontal ?
        this.sharedTitlePrimaryWeight() : 1)
      .padding({
        left: this.sidebarCollapsed ? 6 : 16,
        right: this.splitPaneSession !== null && !this.splitHorizontal ? 10 :
          this.titleButtonInset + 10
      })
      .focusable(true)
      .focusOnTouch(true)
      .onTouch((event: TouchEvent) => {
        this.handleTitleTouch(event);
      })

      // Left/right panes share the application title bar. A top/bottom split
      // gives the lower pane its own local title because it is not adjacent to
      // the application title bar.
      if (this.splitPaneSession !== null && !this.splitHorizontal) {
        Divider()
          .vertical(true)
          .height(20)
          .strokeWidth(1)
          .color(Theme.divider(this.isDark))

        Row() {
          Text('分屏')
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.accent(this.isDark))
            .height(19)
            .padding({ left: 6, right: 6 })
            .backgroundColor(Theme.accentWash(this.isDark))
            .borderRadius(6)
          UiIcon({
            name: IconName.Terminal,
            iconSize: 13,
            color: this.splitFocused ? Theme.accent(this.isDark) : Theme.tertiary(this.isDark)
          })
            .margin({ left: 8 })
          Text(this.programLabel(this.splitPaneSession!))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 120 })
            .margin({ left: 6 })
          Blank()
          Text(this.displayCwd(this.splitPaneCwd))
            .fontSize(12)
            .fontColor(Theme.tertiary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 180 })
        }
        .height('100%')
        .layoutWeight(this.sharedTitleSecondaryWeight())
        .padding({ left: 10, right: this.titleButtonInset + 10 })
        .focusable(true)
        .focusOnTouch(true)
        .onTouch((event: TouchEvent) => {
          this.handleTitleTouch(event);
        })
        .accessibilityGroup(true)
        .accessibilityText('分屏，程序 ' + this.programLabel(this.splitPaneSession!) +
          '，空间 ' + this.displayCwd(this.splitPaneCwd))
      }
    }
    .width('100%')
    .height(40)
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

  private handleAppShortcut(keyCode: number, shift: boolean, alt: boolean = false): void {
    // Ctrl+Alt+... combinations are reserved: only the split toggle uses one.
    if (alt && keyCode !== KEYCODE_D) {
      return;
    }
    switch (keyCode) {
      case KEYCODE_K:
        this.paletteCtrl.open();
        break;
      case KEYCODE_B:
        this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut },
          () => { this.sidebarCollapsed = !this.sidebarCollapsed; });
        break;
      case KEYCODE_D:
        if (alt) {
          this.openSplit(shift);
        }
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
        if (this.splitSession() !== null && this.splitFocused) {
          this.closeSplit();
        } else if (this.currentIdx >= 0 && this.currentIdx < this.sessions.length) {
          this.closeSession(this.sessions[this.currentIdx]);
        }
        break;
      default:
        break;
    }
  }

  @Builder
  primaryTerminalPane() {
    Stack() {
      ForEach(this.primaryPaneSessions, (s: TerminalSession) => {
        Column() {
          TerminalView({
            session: s,
            active: this.isCurrentSession(s),
            focusEligible: !this.splitFocused,
            focusRequest: this.terminalFocusRequest,
            layoutRefreshRequest: this.terminalLayoutRefreshRequest,
            onViewFocus: (uid: number) => { this.onPaneFocused(uid); },
            onCloseSession: (uid: number) => {
              const target = this.sessions.find((item: TerminalSession) => item.uid === uid);
              if (target !== undefined) this.closeSession(target);
            },
            onShortcut: (keyCode: number, shift: boolean, alt: boolean) => {
              this.handleAppShortcut(keyCode, shift, alt);
            }
          })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .visibility(this.isCurrentSession(s) ? Visibility.Visible : Visibility.Hidden)
      }, (s: TerminalSession) => 'term_' + s.uid.toString())

      if (this.sessions.length === 0) {
        Column() {
          this.emptyState()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.terminalBg(this.isDark))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.terminalBg(this.isDark))
  }

  @Builder
  splitTerminalPane(session: TerminalSession) {
    Column() {
      if (this.splitHorizontal) {
        Row() {
          Text('分屏')
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.accent(this.isDark))
            .height(19)
            .padding({ left: 6, right: 6 })
            .backgroundColor(Theme.accentWash(this.isDark))
            .borderRadius(6)
          UiIcon({
            name: IconName.Terminal,
            iconSize: 13,
            color: this.splitFocused ? Theme.accent(this.isDark) : Theme.tertiary(this.isDark)
          })
            .margin({ left: 8 })
          Text(this.programLabel(session))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 160 })
            .margin({ left: 6 })
          Blank()
          Text(this.displayCwd(this.splitPaneCwd))
            .fontSize(12)
            .fontColor(Theme.tertiary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 260 })
        }
        .width('100%')
        .height(30)
        .padding({ left: 10, right: 10 })
        .backgroundColor(Theme.windowBg(this.isDark))
        .accessibilityGroup(true)
        .accessibilityText('分屏，程序 ' + this.programLabel(session) +
          '，空间 ' + this.displayCwd(this.splitPaneCwd))
      }

      TerminalView({
        session: session,
        active: true,
        focusEligible: this.splitFocused,
        focusRequest: this.terminalFocusRequest,
        layoutRefreshRequest: this.terminalLayoutRefreshRequest,
        onViewFocus: (uid: number) => { this.onPaneFocused(uid); },
        onCloseSession: (uid: number) => {
          const target = this.sessions.find((item: TerminalSession) => item.uid === uid);
          if (target !== undefined) this.closeSession(target);
        },
        onShortcut: (keyCode: number, shift: boolean, alt: boolean) => {
          this.handleAppShortcut(keyCode, shift, alt);
        }
      })
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.terminalBg(this.isDark))
  }

  @Builder
  splitDivider() {
    if (this.splitHorizontal) {
      Column()
        .width('100%')
        .height(3)
        .backgroundColor(this.splitDividerHovered || this.splitDragging ?
          Theme.accent(this.isDark) : Theme.divider(this.isDark))
        .onHover((isHover: boolean) => {
          this.splitDividerHovered = isHover;
          if (isHover) {
            cursorControl.setCursor(pointer.PointerStyle.NORTH_SOUTH);
          } else {
            cursorControl.restoreDefault();
          }
        })
        .onMouse((event: MouseEvent) => {
          if (event.button !== MouseButton.Left) return;
          if (event.action === MouseAction.Press) {
            this.splitDragging = true;
            this.splitDragStartY = event.windowY;
            this.splitDragStartRatio = this.splitRatio;
          } else if (event.action === MouseAction.Move && this.splitDragging) {
            const delta = event.windowY - this.splitDragStartY;
            if (this.workspaceHeight > 0) {
              this.splitRatio = Math.min(0.8,
                Math.max(0.2, this.splitDragStartRatio + delta / this.workspaceHeight));
            }
          } else if (event.action === MouseAction.Release) {
            this.splitDragging = false;
          }
        })
    } else {
      Column()
        .width(3)
        .height('100%')
        .backgroundColor(this.splitDividerHovered || this.splitDragging ?
          Theme.accent(this.isDark) : Theme.divider(this.isDark))
        .onHover((isHover: boolean) => {
          this.splitDividerHovered = isHover;
          if (isHover) {
            cursorControl.setCursor(pointer.PointerStyle.WEST_EAST);
          } else {
            cursorControl.restoreDefault();
          }
        })
        .onMouse((event: MouseEvent) => {
          if (event.button !== MouseButton.Left) return;
          if (event.action === MouseAction.Press) {
            this.splitDragging = true;
            this.splitDragStartX = event.windowX;
            this.splitDragStartRatio = this.splitRatio;
          } else if (event.action === MouseAction.Move && this.splitDragging) {
            const delta = event.windowX - this.splitDragStartX;
            if (this.workspaceWidth > 0) {
              this.splitRatio = Math.min(0.8,
                Math.max(0.2, this.splitDragStartRatio + delta / this.workspaceWidth));
            }
          } else if (event.action === MouseAction.Release) {
            this.splitDragging = false;
          }
        })
    }
  }

  @Builder
  terminalWorkspace() {
    Column() {
      if (this.splitPaneSession !== null) {
        if (this.splitHorizontal) {
          Column() {
            this.primaryTerminalPane()
          }
          .width('100%')
          .height((this.splitRatio * 100).toString() + '%')
          this.splitDivider()
          Column() {
            this.splitTerminalPane(this.splitPaneSession!)
          }
          .width('100%')
          .layoutWeight(1)
        } else {
          Row() {
            Column() {
              this.primaryTerminalPane()
            }
            .height('100%')
            .width((this.splitRatio * 100).toString() + '%')
            this.splitDivider()
            Column() {
              this.splitTerminalPane(this.splitPaneSession!)
            }
            .height('100%')
            .layoutWeight(1)
          }
          .width('100%')
          .height('100%')
        }
      } else {
        this.primaryTerminalPane()
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.workspaceWidth = newValue.width as number;
      this.workspaceHeight = newValue.height as number;
    })
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
          splitSessionUid: this.splitSessionUid,
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
            const inSpace = (it: TerminalSession): boolean =>
              it.deviceId === deviceId && canonicalSessionCwd(it) === cwd;
            // Prefer an agent session; a space often also holds the plain
            // terminal that SSH auto-open created.
            let idx = this.sessions.findIndex((it: TerminalSession) =>
              inSpace(it) && it.cmd.length > 0);
            if (idx < 0) {
              idx = this.sessions.findIndex((it: TerminalSession) => inSpace(it));
            }
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
          onSplit: () => { this.openSplit(false); },
          onCloseSession: (s: TerminalSession) => this.closeSession(s),
          onSelectSession: (uid: number) => {
            if (uid === this.splitSessionUid) {
              // Keep the split arrangement; just hand the pane focus.
              this.splitFocused = true;
              this.terminalFocusRequest++;
              return;
            }
            const idx = this.sessions.findIndex((it: TerminalSession) => it.uid === uid);
            if (idx >= 0) {
              this.currentIdx = idx;
              this.splitFocused = false;
            }
          },
          onRenameSession: (s: TerminalSession, name: string) => {
            s.markManualTitle();
            s.name = this.capitalizeSessionName(name);
            this.sessions = [...this.sessions];
            this.saveSessionsSoon();
          },
          onOpenSettings: () => { this.openSettings(); },
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

          Column() {
            this.terminalWorkspace()
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
      if (event.keyCode === KEYCODE_ALT_LEFT || event.keyCode === KEYCODE_ALT_RIGHT) {
        this.altDown = (event.type === KeyType.Down);
        return;
      }
      if (event.type !== KeyType.Down) return;
      if (!this.ctrlDown) {
        return;
      }
      this.handleAppShortcut(event.keyCode, this.shiftDown, this.altDown);
    })
  }
}
