/** Local or SSH host shown in the herdrm-style device switcher. */
export class ManagedDevice {
  id: string = '';
  name: string = '';
  sshTarget: string = '';

  constructor(id: string, name: string, sshTarget: string) {
    this.id = id;
    this.name = name;
    this.sshTarget = sshTarget;
  }

  isLocal(): boolean {
    return this.sshTarget.length === 0;
  }
}

export const LOCAL_DEVICE_ID: string = 'local';

export function localDevice(): ManagedDevice {
  return new ManagedDevice(LOCAL_DEVICE_ID, '本机', '');
}

/** Compact, explicit preference format: one URI-encoded record per remote host. */
export function encodeDevices(items: ManagedDevice[]): string {
  const records: string[] = [];
  for (const item of items) {
    if (item.isLocal()) {
      continue;
    }
    records.push(encodeURIComponent(item.id) + '\t' + encodeURIComponent(item.name) + '\t' +
      encodeURIComponent(item.sshTarget));
  }
  return records.join('\n');
}

export function decodeDevices(value: string): ManagedDevice[] {
  const devices: ManagedDevice[] = [localDevice()];
  if (value.length === 0) {
    return devices;
  }
  for (const record of value.split('\n')) {
    const fields = record.split('\t');
    if (fields.length !== 3) {
      continue;
    }
    try {
      const id = decodeURIComponent(fields[0]).trim();
      const name = decodeURIComponent(fields[1]).trim();
      const target = decodeURIComponent(fields[2]).trim();
      if (id.length > 0 && name.length > 0 && isValidSshTarget(target)) {
        devices.push(new ManagedDevice(id, name, target));
      }
    } catch (e) {
      console.error('TERMINAI device record decode failed: ' + JSON.stringify(e));
    }
  }
  return devices;
}

export function isValidSshTarget(value: string): boolean {
  const target = value.trim();
  if (target.length === 0 || target.length > 255) {
    return false;
  }
  // OpenSSH alias, host, user@host, ssh:// URI, IPv4/IPv6 and custom port.
  return /^[A-Za-z0-9._@:\/\-+%\[\]]+$/.test(target);
}

export function newDeviceId(): string {
  return 'ssh-' + Date.now().toString() + '-' + Math.floor(Math.random() * 100000).toString();
}

export function normalizedSshTarget(value: string): string {
  const target = value.trim();
  if (target.startsWith('ssh://')) {
    return target;
  }
  const bracketEnd = target.lastIndexOf(']');
  if (bracketEnd >= 0) {
    return bracketEnd + 1 < target.length && target.substring(bracketEnd + 1).startsWith(':') ?
      'ssh://' + target : target;
  }
  const at = target.lastIndexOf('@');
  const colon = target.lastIndexOf(':');
  const hostStart = at >= 0 ? at + 1 : 0;
  if (colon > hostStart && target.indexOf(':', hostStart) === colon) {
    return 'ssh://' + target;
  }
  return target;
}
