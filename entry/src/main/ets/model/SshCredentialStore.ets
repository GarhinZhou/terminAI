import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { ManagedDevice, SshAuthMode } from './ManagedDevice';

const SSH_CREDENTIAL_PREFIX: string = 'terminai.ssh.password.';
const SSH_KEY_PASSPHRASE_PREFIX: string = 'terminai.ssh.key-passphrase.';

export enum SshCredentialKind {
  Password = 'password',
  KeyPassphrase = 'keyPassphrase'
}

/** Passwords/passphrases are kept in Asset Store, never in Preferences or argv. */
export class SshCredentialStore {
  private static encode(value: string): Uint8Array {
    const encoder = new util.TextEncoder();
    return encoder.encodeInto(value);
  }

  private static alias(deviceId: string, kind: SshCredentialKind): Uint8Array {
    const prefix = kind === SshCredentialKind.KeyPassphrase ?
      SSH_KEY_PASSPHRASE_PREFIX : SSH_CREDENTIAL_PREFIX;
    return SshCredentialStore.encode(prefix + deviceId);
  }

  static kindForDevice(device: ManagedDevice): SshCredentialKind {
    return device.authMode === SshAuthMode.PrivateKey ?
      SshCredentialKind.KeyPassphrase : SshCredentialKind.Password;
  }

  static async save(deviceId: string, secret: string,
    kind: SshCredentialKind = SshCredentialKind.Password): Promise<boolean> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, SshCredentialStore.alias(deviceId, kind));
    try {
      await asset.remove(query);
    } catch (e) {
      // A missing previous credential is the normal add-device path.
    }

    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, SshCredentialStore.alias(deviceId, kind));
    attributes.set(asset.Tag.SECRET, SshCredentialStore.encode(secret));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    try {
      await asset.add(attributes);
      // Report success only when Asset Store can immediately find the record;
      // the UI's bullet placeholder therefore reflects persisted state.
      return await SshCredentialStore.exists(deviceId, kind);
    } catch (e) {
      console.error('TERMINAI SSH credential save failed');
      return false;
    }
  }

  static async load(deviceId: string,
    kind: SshCredentialKind = SshCredentialKind.Password): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, SshCredentialStore.alias(deviceId, kind));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const result: Array<asset.AssetMap> = await asset.query(query);
      if (result.length === 0) {
        return '';
      }
      const secret: asset.Value | undefined = result[0].get(asset.Tag.SECRET);
      if (secret instanceof Uint8Array) {
        // Use the Asset Store guide's explicit UTF-8 decoder construction;
        // this avoids platform-default decoder differences.
        const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        return decoder.decodeToString(secret, { stream: false });
      }
    } catch (e) {
      console.info('TERMINAI SSH credential not available for ' + deviceId);
    }
    return '';
  }

  static async loadForDevice(device: ManagedDevice): Promise<string> {
    return await SshCredentialStore.load(device.id, SshCredentialStore.kindForDevice(device));
  }

  /** Returns only the character count needed for the masked edit placeholder. */
  static async secretLength(deviceId: string, kind: SshCredentialKind): Promise<number> {
    const password = await SshCredentialStore.load(deviceId, kind);
    let count = 0;
    for (const character of password) {
      if (character.length > 0) {
        count++;
      }
    }
    return count;
  }

  /** Checks whether a credential exists without decrypting or exposing its plaintext. */
  static async exists(deviceId: string,
    kind: SshCredentialKind = SshCredentialKind.Password): Promise<boolean> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, SshCredentialStore.alias(deviceId, kind));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    try {
      const result: Array<asset.AssetMap> = await asset.query(query);
      return result.length > 0;
    } catch (e) {
      return false;
    }
  }

  static async remove(deviceId: string,
    kind: SshCredentialKind = SshCredentialKind.Password): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, SshCredentialStore.alias(deviceId, kind));
    try {
      await asset.remove(query);
    } catch (e) {
      // Removing a device without a stored password is already complete.
    }
  }


  static async removeAll(deviceId: string): Promise<void> {
    await SshCredentialStore.remove(deviceId, SshCredentialKind.Password);
    await SshCredentialStore.remove(deviceId, SshCredentialKind.KeyPassphrase);
  }
}
