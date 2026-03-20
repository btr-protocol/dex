import { useState, useEffect } from 'preact/hooks';
import { ArchivistLayout } from '@/components/features/archivist/ArchivistLayout';
import { ChatInterface } from '@/components/features/archivist/ChatInterface';
import { useArchivistAPI } from '@/hooks/useArchivistAPI';
import { useLocalStorage } from '@/hooks/useLocalStorage';
import { generateSessionId } from '@/utils/id';

export function ArchivistPage() {
  const [sessionId, setSessionId] = useState<string>('');
  const [initialQuery, setInitialQuery] = useState<string>('');
  const [savedSessionId, setSavedSessionId] = useLocalStorage<string>('archivist-session-id', '');
  const { messages, sources, loading, sendMessage } = useArchivistAPI(sessionId);

  useEffect(() => {
    const urlParams = new URLSearchParams(window.location.search);
    const queryParam = urlParams.get('q');

    if (queryParam && queryParam.trim()) {
      // New session from URL query - generate ID but don't save until message sent
      const newSessionId = generateSessionId();
      setSessionId(newSessionId);
      setSavedSessionId(newSessionId);
      setInitialQuery(queryParam.trim());
      window.history.replaceState({}, '', window.location.pathname);
    } else {
      // Use saved session ID or generate a new one (not saved yet)
      const sid = savedSessionId || generateSessionId();
      setSessionId(sid);
      setSavedSessionId(sid);
    }
    // NB: Session is NOT created in localStorage until first message is sent
    // This prevents accumulation of empty sessions
  }, [savedSessionId]);

  const handleNewSession = () => {
    const newSessionId = generateSessionId();
    setSessionId(newSessionId);
    setSavedSessionId(newSessionId);
    setInitialQuery('');
    // NB: Session is NOT created in localStorage until first message is sent
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
        initialInput={initialQuery}
      />
    </ArchivistLayout>
  );
}
