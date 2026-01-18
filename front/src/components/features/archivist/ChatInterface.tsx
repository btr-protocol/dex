import { useRef, useEffect, useState } from 'preact/hooks';
import { FlexCol, FlexRow } from '@components/ui/Flex';
import { Icon } from '@components/ui/Icon';
import type { ArchivistMessage } from '@/types/archivist';
import { useClipboard } from '@/hooks/useClipboard';
import { addNotification } from '@lib/notifications';
import { formatTime } from '@sdk/utils/format';
import { formatTimeAgo } from '@/utils/date';

 interface ChatInterfaceProps {
  messages: ArchivistMessage[];
  loading: boolean;
  onSendMessage: (message: string) => Promise<void>;
  lastUserMessage?: string;
  initialInput?: string;
}

const LOADING_MESSAGES = [
  'thinking...',
  'enhancing query...',
  'gathering documents...',
  'summarizing sources...',
  'exploring memories...',
] as const;

export function ChatInterface({ messages, loading, onSendMessage, lastUserMessage, initialInput }: ChatInterfaceProps) {
  // Add animation keyframes for fade-in effect
  useEffect(() => {
    if (typeof document !== 'undefined' && !document.getElementById('archivist-animations')) {
      const style = document.createElement('style');
      style.id = 'archivist-animations';
      style.textContent = `
        @keyframes fadeSlideIn {
          from {
            opacity: 0;
            transform: translateY(10px);
          }
          to {
            opacity:1;
            transform: translateY(0);
          }
        }
        @keyframes shimmer {
          0% {
            background-position: 100% 0;
          }
          100% {
            background-position: -100% 0;
          }
        }
      `;
      document.head.appendChild(style);
      return () => {
        document.head.removeChild(style);
      };
    }
  }, []);
  const [input, setInput] = useState('');
  const [loadingMessage, setLoadingMessage] = useState(0);
  const [renderedMessages, setRenderedMessages] = useState<Set<number>>(new Set());
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const { copy } = useClipboard();

  // Handle initial input from URL parameter
  useEffect(() => {
    if (initialInput && input === '') {
      setInput(initialInput);
      if (textareaRef.current) {
        textareaRef.current.style.height = 'auto';
        textareaRef.current.style.height = `${textareaRef.current.scrollHeight}px`;
      }
    }
  }, [initialInput]);

  // Auto-scroll to bottom when new messages arrive
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  // Cycle loading messages every 3 seconds
  useEffect(() => {
    if (!loading) return;
    const interval = setInterval(() => {
      setLoadingMessage(prev => (prev + 1) % LOADING_MESSAGES.length);
    }, 3000);
    return () => clearInterval(interval);
  }, [loading]);

  // Track rendered messages for progressive fade-in
  useEffect(() => {
    const newMessages = messages.filter((_, idx) => !renderedMessages.has(idx));
    if (newMessages.length > 0) {
      const timer = setTimeout(() => {
        setRenderedMessages(prev => {
          const updated = new Set(prev);
          messages.forEach((_, idx) => updated.add(idx));
          return updated;
        });
      }, 50);
      return () => clearTimeout(timer);
    }
  }, [messages]);

  // Auto-resize textarea
  useEffect(() => {
    if (textareaRef.current) {
      textareaRef.current.style.height = 'auto';
      textareaRef.current.style.height = `${textareaRef.current.scrollHeight}px`;
    }
  }, [input]);

  // Handle copy button clicks for code blocks
  useEffect(() => {
    const handleCopyClick = (e: Event) => {
      const target = e.target as HTMLElement;
      const button = target.closest('.copy-button') as HTMLButtonElement;
      if (!button) return;

      const code = button.dataset.code;
      if (code) {
        copy(code, `Copied ${code.length} characters`);
      }
    };

    document.addEventListener('click', handleCopyClick);
    return () => document.removeEventListener('click', handleCopyClick);
  }, [copy]);

  const handleSubmit = async (e: Event) => {
    e.preventDefault();
    if (!input.trim() || loading) return;

    const messageText = input.trim();
    setInput('');

    // Reset textarea height
    if (textareaRef.current) {
      textareaRef.current.style.height = 'auto';
    }

    await onSendMessage(messageText);
  };

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSubmit(e);
    }
  };

  return (
    <FlexCol className="h-[calc(100vh-5.5rem)] min-h-0 pb-4">
      {/* Messages Container */}
      <div className="flex-1 overflow-y-auto min-h-0">
        {messages.length === 0 ? (
          <div className="flex items-center justify-center h-full">
            <FlexCol gap="4" className="text-center max-w-md">
              <div className="text-lg font-semibold">Ask the Archivist</div>
              <div className="text-sm text-fg-3">
                I can help you understand BTR protocol, smart contracts, and documentation.
                Ask me anything about how BTR works!
              </div>
            </FlexCol>
          </div>
        ) : (
          <>
            <div className="space-y-1">
              {messages.map((msg, idx) => (
                <ChatMessage key={idx} message={msg} copy={copy} onRegenerate={idx === messages.length - 1 && msg.role === 'assistant' && lastUserMessage ? () => onSendMessage(lastUserMessage) : undefined} isRendered={renderedMessages.has(idx)} />
              ))}
            </div>
            {loading && (
              <FlexRow gap="2" className="text-fg-1 text-sm items-center">
                <Icon name="loader" className="w-4 h-4 animate-spin" />
                <span
                  className="font-medium"
                  style={{
                    animation: 'shimmer 1s infinite linear',
                    background: 'linear-gradient(90deg, var(--fg-1) 0%, var(--fg-2) 50%, var(--fg-1) 100%)',
                    backgroundSize: '200% 100%',
                    WebkitBackgroundClip: 'text',
                    backgroundClip: 'text',
                    WebkitTextFillColor: 'transparent',
                    color: 'transparent'
                  }}
                >
                  {LOADING_MESSAGES[loadingMessage].charAt(0).toUpperCase() + LOADING_MESSAGES[loadingMessage].slice(1)}
                </span>
              </FlexRow>
            )}
            <div ref={messagesEndRef} />
          </>
        )}
      </div>

      {/* Input Area */}
      <div className="border-t border-border shrink-0 pt-4">
        <form onSubmit={handleSubmit}>
          <div className="btn-group-outlined items-stretch h-[6rem]">
            <div className="flex-1 border-r border-border h-full">
              <textarea
                ref={textareaRef}
                value={input}
                onInput={(e) => setInput((e.target as HTMLTextAreaElement).value)}
                onKeyDown={handleKeyDown}
                placeholder="Ask anything about BTR or all things DeFi..."
                className="w-full px-4 py-3 bg-bg-2 resize-none focus:outline-none focus:ring-0 text-sm font-title font-medium h-full overflow-auto"
                rows={8}
                disabled={loading}
              />
            </div>
            <button
              type="submit"
              disabled={!input.trim() || loading}
              className={`h-full px-4 py-3 disabled:opacity-30 disabled:cursor-not-allowed transition-colors flex items-center justify-center ${
                input.trim()
                  ? 'bg-bg-primary text-primary hover:bg-primary/90'
                  : 'bg-bg-2/50 hover:bg-bg-2/70 text-fg-1'
              }`}
            >
              <Icon name="send" className="w-6 h-6" />
            </button>
          </div>
          <div className="text-xs text-fg-3 mt-2">
            Press Enter to send, Shift + Enter for new line
          </div>
        </form>
      </div>
    </FlexCol>
  );
}

interface ChatMessageProps {
  message: ArchivistMessage;
  copy: (text: string, message?: string) => void;
  onRegenerate?: () => void;
  isRendered?: boolean;
}

function ChatMessage({ message, copy, onRegenerate, isRendered }: ChatMessageProps) {
  const isUser = message.role === 'user';

  const handleCopy = () => {
    const tempDiv = document.createElement('div');
    tempDiv.innerHTML = message.html || message.content;
    const text = tempDiv.innerText || tempDiv.textContent || '';
    copy(text, `Copied ${text.length} characters`);
  };

  return (
    <div className={`${isUser ? 'flex justify-end' : 'flex justify-start'}`}>
      {isUser ? (
        <div className="flex flex-col items-end max-w-[80%]">
          <div className="text-xs text-fg-3 mb-1 font-title">You</div>
          <div className="px-4 py-3 rounded-sm bg-bg-primary text-primary w-full">
            <div className="text-sm whitespace-pre-wrap break-words">
              {message.content}
            </div>
            <div className="text-xs opacity-60 mt-1 font-title">
              {formatTime(message.timestamp)}
            </div>
          </div>
        </div>
      ) : (
        <div
          className="flex flex-col items-start max-w-[95%]"
          style={{
            animation: !isRendered ? 'fadeSlideIn 0.5s ease-out forwards' : undefined
          }}
        >
          <div className="text-xs text-fg-3 mb-1 font-title">Archivist</div>
          <div className="bg-bg-1 px-4 py-3 rounded-sm w-full">
            <div
              className="text-sm prose prose-invert max-w-none markdown-content"
              dangerouslySetInnerHTML={{ __html: message.html || message.content }}
            />
            <div className="flex items-center mt-2 justify-end">
              <div className="text-xs opacity-60 font-title">
                {formatTime(message.timestamp)}
              </div>
              <button
                onClick={handleCopy}
                className="p-1 hover:bg-bg-2 rounded-sm transition-colors"
                title="Copy response"
              >
                <Icon name="copy" className="w-4 h-4 text-fg-3" />
              </button>
              {onRegenerate && (
                <button
                  onClick={onRegenerate}
                  className="p-1 hover:bg-bg-2 rounded-sm transition-colors"
                  title="Regenerate response"
                >
                  <Icon name="refresh-cw" className="w-4 h-4 text-fg-3" />
                </button>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
