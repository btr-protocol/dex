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

/** Icon names for log levels */
export const ICON_BY_LOG_LEVEL: Record<LogLevel, string> = {
  [LogLevel.DEBUG]: 'bug',
  [LogLevel.INFO]: 'info',
  [LogLevel.WARNING]: 'warning',
  [LogLevel.ERROR]: 'x-circle',
};
