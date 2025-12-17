import { useNotifications, removeNotification, type NotificationType } from '@lib/notifications';
import { X, Info, CheckCircle, AlertTriangle, AlertCircle } from 'lucide-react';
import { useState, useEffect, useRef } from 'preact/hooks';
import { Button } from '@components/ui/Button';

const icons: Record<NotificationType, any> = {
    info: Info,
    success: CheckCircle,
    warning: AlertTriangle,
    error: AlertCircle,
};

// Use CSS variable colors for proper theming
const stateColors: Record<NotificationType, string> = {
    info: 'var(--fg-2)',
    success: 'var(--green)',
    warning: 'var(--yellow)',
    error: 'var(--red)',
};

function NotificationItem({ notification }: { notification: { id: string; type: NotificationType; title: string; message?: string; duration?: number } }) {
    const Icon = icons[notification.type];
    const stateColor = stateColors[notification.type];
    const barRef = useRef<HTMLDivElement>(null);
    const durationSeconds = (notification.duration || 5000) / 1000;

    useEffect(() => {
        if (barRef.current) {
            // Force browser to render initial state
            barRef.current.offsetHeight;
            // Set the dynamic transition duration
            barRef.current.style.transition = `width ${durationSeconds}s linear`;
            // Then trigger transition
            barRef.current.style.width = '0%';
        }
    }, [durationSeconds]);

    return (
        <div
            className="relative overflow-hidden flex items-start gap-3 p-3 pb-4 rounded-2xl bg-bg-1 shadow-sm animate-in slide-in-from-right"
            style={{
                borderWidth: '1px',
                borderStyle: 'solid',
                borderColor: `color-mix(in srgb, ${stateColor} 40%, var(--border-color))`,
            }}
        >
            {/* Progress bar with pure CSS animation */}
            <div
                className="absolute bottom-0 left-0 right-0 h-1.5 rounded-b-2xl overflow-hidden"
                style={{ backgroundColor: 'var(--bg-3)' }}
            >
                <div
                    ref={barRef}
                    className="h-full"
                    style={{
                        backgroundColor: `color-mix(in srgb, ${stateColor} 70%, var(--bg-4))`,
                        width: '100%',
                    }}
                />
            </div>

            <Icon
                className="w-4 h-4 mt-0.5 shrink-0"
                style={{ color: stateColor }}
            />
            <p
                className="text-sm flex-1 leading-snug"
                style={{ color: `color-mix(in srgb, ${stateColor} 30%, var(--fg-0))` }}
            >
                {notification.message}
            </p>
            <Button
                variant="ghost"
                size="xs"
                onClick={() => removeNotification(notification.id)}
                className="shrink-0"
                leftIcon={<X className="w-3 h-3" />}
                aria-label="Dismiss"
            />
        </div>
    );
}

export function Notifications() {
    const items = useNotifications();
    const [footerVisible, setFooterVisible] = useState(false);

    // Watch footer visibility to offset toast stack
    useEffect(() => {
        const footer = document.getElementById('site-footer');
        if (!footer) return;

        const observer = new IntersectionObserver(
            ([entry]) => setFooterVisible(entry.isIntersecting),
            { threshold: 0 }
        );

        observer.observe(footer);
        return () => observer.disconnect();
    }, []);

    if (items.length === 0) return null;

    return (
        <div
            className="fixed left-0 right-0 z-toast flex flex-col items-center pointer-events-none transition-all duration-200"
            style={{ bottom: footerVisible ? '2.5rem' : '0.5rem' }}
        >
            <div className="w-full max-w-7xl">
                <div className="flex flex-col gap-2 max-w-sm ml-auto pointer-events-auto">
                    {items.map((notification) => (
                        <NotificationItem key={notification.id} notification={notification} />
                    ))}
                </div>
            </div>
        </div>
    );
}
