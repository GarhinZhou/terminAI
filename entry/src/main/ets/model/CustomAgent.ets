/** Persisted user-defined agent command, scoped to a device. */
export class CustomAgentInfo {
  deviceId: string = '';
  name: string = '';
  command: string = '';

  constructor(deviceId: string, name: string, command: string) {
    this.deviceId = deviceId;
    this.name = name;
    this.command = command;
  }
}

/**
 * Store custom agents as URI-encoded tab-separated records, one per row:
 * deviceId \t name \t command. Legacy two-field rows are treated as local.
 */
export function encodeCustomAgents(items: CustomAgentInfo[]): string {
  const records: string[] = [];
  for (const item of items) {
    const name = item.name.trim();
    const command = item.command.trim();
    const deviceId = item.deviceId.length > 0 ? item.deviceId : 'local';
    if (name.length > 0 && command.length > 0) {
      records.push(encodeURIComponent(deviceId) + '\t' + encodeURIComponent(name) + '\t' +
        encodeURIComponent(command));
    }
  }
  return records.join('\n');
}

export function decodeCustomAgents(value: string): CustomAgentInfo[] {
  const items: CustomAgentInfo[] = [];
  if (value.length === 0) {
    return items;
  }
  for (const record of value.split('\n')) {
    const fields = record.split('\t');
    if (fields.length === 3) {
      try {
        const deviceId = decodeURIComponent(fields[0]).trim();
        const name = decodeURIComponent(fields[1]).trim();
        const command = decodeURIComponent(fields[2]).trim();
        if (name.length > 0 && command.length > 0) {
          items.push(new CustomAgentInfo(deviceId.length > 0 ? deviceId : 'local', name, command));
        }
      } catch (e) {
        console.error('TERMINAI custom agent record decode failed: ' + JSON.stringify(e));
      }
    } else if (fields.length === 2) {
      // Legacy two-field record without a device id → local.
      try {
        const name = decodeURIComponent(fields[0]).trim();
        const command = decodeURIComponent(fields[1]).trim();
        if (name.length > 0 && command.length > 0) {
          items.push(new CustomAgentInfo('local', name, command));
        }
      } catch (e) {
        console.error('TERMINAI legacy custom agent decode failed: ' + JSON.stringify(e));
      }
    }
  }
  return items;
}
