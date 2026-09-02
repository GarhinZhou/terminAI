import libterminal from 'libterminal.so';
import { common } from '@kit.AbilityKit';
import { SshRuntimeConnection } from './RemoteSshState';
import { AgentRunState, SessionManager, SessionProcessInfo, SessionRuntimePhase,
  SessionRuntimeSnapshot, TerminalSession } from './TerminalSession';
import { SessionNotificationService } from './SessionNotificationService';
import { encodeSavedSessions, SavedSessionInfo } from './SessionPersistence';
import { TerminaiPreferences } from './TerminaiPreferences';

const FOREGROUND_ACTIVITY_TICK_INTERVAL = 250;
const BACKGROUND_ACTIVITY_TICK_INTERVAL = 1000;
const ACTIVE_PROCESS_INSPECTION_INTERVAL = 750;
const BACKGROUND_PROCESS_INSPECTION_INTERVAL = 2500;
const PROCESS_INSPECTION_TIMEOUT = 3500;
const PREF_SAVED_SESSIONS = 'savedSessions';
const PREF_CURRENT_SESSION = 'currentSessionIndex';
const SESSION_PERSIST_DELAY = 80;

/**
 * Process-owned terminal runtime. ArkUI pages are replaceable clients of this
 * backend; hiding or rebuilding a window must not own or terminate PTY state.
 */
export class ResidentSessionBackend {
  private static instance: ResidentSessionBackend = new ResidentSessionBackend();

  readonly sessionManager: SessionManager = new SessionManager();
  readonly sshConnections: SshRuntimeConnection[] = [];
  private selectedSessionUid: number = -1;
  private stateSubscriptions: Map<number, number> = new Map();
  private outputSubscriptions: Map<number, number> = new Map();
  private notificationStates: Map<number, AgentRunState> = new Map();
  private activityTimer: number = -1;
  private activityInspectionInFlight: boolean = false;
  private activityInspectionGeneration: number = 0;
  private activityInspectionTimer: number = -1;
  private activityScanCursor: number = 0;
  private persistenceContext: common.Context | undefined = undefined;
  private persistenceTimer: number = -1;
  private shuttingDown: boolean = false;

  private constructor() {
    this.sessionManager.onSessionAdded = (session: TerminalSession) => {
      this.attachSession(session);
      this.schedulePersistence();
    };
    this.sessionManager.onSessionRemoving = (session: TerminalSession) => {
      this.detachSession(session);
      this.schedulePersistence();
    };
  }

  static shared(): ResidentSessionBackend {
    return ResidentSessionBackend.instance;
  }

  configure(context: common.Context, resumePersistence: boolean = true): void {
    this.persistenceContext = context;
    // Only the visible EntryAbility starts a new persistence lifecycle. The
    // resident Ability may be created late while an explicit exit is already
    // in progress and must not rearm a backend that is tearing down.
    if (resumePersistence) {
      this.shuttingDown = false;
    }
    this.startMonitoring();
  }

  setSelectedSessionUid(uid: number): void {
    this.selectedSessionUid = uid;
    const selected = this.sessionManager.sessions.find((session: TerminalSession) => session.uid === uid);
    if (selected !== undefined) {
      selected.markUnread(false);
    }
    this.schedulePersistence();
  }

  /** Starts process-owned monitoring once; it survives every ArkUI page/window rebuild. */
  startMonitoring(): void {
    for (const session of this.sessionManager.sessions) {
      this.attachSession(session);
    }
    this.ensureActivityTimer();
  }

  selectedSession(): number {
    return this.selectedSessionUid;
  }

  liveSessionCount(): number {
    let count = 0;
    for (const session of this.sessionManager.sessions) {
      if (session.alive || session.id > 0 || session.startInProgress ||
        !session.nativeStartCompleted) {
        count++;
      }
    }
    return count;
  }

  hasRuntimeSessions(): boolean {
    return this.sessionManager.sessions.length > 0;
  }

  runtimeSnapshots(): SessionRuntimeSnapshot[] {
    return this.sessionManager.runtimeSnapshots();
  }

  /** Returns invariant failures without throwing from a native event callback. */
  validateRuntimeInvariants(): string[] {
    const failures: string[] = [];
    const seenUids: number[] = [];
    const seenNativeIds: number[] = [];
    for (const snapshot of this.runtimeSnapshots()) {
      if (snapshot.uid <= 0 || seenUids.indexOf(snapshot.uid) >= 0) {
        failures.push('重复或无效的逻辑会话 UID：' + snapshot.uid.toString());
      } else {
        seenUids.push(snapshot.uid);
      }
      if (snapshot.nativeId > 0) {
        if (seenNativeIds.indexOf(snapshot.nativeId) >= 0) {
          failures.push('原生会话被多个逻辑会话占用：' + snapshot.nativeId.toString());
        } else {
          seenNativeIds.push(snapshot.nativeId);
        }
      }
      if (snapshot.phase === SessionRuntimePhase.Running && snapshot.nativeId <= 0) {
        failures.push('运行中的会话缺少原生 ID：UID ' + snapshot.uid.toString());
      }
      if (snapshot.phase === SessionRuntimePhase.Disposed) {
        failures.push('已释放的会话仍存在于运行时列表：UID ' + snapshot.uid.toString());
      }
    }
    return failures;
  }

  logRuntimeInvariantFailures(): void {
    for (const failure of this.validateRuntimeInvariants()) {
      console.error('TERMINAI runtime invariant failed: ' + failure);
    }
  }

  private attachSession(session: TerminalSession): void {
    if (!this.stateSubscriptions.has(session.uid)) {
      const observerId = session.subscribeState(() => {
        this.handleSessionState(session);
      });
      this.stateSubscriptions.set(session.uid, observerId);
      this.notificationStates.set(session.uid, session.activityState);
    }
    if (!this.outputSubscriptions.has(session.uid)) {
      const observerId = session.subscribeOutput(() => {
        this.handleSessionOutput(session);
      });
      this.outputSubscriptions.set(session.uid, observerId);
    }
    this.ensureActivityTimer();
  }

  private detachSession(session: TerminalSession): void {
    const observerId = this.stateSubscriptions.get(session.uid);
    if (observerId !== undefined) {
      session.unsubscribeState(observerId);
      this.stateSubscriptions.delete(session.uid);
    }
    const outputObserverId = this.outputSubscriptions.get(session.uid);
    if (outputObserverId !== undefined) {
      session.unsubscribeOutput(outputObserverId);
      this.outputSubscriptions.delete(session.uid);
    }
    this.notificationStates.delete(session.uid);
    SessionNotificationService.cancelSession(session.uid);
    if (!this.hasMonitorableAgent()) {
      this.stopActivityTimer();
    }
  }

  private handleSessionOutput(session: TerminalSession): void {
    const foreground = AppStorage.get<boolean>('appForeground') ?? false;
    if (!foreground || this.selectedSessionUid !== session.uid) {
      session.markUnread(true);
    }
  }

  private handleSessionState(session: TerminalSession): void {
    const previous = this.notificationStates.get(session.uid) ?? AgentRunState.Unknown;
    const current = session.alive ? session.activityState : AgentRunState.Exited;
    this.notificationStates.set(session.uid, current);
    this.schedulePersistence();
    this.ensureActivityTimer();
    if (previous === current) {
      return;
    }
    if (SessionNotificationService.isAttentionState(current)) {
      const foreground = AppStorage.get<boolean>('appForeground') ?? false;
      const notifyEnabled = AppStorage.get<boolean>('notifyEnabled') ?? false;
      const userIsLooking = foreground && this.selectedSessionUid === session.uid;
      if (notifyEnabled && !userIsLooking) {
        SessionNotificationService.publishSession(session, current)
          .catch((error: Error) => {
            console.error('TERMINAI publish resident session notification failed: ' + error.message);
          });
      }
      return;
    }
    if (current === AgentRunState.Outputting || current === AgentRunState.Silent) {
      SessionNotificationService.cancelSession(session.uid);
    }
  }

  private hasMonitorableAgent(): boolean {
    return this.sessionManager.sessions.some((session: TerminalSession) =>
      session.isAgentSession() && !session.disposed &&
      (session.alive || session.id > 0 || session.startInProgress || !session.nativeStartCompleted));
  }

  private ensureActivityTimer(): void {
    if (this.activityTimer >= 0 || !this.hasMonitorableAgent()) {
      return;
    }
    const foreground = AppStorage.get<boolean>('appForeground') ?? false;
    const delay = foreground ? FOREGROUND_ACTIVITY_TICK_INTERVAL : BACKGROUND_ACTIVITY_TICK_INTERVAL;
    this.activityTimer = setTimeout(() => {
      this.activityTimer = -1;
      this.refreshActivityStates();
      this.ensureActivityTimer();
    }, delay);
  }

  private stopActivityTimer(): void {
    if (this.activityTimer >= 0) {
      clearTimeout(this.activityTimer);
      this.activityTimer = -1;
    }
    if (this.activityInspectionTimer >= 0) {
      clearTimeout(this.activityInspectionTimer);
      this.activityInspectionTimer = -1;
    }
    this.activityInspectionGeneration++;
    this.activityInspectionInFlight = false;
  }

  private refreshActivityStates(): void {
    const sessions = this.sessionManager.sessions;
    const now = Date.now();
    for (const session of sessions) {
      if (session.isAgentSession()) {
        session.updateActivity(now);
      }
    }
    if (!this.hasMonitorableAgent()) {
      this.stopActivityTimer();
      return;
    }
    if (this.activityInspectionInFlight || sessions.length === 0) {
      return;
    }

    let candidate: TerminalSession | undefined = undefined;
    const active = sessions.find((session: TerminalSession) =>
      session.uid === this.selectedSessionUid);
    if (active !== undefined && active.isAgentSession() && active.sshTarget.length === 0 &&
      active.id > 0 && active.alive &&
      now - active.lastProcessInspectionAt >= ACTIVE_PROCESS_INSPECTION_INTERVAL) {
      candidate = active;
    } else {
      const count = sessions.length;
      for (let offset = 0; offset < count; offset++) {
        const index = (this.activityScanCursor + offset) % count;
        const session = sessions[index];
        // /proc observes the local ssh client, not the remote agent. Remote
        // sessions use PTY output plus exact OSC 777 wrapper markers instead.
        if (!session.isAgentSession() || session.sshTarget.length > 0 ||
          session.id <= 0 || !session.alive) {
          continue;
        }
        const interval = session.uid === this.selectedSessionUid ?
          ACTIVE_PROCESS_INSPECTION_INTERVAL : BACKGROUND_PROCESS_INSPECTION_INTERVAL;
        if (now - session.lastProcessInspectionAt < interval) {
          continue;
        }
        candidate = session;
        this.activityScanCursor = (index + 1) % count;
        break;
      }
    }
    if (candidate === undefined) {
      return;
    }
    this.inspectActivity(candidate, now);
  }

  private inspectActivity(candidate: TerminalSession, now: number): void {
    const expectedUid = candidate.uid;
    const expectedNativeId = candidate.id;
    candidate.lastProcessInspectionAt = now;
    this.activityInspectionInFlight = true;
    this.activityInspectionGeneration++;
    const inspectionGeneration = this.activityInspectionGeneration;
    if (this.activityInspectionTimer >= 0) {
      clearTimeout(this.activityInspectionTimer);
    }
    this.activityInspectionTimer = setTimeout(() => {
      if (this.activityInspectionGeneration !== inspectionGeneration) {
        return;
      }
      this.activityInspectionTimer = -1;
      this.activityInspectionGeneration++;
      this.activityInspectionInFlight = false;
      const session = this.findInspectableSession(expectedUid, expectedNativeId);
      if (session !== undefined) {
        session.processSignalAvailable = false;
      }
      console.error('TERMINAI resident process inspection timed out');
    }, PROCESS_INSPECTION_TIMEOUT);
    const inspection: Promise<SessionProcessInfo> = libterminal.inspectSessionAsync(expectedNativeId);
    inspection.then((process: SessionProcessInfo) => {
      if (this.activityInspectionGeneration !== inspectionGeneration) {
        return;
      }
      this.clearInspectionTimer();
      const session = this.findInspectableSession(expectedUid, expectedNativeId);
      if (session !== undefined) {
        session.updateProcess(process);
        session.updateActivity(Date.now());
      }
      this.activityInspectionInFlight = false;
    }).catch((error: Error) => {
      if (this.activityInspectionGeneration !== inspectionGeneration) {
        return;
      }
      this.clearInspectionTimer();
      const session = this.findInspectableSession(expectedUid, expectedNativeId);
      if (session !== undefined) {
        session.processSignalAvailable = false;
      }
      this.activityInspectionInFlight = false;
      console.error('TERMINAI resident process inspection failed: ' + error.message);
    });
  }

  private clearInspectionTimer(): void {
    if (this.activityInspectionTimer >= 0) {
      clearTimeout(this.activityInspectionTimer);
      this.activityInspectionTimer = -1;
    }
  }

  private findInspectableSession(uid: number, nativeId: number): TerminalSession | undefined {
    return this.sessionManager.sessions.find((session: TerminalSession) =>
      session.uid === uid && session.id === nativeId && !session.disposed);
  }

  /** Debounced process-owned persistence remains active after the main page is destroyed. */
  schedulePersistence(): void {
    if (this.shuttingDown || this.persistenceContext === undefined) {
      return;
    }
    if (this.persistenceTimer >= 0) {
      clearTimeout(this.persistenceTimer);
    }
    this.persistenceTimer = setTimeout(() => {
      this.persistenceTimer = -1;
      this.persistSessionsNow();
    }, SESSION_PERSIST_DELAY);
  }

  flushPersistence(): void {
    // A lifecycle callback can arrive after explicit shutdown removed every
    // runtime session. Never let that late callback replace the pre-exit
    // snapshot with an empty list.
    if (this.shuttingDown) {
      return;
    }
    if (this.persistenceTimer >= 0) {
      clearTimeout(this.persistenceTimer);
      this.persistenceTimer = -1;
    }
    this.persistSessionsNow();
  }

  private persistedSessionItems(): SavedSessionInfo[] {
    const items: SavedSessionInfo[] = [];
    // The restart snapshot must describe exactly the sessions that exist in
    // the user-visible session manager at save time. pendingSessions are only
    // transient SSH connection requests: they have no sidebar card and may be
    // left over from an older failed restore. Persisting them can resurrect an
    // older agent instead of the visible session present when the app closed.
    for (const session of this.sessionManager.sessions) {
      items.push(new SavedSessionInfo(session.cwd, session.cmd, session.agentKind,
        session.agentIconKind, session.deviceId, session.name, session.manualTitle,
        session.sequence, session.shellName));
    }
    return items;
  }

  private persistSessionsNow(): void {
    const context = this.persistenceContext;
    if (context === undefined) {
      return;
    }
    try {
      const store = TerminaiPreferences.get(context);
      const items = this.persistedSessionItems();
      const selectedIndex = this.sessionManager.sessions.findIndex((session: TerminalSession) =>
        session.uid === this.selectedSessionUid);
      store.putSync(PREF_SAVED_SESSIONS, encodeSavedSessions(items));
      store.putSync(PREF_CURRENT_SESSION, selectedIndex);
      store.flushSync();
      console.info('TERMINAI session snapshot saved count=' + items.length.toString() +
        ' selected=' + selectedIndex.toString());
    } catch (error) {
      console.error('TERMINAI resident session persistence failed: ' + JSON.stringify(error));
    }
  }

  removeSshConnection(connection: SshRuntimeConnection): void {
    const index = this.sshConnections.indexOf(connection);
    if (index >= 0) {
      this.sshConnections.splice(index, 1);
    }
  }

  /** Explicit app exit is the only UI flow allowed to tear down the backend. */
  shutdown(): void {
    if (this.shuttingDown) {
      return;
    }
    this.shuttingDown = true;
    if (this.persistenceTimer >= 0) {
      clearTimeout(this.persistenceTimer);
      this.persistenceTimer = -1;
    }
    // Commit the exact pre-teardown snapshot directly. Public lifecycle
    // flushes are blocked after the latch is set, so later onBackground or
    // onDestroy callbacks cannot persist the empty post-removal state.
    this.persistSessionsNow();
    this.stopActivityTimer();
    this.sessionManager.onEvent = () => {};
    this.sessionManager.onRuntimeChanged = () => {};
    this.sessionManager.removeAll();
    for (const connection of this.sshConnections) {
      const scanId = connection.scanId;
      const masterId = connection.masterId;
      // Invalidate callback generations and cancel delayed reconnects before
      // killing native processes. A queued retry must never outlive the app.
      connection.invalidate(true);
      this.stopNativeSession(scanId);
      this.stopNativeSession(masterId);
      connection.scanId = -1;
      connection.masterId = -1;
      connection.pendingSessions = [];
    }
    this.sshConnections.splice(0, this.sshConnections.length);
    this.selectedSessionUid = -1;
  }

  private stopNativeSession(id: number): void {
    if (id <= 0) {
      return;
    }
    libterminal.killSessionAsync(id)
      .catch((error: Error) => {
        console.error('TERMINAI resident backend cleanup failed: ' + error.message);
      });
  }
}
