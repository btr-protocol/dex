import { useState, useMemo, useEffect } from 'preact/hooks';
import { Icon } from '@components/ui/Icon';
import { BaseModal, MODAL_PADDING } from '@components/ui/BaseModal';
import { MultiSelectModal, FilterButton, FilterOption } from '@components/ui/MultiSelectModal';
import { EmptyState } from '@components/ui/EmptyState';
import { DownloadModal } from '@components/DownloadModal';
import { Tooltip, ButtonGroup } from '@components/ui';
import { Notification } from '@components/Notification';
import { INotification, LogLevel, ICON_BY_LOG_LEVEL } from '@/types/notification';

interface NotificationsModalProps {
  isOpen: boolean;
  onClose: (open: boolean) => void;
  notifications: INotification[];
  onDeleteNotification: (id: string) => void;
  onDeleteGroup: (message: string) => void;
  onClearAll: () => void;
}

// Build log level filter options from centralized icon mapping
const logLevelFilterOptions: FilterOption[] = [
  { id: LogLevel.DEBUG, name: 'Debug', icon: ICON_BY_LOG_LEVEL[LogLevel.DEBUG] },
  { id: LogLevel.INFO, name: 'Info', icon: ICON_BY_LOG_LEVEL[LogLevel.INFO] },
  { id: LogLevel.WARNING, name: 'Warning', icon: ICON_BY_LOG_LEVEL[LogLevel.WARNING] },
  { id: LogLevel.ERROR, name: 'Error', icon: ICON_BY_LOG_LEVEL[LogLevel.ERROR] },
];

export function NotificationsModal({
  isOpen,
  onClose,
  notifications,
  onDeleteNotification,
  onDeleteGroup,
  onClearAll,
}: NotificationsModalProps) {
  const [searchQuery, setSearchQuery] = useState('');
  const [selectedLevels, setSelectedLevels] = useState<string[]>(
    logLevelFilterOptions.map((opt) => opt.id)
  );
  const [isLevelFilterOpen, setIsLevelFilterOpen] = useState(false);
  const [isDownloadModalOpen, setIsDownloadModalOpen] = useState(false);

  // Reset state when dialog opens
  useEffect(() => {
    if (isOpen) {
      setSearchQuery('');
      setSelectedLevels(logLevelFilterOptions.map((opt) => opt.id));
    }
  }, [isOpen]);

  // Filter notifications
  const filteredNotifications = useMemo(() => {
    let filtered = [...notifications];

    if (searchQuery) {
      const query = searchQuery.toLowerCase();
      filtered = filtered.filter((n) => n.message.toLowerCase().includes(query));
    }

    // Filter by level if any levels selected
    if (selectedLevels.length > 0) {
      filtered = filtered.filter((n) => selectedLevels.includes(n.level));
    }

    return filtered.sort((a, b) => b.timestamp - a.timestamp);
  }, [notifications, searchQuery, selectedLevels]);

  // Group notifications by day and message
  const groupedNotifications = useMemo(() => {
    const dateGroups = new Map<number, INotification[]>();

    filteredNotifications.forEach((notification) => {
      const date = new Date(notification.timestamp);
      date.setHours(0, 0, 0, 0);
      const groupTimestamp = date.getTime();

      if (!dateGroups.has(groupTimestamp)) {
        dateGroups.set(groupTimestamp, []);
      }
      dateGroups.get(groupTimestamp)!.push(notification);
    });

    // Group by message within each day
    return Array.from(dateGroups.entries())
      .map(([timestamp, dayNotifications]) => {
        const messageGroups = new Map<string, INotification[]>();

        dayNotifications.forEach((notification) => {
          if (!messageGroups.has(notification.message)) {
            messageGroups.set(notification.message, []);
          }
          messageGroups.get(notification.message)!.push(notification);
        });

        const groupedItems = Array.from(messageGroups.entries())
          .map(([_message, items]) => ({
            ...items[0],
            count: items.length,
            timestamp: Math.max(...items.map((item) => item.timestamp)),
          }))
          .sort((a, b) => b.timestamp - a.timestamp);

        return { timestamp, items: groupedItems };
      })
      .sort((a, b) => b.timestamp - a.timestamp);
  }, [filteredNotifications]);

  const formatDayHeader = (timestamp: number): string => {
    const date = new Date(timestamp);
    const today = new Date();
    const yesterday = new Date(today);
    yesterday.setDate(yesterday.getDate() - 1);

    today.setHours(0, 0, 0, 0);
    yesterday.setHours(0, 0, 0, 0);
    date.setHours(0, 0, 0, 0);

    if (date.getTime() === today.getTime()) return 'TODAY';
    if (date.getTime() === yesterday.getTime()) return 'YESTERDAY';

    return date.toLocaleDateString('en-US', {
      weekday: 'long',
      month: 'long',
      day: 'numeric',
    }).toUpperCase();
  };

  const copyAll = () => {
    navigator.clipboard.writeText(JSON.stringify(filteredNotifications, null, 2));
  };

  const saveAll = () => {
    const blob = new Blob([JSON.stringify(filteredNotifications, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'btr-logs.json';
    a.click();
    URL.revokeObjectURL(url);
  };

  const reportAll = () => {
    const body = filteredNotifications.map((n) => `${n.timestamp}: [${n.level}] ${n.message}`).join('\n');
    const subject = encodeURIComponent('Notification Report');
    const encodedBody = encodeURIComponent(body);
    window.location.href = `mailto:tech@btr.supply?subject=${subject}&body=${encodedBody}`;
  };

  const resetFilters = () => {
    setSearchQuery('');
    setSelectedLevels(logLevelFilterOptions.map((opt) => opt.id));
  };

  const allLevelsSelected = selectedLevels.length === logLevelFilterOptions.length;
  const hasActiveFilters = !!searchQuery || !allLevelsSelected;

  return (
    <>
      <BaseModal
        isOpen={isOpen}
        onClose={onClose}
        title="Notifications"
        headerType="input"
        placeholder="Search notifications..."
        searchValue={searchQuery}
        onSearchChange={setSearchQuery}
        maxWidth="max-w-3xl"
        headerRight={
          <>
            <FilterButton
              label="Filter"
              options={logLevelFilterOptions}
              selected={selectedLevels}
              onClick={() => setIsLevelFilterOpen(true)}
            />
            <ButtonGroup variant="compact">
              <Tooltip content="Download notifications" side="bottom">
                <button
                  onClick={() => setIsDownloadModalOpen(true)}
                  className="p-1.5 hover:bg-bg-3 transition-colors text-muted-foreground hover:text-foreground"
                >
                  <Icon name="download" className="w-4 h-4" />
                </button>
              </Tooltip>
              <Tooltip content="Clear all notifications" side="bottom">
                <button
                  onClick={onClearAll}
                  className="p-1.5 hover:bg-red/10 transition-colors text-muted-foreground hover:text-red"
                >
                  <Icon name="trash" className="w-4 h-4" />
                </button>
              </Tooltip>
            </ButtonGroup>
          </>
        }
      >
        <div className="divide-y divide-border">
          {groupedNotifications.length > 0 ? (
            groupedNotifications.map((group) => (
              <div key={group.timestamp}>
                <div className={`sticky top-0 z-10 ${MODAL_PADDING} py-2 bg-bg-2 border-b border-border`}>
                  <h5 className="text-xs font-semibold text-muted-foreground tracking-wide">
                    {formatDayHeader(group.timestamp)}
                  </h5>
                </div>
                {group.items.map((notification) => (
                  <Notification
                    key={notification.id}
                    notification={notification}
                    onDelete={onDeleteNotification}
                    onDeleteGroup={onDeleteGroup}
                  />
                ))}
              </div>
            ))
          ) : (
            <EmptyState
              query={searchQuery}
              message="No notifications found"
              onReset={resetFilters}
              showResetButton={hasActiveFilters}
            />
          )}
        </div>
      </BaseModal>

      <MultiSelectModal
        isOpen={isLevelFilterOpen}
        onClose={() => setIsLevelFilterOpen(false)}
        title="Filter by Level"
        placeholder="Search log levels..."
        options={logLevelFilterOptions}
        selected={selectedLevels}
        onApply={setSelectedLevels}
      />

      <DownloadModal
        isOpen={isDownloadModalOpen}
        onClose={() => setIsDownloadModalOpen(false)}
        onCopy={copyAll}
        onDownload={saveAll}
        onEmail={reportAll}
      />
    </>
  );
}
