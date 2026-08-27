/** Minimal session description persisted across application restarts. */
export class SavedSessionInfo {
  cwd: string = '~';
  cmd: string = '';
  agentKind: string = '';
  iconKind: string = '';
  deviceId: string = 'local';
  title: string = '';
  manualTitle: boolean = false;
  sequence: number = 1;
  shellName: string = 'zsh';

  constructor(cwd: string, cmd: string, agentKind: string, iconKind: string,
    deviceId: string, title: string, manualTitle: boolean, sequence: number,
    shellName: string) {
    this.cwd = cwd;
    this.cmd = cmd;
    this.agentKind = agentKind;
    this.iconKind = iconKind;
    this.deviceId = deviceId;
    this.title = title;
    this.manualTitle = manualTitle;
    this.sequence = sequence;
    this.shellName = shellName;
  }
}

/** URI encoding keeps terminal commands and titles safe inside tab-separated preferences. */
export function encodeSavedSessions(items: SavedSessionInfo[]): string {
  const records: string[] = [];
  for (const item of items) {
    records.push(encodeURIComponent(item.cwd) + '\t' + encodeURIComponent(item.cmd) + '\t' +
      encodeURIComponent(item.agentKind) + '\t' + encodeURIComponent(item.iconKind) + '\t' +
      encodeURIComponent(item.deviceId) + '\t' + encodeURIComponent(item.title) + '\t' +
      (item.manualTitle ? '1' : '0') + '\t' + item.sequence.toString() + '\t' +
      encodeURIComponent(item.shellName));
  }
  return records.join('\n');
}

export function decodeSavedSessions(value: string): SavedSessionInfo[] {
  const items: SavedSessionInfo[] = [];
  if (value.length === 0) {
    return items;
  }
  for (const record of value.split('\n')) {
    if (items.length >= 100) {
      break;
    }
    const fields = record.split('\t');
    if (fields.length !== 9) {
      continue;
    }
    try {
      const cwd = decodeURIComponent(fields[0]);
      const cmd = decodeURIComponent(fields[1]);
      const agentKind = decodeURIComponent(fields[2]);
      const iconKind = decodeURIComponent(fields[3]);
      const deviceId = decodeURIComponent(fields[4]);
      const title = decodeURIComponent(fields[5]);
      const sequence = parseInt(fields[7]);
      const shellName = decodeURIComponent(fields[8]);
      if (cwd.length > 0 && deviceId.length > 0 && sequence > 0 && sequence <= 10000) {
        items.push(new SavedSessionInfo(cwd, cmd, agentKind, iconKind, deviceId,
          title, fields[6] === '1', sequence, shellName));
      }
    } catch (error) {
      console.error('TERMINAI saved session decode failed: ' + JSON.stringify(error));
    }
  }
  return items;
}

