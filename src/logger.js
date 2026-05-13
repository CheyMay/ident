export function createLogger() {
  return {
    info(message, meta) {
      log('INFO', message, meta);
    },
    warn(message, meta) {
      log('WARN', message, meta);
    },
    error(message, meta) {
      log('ERROR', message, meta);
    }
  };
}

function log(level, message, meta) {
  const suffix = meta ? ` ${JSON.stringify(meta)}` : '';
  console.log(`${new Date().toISOString()} ${level} ${message}${suffix}`);
}
