export enum SshConnectionState {
  Disconnected = '未连接',
  Connecting = '连接中',
  Reconnecting = '等待重连',
  Scanning = '扫描智能体',
  Connected = '已连接',
  ConnectedScanFailed = '已连接（扫描失败）',
  NeedsCredential = '需要凭据',
  AuthFailed = '认证失败',
  HostKeyFailed = '主机密钥异常',
  NetworkFailed = '网络不可达',
  Failed = '连接失败'
}

export class RemoteAgentInfo {
  deviceId: string = '';
  name: string = '';
  path: string = '';
  iconKind: string = '';

  constructor(deviceId: string, name: string, path: string, iconKind: string) {
    this.deviceId = deviceId;
    this.name = name;
    this.path = path;
    this.iconKind = iconKind;
  }
}

/** Mutable holder lets the connection callback erase the in-memory SSH secret after use. */
export class SshSecretValue {
  value: string = '';

  constructor(value: string) {
    this.value = value;
  }
}

export class PendingRemoteSession {
  cwd: string = '~';
  cmd: string = '';
  label: string = '';
  iconKind: string = '';
  title: string = '';
  manualTitle: boolean = false;
  sequence: number = 0;
  shellName: string = '';
  focusSession: boolean = true;

  constructor(cwd: string, cmd: string, label: string, iconKind: string,
    title: string = '', manualTitle: boolean = false, sequence: number = 0,
    shellName: string = '', focusSession: boolean = true) {
    this.cwd = cwd;
    this.cmd = cmd;
    this.label = label;
    this.iconKind = iconKind;
    this.title = title;
    this.manualTitle = manualTitle;
    this.sequence = sequence;
    this.shellName = shellName;
    this.focusSession = focusSession;
  }
}

export class SshRuntimeConnection {
  deviceId: string = '';
  target: string = '';
  controlPath: string = '';
  state: SshConnectionState = SshConnectionState.Disconnected;
  masterId: number = -1;
  scanId: number = -1;
  credentialAvailable: boolean = false;
  connectedMarkerSeen: boolean = false;
  openTerminalOnReady: boolean = false;
  authOutput: string = '';
  scanOutput: string = '';
  pendingSessions: PendingRemoteSession[] = [];
  /** Invalidates callbacks from previous connect/scan attempts. */
  attemptGeneration: number = 0;
  masterExitedGeneration: number = 0;
  scanExitedGeneration: number = 0;
  retryAttempt: number = 0;
  retryTimer: number = -1;
  nextRetryAt: number = 0;
  lastConnectedAt: number = 0;
  lastError: string = '';
  manualDisconnect: boolean = false;
  /** Login-shell name detected during the remote scan (e.g. bash, zsh, fish). */
  remoteShell: string = '';

  constructor(deviceId: string, target: string) {
    this.deviceId = deviceId;
    this.target = target;
  }

  isReady(): boolean {
    return this.state === SshConnectionState.Connected ||
      this.state === SshConnectionState.ConnectedScanFailed;
  }

  isBusy(): boolean {
    return this.state === SshConnectionState.Connecting || this.state === SshConnectionState.Scanning;
  }

  beginAttempt(): number {
    this.clearRetryTimer();
    this.manualDisconnect = false;
    this.attemptGeneration++;
    this.masterExitedGeneration = 0;
    this.scanExitedGeneration = 0;
    return this.attemptGeneration;
  }

  isCurrentAttempt(generation: number): boolean {
    return !this.manualDisconnect && generation > 0 && generation === this.attemptGeneration;
  }

  completeMasterStart(generation: number, nativeId: number): boolean {
    if (!this.isCurrentAttempt(generation) || this.masterExitedGeneration === generation) {
      return false;
    }
    if (this.masterId > 0 && this.masterId !== nativeId) {
      return false;
    }
    this.masterId = nativeId;
    return true;
  }

  acceptMasterEvent(generation: number, nativeId: number): boolean {
    if (!this.isCurrentAttempt(generation) || this.masterExitedGeneration === generation) {
      return false;
    }
    if (this.masterId <= 0) {
      this.masterId = nativeId;
    }
    return this.masterId === nativeId;
  }

  markMasterExited(generation: number): void {
    if (generation === this.attemptGeneration) {
      this.masterExitedGeneration = generation;
      this.masterId = -1;
    }
  }

  completeScanStart(generation: number, nativeId: number): boolean {
    if (!this.isCurrentAttempt(generation) || this.scanExitedGeneration === generation) {
      return false;
    }
    if (this.scanId > 0 && this.scanId !== nativeId) {
      return false;
    }
    this.scanId = nativeId;
    return true;
  }

  acceptScanEvent(generation: number, nativeId: number): boolean {
    if (!this.isCurrentAttempt(generation) || this.scanExitedGeneration === generation) {
      return false;
    }
    if (this.scanId <= 0) {
      this.scanId = nativeId;
    }
    return this.scanId === nativeId;
  }

  markScanExited(generation: number): void {
    if (generation === this.attemptGeneration) {
      this.scanExitedGeneration = generation;
      this.scanId = -1;
    }
  }

  markConnected(): void {
    this.retryAttempt = 0;
    this.nextRetryAt = 0;
    this.lastConnectedAt = Date.now();
    this.lastError = '';
  }

  nextRetryDelay(): number {
    const exponent = Math.min(this.retryAttempt, 5);
    const delay = Math.min(30000, 1000 * Math.pow(2, exponent));
    this.retryAttempt++;
    return delay;
  }

  clearRetryTimer(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.nextRetryAt = 0;
  }

  invalidate(manualDisconnect: boolean): void {
    this.clearRetryTimer();
    this.manualDisconnect = manualDisconnect;
    this.attemptGeneration++;
    this.masterExitedGeneration = this.attemptGeneration;
    this.scanExitedGeneration = this.attemptGeneration;
  }
}

export function encodeConnectionStates(items: SshRuntimeConnection[]): string {
  const records: string[] = [];
  for (const item of items) {
    records.push(encodeURIComponent(item.deviceId) + '\t' + encodeURIComponent(item.state));
  }
  return records.join('\n');
}

export function connectionStateOf(value: string, deviceId: string): SshConnectionState {
  for (const record of value.split('\n')) {
    const fields = record.split('\t');
    if (fields.length !== 2) {
      continue;
    }
    try {
      if (decodeURIComponent(fields[0]) === deviceId) {
        const state = decodeURIComponent(fields[1]);
        if (state === SshConnectionState.Connecting) return SshConnectionState.Connecting;
        if (state === SshConnectionState.Reconnecting) return SshConnectionState.Reconnecting;
        if (state === SshConnectionState.Scanning) return SshConnectionState.Scanning;
        if (state === SshConnectionState.Connected) return SshConnectionState.Connected;
        if (state === SshConnectionState.ConnectedScanFailed) return SshConnectionState.ConnectedScanFailed;
        if (state === SshConnectionState.NeedsCredential || state === '需要密码') {
          return SshConnectionState.NeedsCredential;
        }
        if (state === SshConnectionState.AuthFailed) return SshConnectionState.AuthFailed;
        if (state === SshConnectionState.HostKeyFailed) return SshConnectionState.HostKeyFailed;
        if (state === SshConnectionState.NetworkFailed) return SshConnectionState.NetworkFailed;
        if (state === SshConnectionState.Failed) return SshConnectionState.Failed;
      }
    } catch (e) {
      console.error('TERMINAI SSH state decode failed: ' + JSON.stringify(e));
    }
  }
  return SshConnectionState.Disconnected;
}

export function encodeRemoteAgents(items: RemoteAgentInfo[]): string {
  const records: string[] = [];
  for (const item of items) {
    records.push(encodeURIComponent(item.deviceId) + '\t' + encodeURIComponent(item.name) + '\t' +
      encodeURIComponent(item.path) + '\t' + encodeURIComponent(item.iconKind));
  }
  return records.join('\n');
}

export function decodeRemoteAgents(value: string): RemoteAgentInfo[] {
  const items: RemoteAgentInfo[] = [];
  if (value.length === 0) {
    return items;
  }
  for (const record of value.split('\n')) {
    const fields = record.split('\t');
    if (fields.length !== 4) {
      continue;
    }
    try {
      const deviceId = decodeURIComponent(fields[0]);
      const name = decodeURIComponent(fields[1]);
      const path = decodeURIComponent(fields[2]);
      const iconKind = decodeURIComponent(fields[3]);
      if (deviceId.length > 0 && name.length > 0 && path.length > 0) {
        items.push(new RemoteAgentInfo(deviceId, name, path, iconKind));
      }
    } catch (e) {
      console.error('TERMINAI remote agent decode failed: ' + JSON.stringify(e));
    }
  }
  return items;
}

export function remoteAgentsForDevice(value: string, deviceId: string): RemoteAgentInfo[] {
  return decodeRemoteAgents(value).filter((item: RemoteAgentInfo) => item.deviceId === deviceId);
}

export function replaceRemoteAgents(value: string, deviceId: string,
  agents: RemoteAgentInfo[]): string {
  const retained = decodeRemoteAgents(value).filter((item: RemoteAgentInfo) => item.deviceId !== deviceId);
  return encodeRemoteAgents(retained.concat(agents));
}

export function removeRemoteAgents(value: string, deviceId: string): string {
  return encodeRemoteAgents(decodeRemoteAgents(value).filter((item: RemoteAgentInfo) =>
    item.deviceId !== deviceId));
}
