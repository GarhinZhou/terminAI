import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';

const SSH_CREDENTIAL_PREFIX: string = 'terminai.ssh.password.';

/** Passwords are kept in Asset Store, never in Preferences or process arguments. */
export class SshCredentialStore {
  private static encode(value: string): Uint8Array {
    const encoder = new util.TextEncoder();
    return encoder.encodeInto(value);
  }

  private static alias(deviceId: string): Uint8Array {
    return SshCredentialStore.encode(SSH_CREDENTIAL_PREFIX + deviceId);
  }

  static async save(deviceId: string, password: string): Promise<boolean> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, SshCredentialStore.alias(deviceId));
    try {
      await asset.remove(query);
    } catch (e) {
      // A missing previous credential is the normal add-device path.
    }

    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, SshCredentialStore.alias(deviceId));
    attributes.set(asset.Tag.SECRET, SshCredentialStore.encode(password));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    try {
      await asset.add(attributes);
      // Report success only when Asset Store can immediately find the record;
      // the UI's bullet placeholder therefore reflects persisted state.
      return await SshCredentialStore.exists(deviceId);
    } catch (e) {
      console.error('TERMINAI SSH credential save failed');
      return false;
    }
  }

  static async load(deviceId: string): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, SshCredentialStore.alias(deviceId));
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

  /** Returns only the character count needed for the masked edit placeholder. */
  static async passwordLength(deviceId: string): Promise<number> {
    const password = await SshCredentialStore.load(deviceId);
    let count = 0;
    for (const character of password) {
      if (character.length > 0) {
        count++;
      }
    }
    return count;
  }

  /** Checks whether a credential exists without decrypting or exposing its plaintext. */
  static async exists(deviceId: string): Promise<boolean> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, SshCredentialStore.alias(deviceId));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    try {
      const result: Array<asset.AssetMap> = await asset.query(query);
      return result.length > 0;
    } catch (e) {
      return false;
    }
  }

  static async remove(deviceId: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, SshCredentialStore.alias(deviceId));
    try {
      await asset.remove(query);
    } catch (e) {
      // Removing a device without a stored password is already complete.
    }
  }
}
