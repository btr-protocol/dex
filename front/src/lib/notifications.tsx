import { useState, useEffect } from 'preact/hooks';

export type NotificationType = 'info' | 'success' | 'warning' | 'error';
export interface Notification { id: string; type: NotificationType; title: string; message?: string; timestamp: number; duration: number; }

// Notification timing config
const MIN_DURATION_MS = 5000; // 5 seconds minimum
const MAX_DURATION_MS = 15000; // 15 seconds maximum
const MS_PER_CHAR = 120; // 120ms per character (comfortable reading speed)

// Toast notifications (auto-close)
let toastState: Notification[] = [];
const toastSubs = new Set<(s: Notification[]) => void>();

// Persistent notification log (never auto-close)
let logState: Notification[] = [];
const logSubs = new Set<(s: Notification[]) => void>();

const emitToasts = () => toastSubs.forEach(fn => fn(toastState));
const emitLog = () => logSubs.forEach(fn => fn(logState));

function calculateDuration(message: string, type?: NotificationType): number {
    // Base duration from message length
    const baseDuration = message.length * MS_PER_CHAR;

    // Type-based multipliers (errors and warnings should stay longer)
    const multiplier = type === 'error' ? 1.5 : type === 'warning' ? 1.3 : 1.0;

    // Clamp between min and max
    return Math.min(
        MAX_DURATION_MS,
        Math.max(MIN_DURATION_MS, baseDuration * multiplier)
    );
}

// Hook for toast notifications (auto-close)
export function useNotifications() {
    const [s, set] = useState(toastState);
    useEffect(() => { toastSubs.add(set); return () => void toastSubs.delete(set); }, []);
    return s;
}

// Hook for persistent notification log (never auto-close)
export function useNotificationLog() {
    const [s, set] = useState(logState);
    useEffect(() => { logSubs.add(set); return () => void logSubs.delete(set); }, []);
    return s;
}

export function addNotification(type: NotificationType, message: string) {
    const id = Math.random().toString(36).slice(2);
    const duration = calculateDuration(message, type);
    const title = type.charAt(0).toUpperCase() + type.slice(1);
    const notification = { id, type, title, message, timestamp: Date.now(), duration };

    // Add to both toast and persistent log
    toastState = [notification, ...toastState];
    logState = [notification, ...logState];

    emitToasts();
    emitLog();

    // Auto-remove from toast after duration (but NOT from log)
    setTimeout(() => removeNotification(id), duration);
    return id;
}

// Remove from toast (called on auto-close)
export function removeNotification(id: string) {
    toastState = toastState.filter(n => n.id !== id);
    emitToasts();
}

// Remove from persistent log (user action)
export function removeFromLog(id: string) {
    logState = logState.filter(n => n.id !== id);
    emitLog();
}

// Remove from persistent log by message
export function removeFromLogByMessage(message: string) {
    logState = logState.filter(n => n.message !== message);
    emitLog();
}

// Clear all from persistent log
export function clearLog() {
    logState = [];
    emitLog();
}
