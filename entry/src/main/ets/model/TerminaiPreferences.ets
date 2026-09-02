import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const PREFERENCES_NAME = 'terminai_settings';

/**
 * Process-wide owner of the application's Preferences object.
 *
 * HarmonyOS Preferences keeps an in-memory map per opened object and flushes
 * that map as a whole. Opening the same file through UIAbilityContext and
 * ApplicationContext produced independent snapshots: a later style flush
 * could therefore restore an old savedSessions value, while a session flush
 * could erase unrelated settings. Every caller must share this one object.
 */
export class TerminaiPreferences {
  private static instance: preferences.Preferences | undefined = undefined;

  static configure(context: common.Context): void {
    if (TerminaiPreferences.instance !== undefined) {
      return;
    }
    try {
      TerminaiPreferences.instance = preferences.getPreferencesSync(context,
        { name: PREFERENCES_NAME });
    } catch (error) {
      console.error('TERMINAI configure preferences failed: ' + JSON.stringify(error));
    }
  }

  static get(context: common.Context): preferences.Preferences {
    const current = TerminaiPreferences.instance;
    if (current !== undefined) {
      return current;
    }
    try {
      const created = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      TerminaiPreferences.instance = created;
      return created;
    } catch (error) {
      console.error('TERMINAI open preferences failed: ' + JSON.stringify(error));
      throw new Error('无法打开 terminAI 偏好存储');
    }
  }
}
