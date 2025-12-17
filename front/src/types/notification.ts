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

export const ICON_BY_LOG_LEVEL: Record<LogLevel, string> = {
  [LogLevel.DEBUG]: 'bug',
  [LogLevel.INFO]: 'info-circle',
  [LogLevel.WARNING]: 'alert-triangle',
  [LogLevel.ERROR]: 'x-circle',
};
