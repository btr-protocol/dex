import { useEffect, useState } from 'preact/hooks';
import { FlexCol } from '@components/ui/Flex';
import { Icon } from '@components/ui/Icon';
import { formatTimeAgo } from '@sdk/utils/format';
import { getAllSessions, deleteSession as deleteSessionFromStorage } from '@/utils/sessionStorage';

interface SessionsPanelProps {
  currentSessionId: string;
  onNewSession: () => void;
  onSelectSession: (sessionId: string) => void;
}

interface SessionsPanelProps {
  currentSessionId: string;
  onNewSession: () => void;
  onSelectSession: (sessionId: string) => void;
}

export function SessionsPanel({
  currentSessionId,
  onNewSession,
  onSelectSession
}: SessionsPanelProps) {
  const [sessions, setSessions] = useState(getAllSessions());

  // Refresh sessions whenever currentSessionId changes (to catch new sessions being created)
  useEffect(() => {
    setSessions(getAllSessions());
  }, [currentSessionId]);

  const handleDeleteSession = (sessionId: string, e: Event) => {
    e.stopPropagation();

    deleteSessionFromStorage(sessionId);
    setSessions(getAllSessions());

    if (sessionId === currentSessionId) {
      onNewSession();
    }
  };

  return (
    <>
      {sessions.length === 0 ? (
        <div className="text-xs text-fg-3 py-3">
          No previous chats
        </div>
      ) : (
        <div className="divide-y divide-border">
          {sessions.map((session) => (
            <SessionItem
              key={session.sessionId}
              session={session}
              isActive={session.sessionId === currentSessionId}
              onSelect={() => onSelectSession(session.sessionId)}
              onDelete={(e) => handleDeleteSession(session.sessionId, e)}
            />
          ))}
        </div>
      )}
    </>
  );
}

interface SessionItemProps {
  session: {
    sessionId: string;
    name?: string;
    lastMessage?: string;
    lastActive: number;
    messageCount: number;
  };
  isActive: boolean;
  onSelect: () => void;
  onDelete: (e: Event) => void;
}

function SessionItem({ session, isActive, onSelect, onDelete }: SessionItemProps) {
  const sessionName = session.name || session.lastMessage || 'New conversation';
  const timeAgo = formatTimeAgo(session.lastActive);

  return (
    <div className="flex items-center gap-1.5 py-1 group">
      <button
        onClick={onSelect}
        className={`w-full text-left rounded transition-colors flex-1 min-w-0 ${
          isActive ? 'text-primary bg-primary/10' : 'text-fg-2 hover:text-fg-1'
        }`}
      >
        <FlexCol gap="1" className="min-w-0">
          <div className="text-xs font-medium truncate">
            {sessionName}
          </div>
          <div className="text-xs text-fg-3">
            {session.messageCount} message{session.messageCount !== 1 ? 's' : ''} · {timeAgo}
          </div>
        </FlexCol>
      </button>
      <button
        onClick={onDelete}
        className="opacity-0 group-hover:opacity-100 p-1 hover:bg-destructive/20 transition-opacity shrink-0"
        title="Delete session"
      >
        <Icon name="trash" className="w-3 h-3 text-destructive" />
      </button>
    </div>
  );
}
