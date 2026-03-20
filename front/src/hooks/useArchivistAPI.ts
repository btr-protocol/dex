import { useState, useEffect } from 'preact/hooks';
import type { ArchivistMessage, ArchivistResponse, ArchivistSource, ArchivistSession } from '@/types/archivist';
import { getSession, saveSession, getSessionMessages, saveSessionMessages, cleanupEmptySessions, clearAllSessions } from '@/utils/sessionStorage';
import { logger } from '@sdk/utils';
import { authFetch } from '@lib/auth';

const log = logger.withContext('archivistAPI');

const ARCHIVIST_API_URL = import.meta.env.VITE_ARCHIVIST_API || 'http://localhost:4001';

// Clean up any legacy empty sessions on first load
if (typeof window !== 'undefined') {
  cleanupEmptySessions();
}

export function useArchivistAPI(sessionId: string) {
  const [messages, setMessages] = useState<ArchivistMessage[]>([]);
  const [sources, setSources] = useState<ArchivistSource[]>([]);
  const [loading, setLoading] = useState(false);
  const [lastUserMessage, setLastUserMessage] = useState<string>();

  // Load messages from localStorage when sessionId changes
  useEffect(() => {
    if (sessionId) {
      loadMessages(sessionId);
    } else {
      setMessages([]);
      setSources([]);
    }
  }, [sessionId]);

  const loadMessages = (sid: string) => {
    try {
      const stored = getSessionMessages(sid);
      if (stored) {
        const parsed = JSON.parse(stored) as ArchivistMessage[];
        setMessages(parsed);
      } else {
        setMessages([]);
      }
      setSources([]);
    } catch (error) {
      log.error('Failed to load messages', error);
      setMessages([]);
    }
  };

  /**
   * Save messages and update session metadata.
   * Session is only created/updated after the first message is sent.
   */
  const saveMessages = (sid: string, msgs: ArchivistMessage[]) => {
    if (msgs.length === 0) {
      // Don't save empty sessions - delete if exists
      const existingSession = getSession(sid);
      if (existingSession) {
        saveSession({ ...existingSession, messageCount: 0, lastActive: Date.now() });
      }
      return;
    }

    // Save messages to localStorage
    saveSessionMessages(sid, JSON.stringify(msgs));

    // Update session metadata
    const existingSession = getSession(sid);
    const lastUserMessage = msgs.filter(m => m.role === 'user').pop();
    const firstUserMessage = msgs.find(m => m.role === 'user');

    const session: ArchivistSession = {
      sessionId: sid,
      name: existingSession?.name || firstUserMessage?.content || 'New conversation',
      lastMessage: lastUserMessage?.content || 'New conversation',
      lastActive: Date.now(),
      createdAt: existingSession?.createdAt || Date.now(),
      messageCount: msgs.length,
    };

    saveSession(session);
  };

  const sendMessage = async (content: string) => {
    if (!sessionId || !content.trim()) return;

    const trimmedContent = content.trim();
    setLastUserMessage(trimmedContent);

    const userMessage: ArchivistMessage = {
      role: 'user',
      content: trimmedContent,
      timestamp: Date.now(),
    };

    const updatedMessages = [...messages, userMessage];
    setMessages(updatedMessages);
    saveMessages(sessionId, updatedMessages);

    setLoading(true);

    try {
      const response = await authFetch(`${ARCHIVIST_API_URL}/agents/archivist/chat`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Session-ID': sessionId,
        },
        body: JSON.stringify({ message: content.trim() }),
      });

      if (!response.ok) {
        if (response.status === 401 || response.status === 403) {
          throw new Error('Authentication required. Please connect your wallet and sign in.');
        }
        throw new Error(`API error: ${response.status}`);
      }

      const data: ArchivistResponse = await response.json();

      const assistantMessage: ArchivistMessage = {
        role: 'assistant',
        content: data.response,
        html: data.response, // Response is already HTML from archivist
        timestamp: Date.now(),
      };

      const finalMessages = [...updatedMessages, assistantMessage];
      setMessages(finalMessages);
      saveMessages(sessionId, finalMessages);

      // Update sources
      if (data.sources && data.sources.length > 0) {
        setSources(data.sources);
      }
    } catch (error) {
      log.error('Failed to send message', error);

      let errorMessage = 'Sorry, I encountered an error. Please make sure the Archivist server is running on http://localhost:4001';
      if (error instanceof Error && error.message.includes('Authentication required')) {
        errorMessage = error.message;
      }

      const errorMessageObj: ArchivistMessage = {
        role: 'assistant',
        content: errorMessage,
        timestamp: Date.now(),
      };

      const finalMessages = [...updatedMessages, errorMessageObj];
      setMessages(finalMessages);
      saveMessages(sessionId, finalMessages);
    } finally {
      setLoading(false);
    }
  };

  const createSession = async () => {
    // Session creation is handled client-side via localStorage
    // No API call needed as backend creates sessions on first message
  };

  return {
    messages,
    sources,
    loading,
    sendMessage,
    createSession,
    lastUserMessage,
  };
}
