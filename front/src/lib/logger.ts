/**
 * Frontend logger - integrates with notification system
 * Uses SDK logger under the hood
 */

import { logger as sdkLogger, setNotificationHandler } from '@sdk/utils';
import { addNotification } from './notifications';

// Set up notification integration
setNotificationHandler((type, message) => {
  addNotification(type, message);
});

/**
 * Single logger instance for frontend
 */
export const logger = sdkLogger;

/**
 * Create a scoped logger with context bound
 */
export function withContext(context: string) {
  return sdkLogger.withContext(context);
}

/**
 * Convenience exports
 */
export const debug = logger.debug;
export const info = logger.info;
export const warn = logger.warn;
export const error = logger.error;
export { info as log };
