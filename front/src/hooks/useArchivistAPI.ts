import { useState, useEffect } from 'preact/hooks';
import type { ArchivistMessage, ArchivistResponse, ArchivistSource, ArchivistSession } from '@/types/archivist';

const ARCHIVIST_API_URL = import.meta.env.VITE_ARCHIVIST_API || 'http://localhost:4001';

export function useArchivistAPI(sessionId: string) {
  const [messages, setMessages] = useState<ArchivistMessage[]>([]);
  const [sources, setSources] = useState<ArchivistSource[]>([]);
  const [loading, setLoading] = useState(false);
  const [lastUserMessage, setLastUserMessage] = useState<string>();

  // Load messages from localStorage when sessionId changes
  useEffect(() => {
    if (sessionId) {
      loadMessages(sessionId);
    }
  }, [sessionId]);

  const loadMessages = (sid: string) => {
    try {
      const stored = localStorage.getItem(`archivist-messages-${sid}`);
      if (stored) {
        const parsed = JSON.parse(stored) as ArchivistMessage[];
        setMessages(parsed);
      } else {
        setMessages([]);
      }
      setSources([]);
    } catch (error) {
      console.error('Failed to load messages:', error);
      setMessages([]);
    }
  };

  const saveMessages = (sid: string, msgs: ArchivistMessage[]) => {
    try {
      localStorage.setItem(`archivist-messages-${sid}`, JSON.stringify(msgs));
      updateSessionMetadata(sid, msgs);
    } catch (error) {
      console.error('Failed to save messages:', error);
    }
  };

  const updateSessionMetadata = (sid: string, msgs: ArchivistMessage[]) => {
    try {
      const stored = localStorage.getItem('archivist-sessions');
      const sessions: ArchivistSession[] = stored ? JSON.parse(stored) : [];

      const existingSession = sessions.find(s => s.sessionId === sid);
      const lastUserMessage = msgs.filter(m => m.role === 'user').pop();
      const firstUserMessage = msgs.find(m => m.role === 'user');

      const session: ArchivistSession = {
        sessionId: sid,
        name: existingSession?.name || firstUserMessage?.content,
        lastMessage: lastUserMessage?.content || 'New conversation',
        lastActive: Date.now(),
        createdAt: existingSession?.createdAt || Date.now(),
        messageCount: msgs.length,
      };

      const existingIndex = sessions.findIndex(s => s.sessionId === sid);
      if (existingIndex >= 0) {
        sessions[existingIndex] = session;
      } else {
        sessions.push(session);
      }

      localStorage.setItem('archivist-sessions', JSON.stringify(sessions));
    } catch (error) {
      console.error('Failed to update session metadata:', error);
    }
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
      const response = await fetch(`${ARCHIVIST_API_URL}/agents/archivist/chat`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Session-ID': sessionId,
        },
        body: JSON.stringify({ message: content.trim() }),
      });

      if (!response.ok) {
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
      console.error('Failed to send message:', error);

      const errorMessage: ArchivistMessage = {
        role: 'assistant',
        content: 'Sorry, I encountered an error. Please make sure the Archivist server is running on http://localhost:4001',
        timestamp: Date.now(),
      };

      const finalMessages = [...updatedMessages, errorMessage];
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
