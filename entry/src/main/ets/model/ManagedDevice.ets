/** Local or SSH host shown in the herdrm-style device switcher. */
export enum SshAuthMode {
  Password = 'password',
  PrivateKey = 'privateKey'
}

export class ManagedDevice {
  id: string = '';
  name: string = '';
  sshTarget: string = '';
  authMode: SshAuthMode = SshAuthMode.Password;
  identityFile: string = '';

  constructor(id: string, name: string, sshTarget: string,
    authMode: SshAuthMode = SshAuthMode.Password, identityFile: string = '') {
    this.id = id;
    this.name = name;
    this.sshTarget = sshTarget;
    this.authMode = authMode;
    this.identityFile = identityFile;
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
      encodeURIComponent(item.sshTarget) + '\t' + encodeURIComponent(item.authMode) + '\t' +
      encodeURIComponent(item.identityFile));
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
    // Three-field records are from releases before device-level key auth.
    if (fields.length !== 3 && fields.length !== 5) {
      continue;
    }
    try {
      const id = decodeURIComponent(fields[0]).trim();
      const name = decodeURIComponent(fields[1]).trim();
      const target = decodeURIComponent(fields[2]).trim();
      const authMode = fields.length === 5 && decodeURIComponent(fields[3]) === SshAuthMode.PrivateKey ?
        SshAuthMode.PrivateKey : SshAuthMode.Password;
      const identityFile = fields.length === 5 ? decodeURIComponent(fields[4]).trim() : '';
      if (id.length > 0 && name.length > 0 && isValidSshTarget(target)) {
        devices.push(new ManagedDevice(id, name, target, authMode, identityFile));
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

/** Identity paths are shell-quoted at command construction time. */
export function isValidIdentityFile(value: string): boolean {
  const path = value.trim();
  return path.length > 0 && path.length <= 4096 && path.indexOf('\n') < 0 &&
    path.indexOf('\r') < 0 && path.indexOf('\0') < 0;
}

function shellQuote(value: string): string {
  return "'" + value.replace(/'/g, "'\"'\"'") + "'";
}

/** Shared by validation, remote scan and visible terminal sessions. */
export function sshAuthenticationArguments(device: ManagedDevice): string {
  if (device.authMode === SshAuthMode.PrivateKey) {
    return '-o BatchMode=no -o PubkeyAuthentication=yes ' +
      '-o PasswordAuthentication=no -o KbdInteractiveAuthentication=no ' +
      '-o PreferredAuthentications=publickey -o IdentitiesOnly=yes ' +
      '-o NumberOfPasswordPrompts=0 -i ' + shellQuote(device.identityFile.trim());
  }
  // Keep publickey first for compatibility with SSH aliases, default keys and
  // SSH Agent, then fall back to the password saved for this device.
  return '-o BatchMode=no -o PubkeyAuthentication=yes ' +
    '-o PasswordAuthentication=yes -o KbdInteractiveAuthentication=yes ' +
    '-o PreferredAuthentications=publickey,password,keyboard-interactive ' +
    '-o NumberOfPasswordPrompts=1';
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
