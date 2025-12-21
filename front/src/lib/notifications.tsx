import { useState, useEffect } from 'preact/hooks';

export type NotificationType = 'info' | 'success' | 'warning' | 'error';
export interface Notification { id: string; type: NotificationType; title: string; message?: string; timestamp: number; duration: number; }

// Notification timing config
const MIN_DURATION_MS = 5000; // 5 seconds minimum
const MAX_DURATION_MS = 15000; // 15 seconds maximum
const MS_PER_CHAR = 120; // 120ms per character (comfortable reading speed)

let state: Notification[] = [];
const subs = new Set<(s: Notification[]) => void>();

const emit = () => subs.forEach(fn => fn(state));

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

export function useNotifications() {
    const [s, set] = useState(state);
    useEffect(() => { subs.add(set); return () => void subs.delete(set); }, []);
    return s;
}

export function addNotification(type: NotificationType, message: string) {
    const id = Math.random().toString(36).slice(2);
    const duration = calculateDuration(message, type);
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
