/** Return the last program selected for one device. */
export function programForDevice(value: string, deviceId: string): string {
  for (const record of value.split('\n')) {
    const fields = record.split('\t');
    if (fields.length !== 2) {
      continue;
    }
    try {
      if (decodeURIComponent(fields[0]) === deviceId) {
        return decodeURIComponent(fields[1]);
      }
    } catch (error) {
      console.error('TERMINAI device program decode failed: ' + JSON.stringify(error));
    }
  }
  return '';
}

/** Replace one device entry while retaining every other device's selection. */
export function setProgramForDevice(value: string, deviceId: string, program: string): string {
  const records: string[] = [];
  for (const record of value.split('\n')) {
    const fields = record.split('\t');
    if (fields.length !== 2) {
      continue;
    }
    try {
      if (decodeURIComponent(fields[0]) !== deviceId) {
        records.push(record);
      }
    } catch (error) {
      console.error('TERMINAI device program decode failed: ' + JSON.stringify(error));
    }
  }
  if (deviceId.length > 0 && program.length > 0) {
    records.push(encodeURIComponent(deviceId) + '\t' + encodeURIComponent(program));
  }
  return records.join('\n');
}

