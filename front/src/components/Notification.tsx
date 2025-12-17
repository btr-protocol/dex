import { Copy, Save, Bug, X, Trash2, AlertTriangle, Info, XCircle } from 'lucide-react';
import { Button } from '@components/ui/Button';
import { Badge } from '@components/ui/Badge';
import { INotification, LogLevel } from '@/types/notification';

const ICON_MAP = {
  [LogLevel.DEBUG]: Bug,
  [LogLevel.INFO]: Info,
  [LogLevel.WARNING]: AlertTriangle,
  [LogLevel.ERROR]: XCircle,
};

interface NotificationProps {
  notification: INotification;
  onDelete: (id: string) => void;
  onDeleteGroup: (message: string) => void;
}

export function Notification({ notification, onDelete, onDeleteGroup }: NotificationProps) {
  const Icon = ICON_MAP[notification.level];

  const formatTime = (timestamp: number) => {
    const date = new Date(timestamp);
    return date.toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });
  };

  const copy = () => {
    navigator.clipboard.writeText(JSON.stringify(notification, null, 2));
  };

  const save = () => {
    const blob = new Blob([JSON.stringify(notification, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${notification.id}-log.json`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const report = () => {
    const subject = encodeURIComponent('Log Report');
    const body = encodeURIComponent(JSON.stringify(notification, null, 2));
    window.location.href = `mailto:tech@btr.supply?subject=${subject}&body=${body}`;
  };

  const levelColors = {
    [LogLevel.DEBUG]: 'text-muted-foreground',
    [LogLevel.INFO]: 'text-blue',
    [LogLevel.WARNING]: 'text-yellow',
    [LogLevel.ERROR]: 'text-red',
  };

  return (
    <div className="group relative flex items-start gap-3 px-4 py-3 border-b border-border hover:bg-bg-2 transition-colors">
      <Icon className={`w-5 h-5 shrink-0 mt-0.5 ${levelColors[notification.level]}`} />

      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2 text-xs text-muted-foreground mb-1">
          <span className="font-mono">{formatTime(notification.timestamp)}</span>
          {notification.count && notification.count > 1 && (
            <Badge variant="default">{notification.count}x</Badge>
          )}
        </div>
        <p className="text-sm text-foreground break-words">{notification.message}</p>
      </div>

      {/* Actions - visible on hover */}
      <div className="absolute right-2 top-1/2 -translate-y-1/2 flex gap-1 opacity-0 group-hover:opacity-100 transition-opacity bg-bg-1 border border-border rounded-sm p-1">
        <Button
          onClick={copy}
          variant="ghost"
          size="xs"
          className="h-auto w-auto p-1.5"
          title="Copy"
          leftIcon={<Copy className="w-3.5 h-3.5" />}
        />
        <Button
          onClick={save}
          variant="ghost"
          size="xs"
          className="h-auto w-auto p-1.5"
          title="Save"
          leftIcon={<Save className="w-3.5 h-3.5" />}
        />
        <Button
          onClick={report}
          variant="ghost"
          size="xs"
          className="h-auto w-auto p-1.5"
          title="Report"
          leftIcon={<Bug className="w-3.5 h-3.5" />}
        />
        <Button
          onClick={() => onDelete(notification.id)}
          variant="ghost"
          size="xs"
          className="h-auto w-auto p-1.5"
          title="Delete"
          leftIcon={<X className="w-3.5 h-3.5" />}
        />
        <Button
          onClick={() => onDeleteGroup(notification.message)}
          variant="ghost"
          size="xs"
          className="h-auto w-auto p-1.5 hover:bg-red/10 text-red"
          title="Delete all"
          leftIcon={<Trash2 className="w-3.5 h-3.5" />}
        />
      </div>
    </div>
  );
}
