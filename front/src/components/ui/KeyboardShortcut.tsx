import { Badge } from './Badge';

interface KeyboardShortcutProps {
  keys: string | string[];
  label?: string;
  className?: string;
}

/**
 * Reusable keyboard shortcut display component
 * Uses Badge component with 'code' variant for consistent kbd styling
 */
export function KeyboardShortcut({ keys, label, className = '' }: KeyboardShortcutProps) {
  const keyString = Array.isArray(keys) ? keys.join('') : keys;

  return (
    <span className={`flex items-center gap-1.5 text-xs text-muted-foreground ${className}`}>
      <Badge variant="code">{keyString}</Badge>
      {label && <span>{label}</span>}
    </span>
  );
}

interface KeyboardShortcutGroupProps {
  shortcuts: Array<{ keys: string | string[]; label: string }>;
  className?: string;
}

/**
 * Container for multiple keyboard shortcuts
 * Aligns shortcuts to the right and manages spacing
 */
export function KeyboardShortcutGroup({
  shortcuts,
  className = '',
}: KeyboardShortcutGroupProps) {
  return (
    <div className={`flex items-center gap-4 ml-auto ${className}`}>
      {shortcuts.map((shortcut, idx) => (
        <KeyboardShortcut key={idx} keys={shortcut.keys} label={shortcut.label} />
      ))}
    </div>
  );
}
