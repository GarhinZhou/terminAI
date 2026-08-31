import { fileIo, ReadTextOptions } from '@kit.CoreFileKit';
import libterminal from 'libterminal.so';

const IDENTITY_DIRECTORY: string = 'ssh-identities';
const MAX_IDENTITY_BYTES: number = 2 * 1024 * 1024;
const HEADER_READ_BYTES: number = 4096;

/** Imports Picker URIs into app-private storage for stable OpenSSH access. */
export class SshIdentityStore {
  static directory(filesDir: string): string {
    return filesDir + '/' + IDENTITY_DIRECTORY;
  }

  static isManaged(filesDir: string, path: string): boolean {
    if (filesDir.length === 0 || path.length === 0) {
      return false;
    }
    return path.startsWith(SshIdentityStore.directory(filesDir) + '/');
  }

  private static newIdentityPath(filesDir: string): string {
    return SshIdentityStore.directory(filesDir) + '/identity-' + Date.now().toString() + '-' +
      Math.floor(Math.random() * 1000000).toString() + '.key';
  }

  private static looksLikePrivateKey(content: string): boolean {
    const normalized = content.trim();
    return normalized.startsWith('-----BEGIN ') &&
      normalized.indexOf('PRIVATE KEY-----') > 0;
  }

  static async importFromPickerUri(filesDir: string, uri: string): Promise<string> {
    if (filesDir.length === 0 || uri.length === 0) {
      throw new Error('无法获取应用私有目录');
    }
    let source: fileIo.File | null = null;
    let destination = '';
    try {
      source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      const sourceStat = await fileIo.stat(source.fd);
      if (!sourceStat.isFile() || sourceStat.size <= 0 || sourceStat.size > MAX_IDENTITY_BYTES) {
        throw new Error('请选择不超过 2 MB 的有效私钥文件');
      }

      const directory = SshIdentityStore.directory(filesDir);
      if (!await fileIo.access(directory)) {
        await fileIo.mkdir(directory, true);
      }
      destination = SshIdentityStore.newIdentityPath(filesDir);
      await fileIo.copyFile(source.fd, destination, 0);

      const readOptions: ReadTextOptions = {
        offset: 0,
        length: Math.min(HEADER_READ_BYTES, sourceStat.size),
        encoding: 'utf-8'
      };
      const header = await fileIo.readText(destination, readOptions);
      if (!SshIdentityStore.looksLikePrivateKey(header)) {
        throw new Error('所选文件不是 OpenSSH/PEM 私钥');
      }
      if (!libterminal.securePrivateFile(destination)) {
        throw new Error('无法设置私钥文件安全权限');
      }
      return destination;
    } catch (e) {
      if (destination.length > 0) {
        await SshIdentityStore.removePath(destination);
      }
      throw new Error(e instanceof Error ? e.message : '私钥文件导入失败');
    } finally {
      if (source !== null) {
        try {
          fileIo.closeSync(source);
        } catch (e) {
          console.error('TERMINAI SSH identity source close failed');
        }
      }
    }
  }

  private static async removePath(path: string): Promise<void> {
    try {
      if (await fileIo.access(path)) {
        await fileIo.unlink(path);
      }
    } catch (e) {
      console.error('TERMINAI managed SSH identity cleanup failed');
    }
  }

  static async removeManaged(filesDir: string, path: string): Promise<void> {
    if (!SshIdentityStore.isManaged(filesDir, path)) {
      return;
    }
    await SshIdentityStore.removePath(path);
  }
}
