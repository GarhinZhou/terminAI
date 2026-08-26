/** Persisted user-defined agent command. */
export class CustomAgentInfo {
  name: string = '';
  command: string = '';

  constructor(name: string, command: string) {
    this.name = name;
    this.command = command;
  }
}

/**
 * Store custom agents as URI-encoded tab-separated records. This keeps the
 * preference format compact while allowing spaces and command arguments.
 */
export function encodeCustomAgents(items: CustomAgentInfo[]): string {
  const records: string[] = [];
  for (const item of items) {
    const name = item.name.trim();
    const command = item.command.trim();
    if (name.length > 0 && command.length > 0) {
      records.push(encodeURIComponent(name) + '\t' + encodeURIComponent(command));
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
    if (fields.length !== 2) {
      continue;
    }
    try {
      const name = decodeURIComponent(fields[0]).trim();
      const command = decodeURIComponent(fields[1]).trim();
      if (name.length > 0 && command.length > 0) {
        items.push(new CustomAgentInfo(name, command));
      }
    } catch (e) {
      console.error('TERMINAI custom agent record decode failed: ' + JSON.stringify(e));
    }
  }
  return items;
}
