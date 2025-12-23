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

import { Bug, Info, AlertTriangle, XCircle } from 'lucide-react';
import type { ComponentType } from 'preact';
import type { LucideProps } from 'lucide-react';

/** Lucide component icons for log levels (used in NotificationsModal) */
export const ICON_BY_LOG_LEVEL: Record<LogLevel, ComponentType<LucideProps>> = {
  [LogLevel.DEBUG]: Bug,
  [LogLevel.INFO]: Info,
  [LogLevel.WARNING]: AlertTriangle,
  [LogLevel.ERROR]: XCircle,
};
