import { useState, useEffect } from 'preact/hooks';

export type NotificationType = 'info' | 'success' | 'warning' | 'error';
export interface Notification { id: string; type: NotificationType; title: string; message?: string; timestamp: number; duration: number; }

// Notification timing config
const MIN_DURATION_MS = 3000; // 3 seconds minimum
const MS_PER_CHAR = 50; // 50ms per character for reading time

let state: Notification[] = [];
const subs = new Set<(s: Notification[]) => void>();

const emit = () => subs.forEach(fn => fn(state));

function calculateDuration(message: string): number {
    return Math.max(MIN_DURATION_MS, message.length * MS_PER_CHAR);
}

export function useNotifications() {
    const [s, set] = useState(state);
    useEffect(() => { subs.add(set); return () => void subs.delete(set); }, []);
    return s;
}

export function addNotification(type: NotificationType, message: string) {
    const id = Math.random().toString(36).slice(2);
    const duration = calculateDuration(message);
    const title = type.charAt(0).toUpperCase() + type.slice(1);
    state = [{ id, type, title, message, timestamp: Date.now(), duration }, ...state];
    emit();
    setTimeout(() => removeNotification(id), duration);
    return id;
}

export function removeNotification(id: string) {
    state = state.filter(n => n.id !== id);
    emit();
}

// Console Integration
const _orig = { warn: console.warn, error: console.error };

export function enableConsoleIntegration() {
    (['warn', 'error'] as const).forEach(key => {
        console[key] = (...args: any[]) => {
            _orig[key](...args);
            addNotification(key === 'warn' ? 'warning' : 'error', args.join(' '));
        };
    });
}

export function disableConsoleIntegration() {
    Object.assign(console, _orig);
}
