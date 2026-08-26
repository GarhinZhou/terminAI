/** Per-device agent binary overrides: { deviceId: { kind: path } }. */
export function overridesForDevice(encoded: string, deviceId: string): Record<string, string> {
  try {
    const nested = JSON.parse(encoded.length > 0 ? encoded : '{}') as Record<string, Record<string, string>>;
    const device = nested[deviceId];
    return device === undefined || device === null ? {} : device;
  } catch (e) {
    return {};
  }
}

export function setOverridesForDevice(encoded: string, deviceId: string,
  map: Record<string, string>): string {
  let nested: Record<string, Record<string, string>> = {};
  try {
    nested = JSON.parse(encoded.length > 0 ? encoded : '{}') as Record<string, Record<string, string>>;
  } catch (e) {
    nested = {};
  }
  nested[deviceId] = map;
  return JSON.stringify(nested);
}

/** Migrate the legacy flat {kind: path} format into {local: {kind: path}}. */
export function migrateAgentOverrides(raw: string): string {
  if (raw.length === 0) {
    return '{}';
  }
  try {
    const obj = JSON.parse(raw) as Record<string, Object>;
    if (obj['local'] !== undefined) {
      return raw;
    }
    const flat: Record<string, string> = {};
    Object.keys(obj).forEach((k: string) => {
      flat[k] = obj[k] as string;
    });
    const wrapped: Record<string, Record<string, string>> = {};
    wrapped['local'] = flat;
    return JSON.stringify(wrapped);
  } catch (e) {
    return '{}';
  }
}
