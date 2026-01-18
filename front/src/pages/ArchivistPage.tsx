import { useState, useEffect } from 'preact/hooks';
import { ArchivistLayout } from '@/components/features/archivist/ArchivistLayout';
import { ChatInterface } from '@/components/features/archivist/ChatInterface';
import { useArchivistAPI } from '@/hooks/useArchivistAPI';
import { useLocalStorage } from '@/hooks/useLocalStorage';
import type { ArchivistSession } from '@/types/archivist';
import { generateSessionId } from '@/utils/id';

export function ArchivistPage() {
  const [sessionId, setSessionId] = useState<string>('');
  const [initialQuery, setInitialQuery] = useState<string>('');
  const [sessions, setSessions] = useLocalStorage<ArchivistSession[]>('archivist-sessions', []);
  const [savedSessionId, setSavedSessionId] = useLocalStorage<string>('archivist-session-id', '');
  const { messages, sources, loading, sendMessage, createSession: _createSession, lastUserMessage } = useArchivistAPI(sessionId);

  useEffect(() => {
    const createSessionEntry = (sid: string) => {
      const now = Date.now();
      const newSession: ArchivistSession = {
        sessionId: sid,
        name: 'New conversation',
        lastMessage: 'New conversation',
        lastActive: now,
        createdAt: now,
        messageCount: 0,
      };
      setSessions([newSession, ...sessions]);
    };

    const urlParams = new URLSearchParams(window.location.search);
    const queryParam = urlParams.get('q');

    if (queryParam && queryParam.trim()) {
      const newSessionId = generateSessionId();
      setSessionId(newSessionId);
      setSavedSessionId(newSessionId);
      setInitialQuery(queryParam.trim());
      createSessionEntry(newSessionId);
      window.history.replaceState({}, '', window.location.pathname);
    } else {
      const sid = savedSessionId || generateSessionId();
      setSessionId(sid);
      setSavedSessionId(sid);
      createSessionEntry(sid);
    }
  }, [savedSessionId]);

  const handleNewSession = () => {
    const newSessionId = generateSessionId();
    setSessionId(newSessionId);
    setSavedSessionId(newSessionId);
    setInitialQuery('');

    const now = Date.now();
    const newSession: ArchivistSession = {
      sessionId: newSessionId,
      name: 'New conversation',
      lastMessage: 'New conversation',
      lastActive: now,
      createdAt: now,
      messageCount: 0,
    };
    setSessions([newSession, ...sessions]);
  };

  return (
    <ArchivistLayout
      currentSessionId={sessionId}
      onNewSession={handleNewSession}
      onSelectSession={setSessionId}
      sources={sources}
    >
      <ChatInterface
        messages={messages}
        loading={loading}
        onSendMessage={sendMessage}
        lastUserMessage={lastUserMessage}
        initialInput={initialQuery}
      />
    </ArchivistLayout>
  );
}
