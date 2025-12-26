import { useEffect, useRef, useState, useCallback } from 'preact/hooks';
import { Dialog, DialogPortal, DialogOverlay } from '@components/ui/Dialog';
import { Icon } from '@components/ui/Icon';
import { cn } from '@utils/cn';

interface DiagramModalProps {
  isOpen: boolean;
  onClose: () => void;
  svgHtml: string;
}

const MIN_SCALE = 0.25;
const MAX_SCALE = 4;
const ZOOM_STEP = 0.25;

export function DiagramModal({ isOpen, onClose, svgHtml }: DiagramModalProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(1);
  const [position, setPosition] = useState({ x: 0, y: 0 });
  const [isDragging, setIsDragging] = useState(false);
  const dragStart = useRef({ x: 0, y: 0, posX: 0, posY: 0 });

  // Reset on open
  useEffect(() => {
    if (isOpen) {
      setScale(1);
      setPosition({ x: 0, y: 0 });
    }
  }, [isOpen]);

  // Handle click outside to close
  useEffect(() => {
    if (!isOpen || !contentRef.current) return;

    const handlePointerDown = (e: PointerEvent) => {
      if (contentRef.current && e.target === contentRef.current) {
        onClose();
      }
    };

    contentRef.current.addEventListener('pointerdown', handlePointerDown);
    return () => contentRef.current?.removeEventListener('pointerdown', handlePointerDown);
  }, [isOpen, onClose]);

  // Native wheel listener (passive: false required for preventDefault)
  useEffect(() => {
    if (!isOpen) return;
    const el = containerRef.current;
    if (!el) return;

    const handleWheel = (e: WheelEvent) => {
      e.preventDefault();
      const delta = e.deltaY > 0 ? -ZOOM_STEP : ZOOM_STEP;
      setScale((s) => Math.min(MAX_SCALE, Math.max(MIN_SCALE, s + delta)));
    };

    el.addEventListener('wheel', handleWheel, { passive: false });
    return () => el.removeEventListener('wheel', handleWheel);
  }, [isOpen]);

  // Keyboard shortcuts
  useEffect(() => {
    if (!isOpen) return;

    const handleKey = (e: KeyboardEvent) => {
      if (e.key === '=' || e.key === '+') {
        setScale((s) => Math.min(MAX_SCALE, s + ZOOM_STEP));
      } else if (e.key === '-') {
        setScale((s) => Math.max(MIN_SCALE, s - ZOOM_STEP));
      } else if (e.key === '0') {
        setScale(1);
        setPosition({ x: 0, y: 0 });
      }
    };

    window.addEventListener('keydown', handleKey);
    return () => window.removeEventListener('keydown', handleKey);
  }, [isOpen]);

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    if (e.button !== 0) return;
    setIsDragging(true);
    dragStart.current = { x: e.clientX, y: e.clientY, posX: position.x, posY: position.y };
  }, [position]);

  const handleMouseMove = useCallback((e: React.MouseEvent) => {
    if (!isDragging) return;
    const dx = e.clientX - dragStart.current.x;
    const dy = e.clientY - dragStart.current.y;
    setPosition({ x: dragStart.current.posX + dx, y: dragStart.current.posY + dy });
  }, [isDragging]);

  const handleMouseUp = useCallback(() => {
    setIsDragging(false);
  }, []);

  const zoomIn = () => setScale((s) => Math.min(MAX_SCALE, s + ZOOM_STEP));
  const zoomOut = () => setScale((s) => Math.max(MIN_SCALE, s - ZOOM_STEP));
  const reset = () => { setScale(1); setPosition({ x: 0, y: 0 }); };

  return (
    <Dialog open={isOpen} onOpenChange={(open) => !open && onClose()}>
      <DialogPortal>
        <DialogOverlay className="bg-black/80" />
        <div
          ref={contentRef}
          className="fixed inset-0 z-modal flex items-center justify-center outline-none"
        >
          {/* Controls */}
          <div className="absolute top-4 right-4 flex gap-2 z-10">
            <ControlButton onClick={zoomOut} title="Zoom out">
              <Icon name="magnifying-glass-minus" className="w-4 h-4" />
            </ControlButton>
            <ControlButton onClick={zoomIn} title="Zoom in">
              <Icon name="magnifying-glass-plus" className="w-4 h-4" />
            </ControlButton>
            <ControlButton onClick={reset} title="Reset">
              <Icon name="arrows-counter-clockwise" className="w-4 h-4" />
            </ControlButton>
            <ControlButton onClick={onClose} title="Close (Esc)">
              <Icon name="x" className="w-4 h-4" />
            </ControlButton>
          </div>

          {/* Scale indicator */}
          <div className="absolute bottom-4 left-4 text-xs text-white/60 font-mono">
            {Math.round(scale * 100)}%
          </div>

          {/* Diagram container */}
          <div
            ref={containerRef}
            className={cn(
              'w-full h-full overflow-hidden',
              isDragging ? 'cursor-grabbing' : 'cursor-grab'
            )}
            onMouseDown={handleMouseDown}
            onMouseMove={handleMouseMove}
            onMouseUp={handleMouseUp}
            onMouseLeave={handleMouseUp}
          >
            <div
              className="w-full h-full flex items-center justify-center"
              style={{
                transform: `translate(${position.x}px, ${position.y}px) scale(${scale})`,
                transformOrigin: 'center center',
                transition: isDragging ? 'none' : 'transform 0.1s ease-out',
              }}
            >
              <div
                className="diagram-modal-content p-8"
                dangerouslySetInnerHTML={{ __html: svgHtml }}
              />
            </div>
          </div>
        </div>
      </DialogPortal>
    </Dialog>
  );
}

function ControlButton({ onClick, title, children }: {
  onClick: () => void;
  title: string;
  children: React.ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      title={title}
      className="w-8 h-8 flex items-center justify-center rounded bg-white/10 hover:bg-white/20 text-white transition-colors"
    >
      {children}
    </button>
  );
}
