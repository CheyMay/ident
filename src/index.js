import { loadConfig } from './config.js';
import { createLogger } from './logger.js';
import { startServer } from './server.js';

const logger = createLogger();
const config = loadConfig();

if (!config.identIntegrationKey) {
  logger.warn('IDENT_INTEGRATION_KEY is empty; IDENT endpoints will return 500 until it is configured');
}

if (!config.amo.baseUrl || !config.amo.accessToken) {
  logger.warn('amoCRM is not fully configured; GetTickets will return only local queued bookings');
}

startServer(config, logger);
