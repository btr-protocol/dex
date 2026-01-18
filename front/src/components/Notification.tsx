import { Icon } from '@components/ui/Icon';
import { Button } from '@components/ui/Button';
import { Badge } from '@components/ui/Badge';
import { INotification, LogLevel, ICON_BY_LOG_LEVEL } from '@/types/notification';
import { useNotificationActions } from '@/hooks/useNotificationActions';
import { formatTime } from '@sdk/utils/format';

interface NotificationProps {
  notification: INotification;
}

export function Notification({ notification }: NotificationProps) {
  const iconName = ICON_BY_LOG_LEVEL[notification.level];
  const { copy, download, report } = useNotificationActions();

  const handleCopy = () => copy(notification);
  const handleSave = () => download(notification, `${notification.id}-log.json`);
  const handleReport = () => report(notification);

  const levelColors = {
    [LogLevel.DEBUG]: 'text-muted-foreground',
    [LogLevel.INFO]: 'text-blue',
    [LogLevel.WARNING]: 'text-yellow',
    [LogLevel.ERROR]: 'text-red',
  };

  return (
    <div className="group relative flex items-start gap-3 px-4 py-3 border-b border-border hover:bg-bg-2 transition-colors">
      <Icon
        name={iconName}
        className={`w-5 h-5 shrink-0 mt-0.5 ${levelColors[notification.level]}`}
      />

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
          onClick={handleCopy}
          variant="ghost"
          size="xs"
          className="h-auto w-auto p-1.5"
          title="Copy"
          leftIcon={<Icon name="copy" className="w-3.5 h-3.5" />}
        />
        <Button
          onClick={handleSave}
          variant="ghost"
          size="xs"
          className="h-auto w-auto p-1.5"
          title="Save"
          leftIcon={<Icon name="floppy-disk" className="w-3.5 h-3.5" />}
        />
        <Button
          onClick={handleReport}
          variant="ghost"
          size="xs"
          className="h-auto w-auto p-1.5"
          title="Report"
          leftIcon={<Icon name="bug" className="w-3.5 h-3.5" />}
        />
      </div>
    </div>
  );
}
