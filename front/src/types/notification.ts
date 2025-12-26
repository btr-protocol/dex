export enum LogLevel {
  DEBUG = 'debug',
  INFO = 'info',
  WARNING = 'warning',
  ERROR = 'error',
}

export interface INotification {
  id: string;
  message: string;
  level: LogLevel;
  timestamp: number;
  count?: number;
  stack?: string;
}

import { ICON_NAMES } from '@components/ui/Icon';

/** Phosphor icon names for log levels */
export const ICON_BY_LOG_LEVEL: Record<LogLevel, string> = {
  [LogLevel.DEBUG]: ICON_NAMES.bug,
  [LogLevel.INFO]: ICON_NAMES.info,
  [LogLevel.WARNING]: ICON_NAMES.warning,
  [LogLevel.ERROR]: ICON_NAMES.xCircle,
};
