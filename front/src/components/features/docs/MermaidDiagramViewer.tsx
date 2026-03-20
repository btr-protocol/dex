import { useState, useRef, useEffect, useCallback } from 'preact/hooks';

interface MermaidDiagramViewerProps {
  svgContent: string;
}

export function MermaidDiagramViewer({ svgContent }: MermaidDiagramViewerProps) {
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [isDragging, setIsDragging] = useState(false);
  const [dragStart, setDragStart] = useState({ x: 0, y: 0 });
  const fullscreenRef = useRef<HTMLDivElement>(null);

  // Get SVG content based on theme
  const getSvgContent = useCallback(() => {
    const tempDiv = document.createElement('div');
    tempDiv.innerHTML = svgContent;

    const lightSvg = tempDiv.querySelector('.mermaid-light');
    const darkSvg = tempDiv.querySelector('.mermaid-dark');

    const isDark = document.documentElement.classList.contains('dark');
    const svgElement = isDark && darkSvg ? darkSvg : lightSvg;

    return svgElement?.innerHTML || '';
  }, [svgContent]);

  // Handle zoom with mouse wheel
  const handleWheel = useCallback((e: WheelEvent) => {
    e.preventDefault();
    e.stopPropagation();

    const delta = e.deltaY * -0.002;
    setZoom((z) => Math.min(Math.max(0.25, z + delta), 5));
  }, []);

  // Handle pan start
  const handleMouseDown = useCallback((e: MouseEvent) => {
    if (e.button !== 0) return; // Only left click
    setIsDragging(true);
    setDragStart({ x: e.clientX - pan.x, y: e.clientY - pan.y });
    e.preventDefault();
  }, [pan]);

  // Handle pan move
  const handleMouseMove = useCallback((e: MouseEvent) => {
    if (!isDragging) return;
    setPan({
      x: e.clientX - dragStart.x,
      y: e.clientY - dragStart.y
    });
  }, [isDragging, dragStart]);

  // Handle pan end
  const handleMouseUp = useCallback(() => {
    setIsDragging(false);
  }, []);

  // Handle keyboard close (Escape)
  useEffect(() => {
    if (!isFullscreen) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setIsFullscreen(false);
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isFullscreen]);

  // Reset transform and lock body scroll when opening fullscreen
  useEffect(() => {
    if (isFullscreen) {
      setZoom(1);
      setPan({ x: 0, y: 0 });
      document.body.style.overflow = 'hidden';
    } else {
      document.body.style.overflow = '';
    }

    return () => {
      document.body.style.overflow = '';
    };
  }, [isFullscreen]);

  // Attach wheel and mouse events to fullscreen container
  useEffect(() => {
    if (!isFullscreen) return;

    const container = fullscreenRef.current;
    if (!container) return;

    container.addEventListener('wheel', handleWheel, { passive: false });
    container.addEventListener('mousedown', handleMouseDown);
    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);

    return () => {
      container.removeEventListener('wheel', handleWheel);
      container.removeEventListener('mousedown', handleMouseDown);
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
    };
  }, [isFullscreen, handleWheel, handleMouseDown, handleMouseMove, handleMouseUp]);

  const openFullscreen = useCallback(() => {
    setIsFullscreen(true);
  }, []);

  const closeFullscreen = useCallback(() => {
    setIsFullscreen(false);
  }, []);

  const zoomIn = useCallback(() => {
    setZoom((z) => Math.min(5, z + 0.5));
  }, []);

  const zoomOut = useCallback(() => {
    setZoom((z) => Math.max(0.25, z - 0.5));
  }, []);

  const resetView = useCallback(() => {
    setZoom(1);
    setPan({ x: 0, y: 0 });
  }, []);

  return (
    <>
      {/* Inline version (clickable to open fullscreen) */}
      <div
        onClick={openFullscreen}
        onKeyDown={(e) => e.key === 'Enter' && openFullscreen()}
        role="button"
        tabIndex={0}
        className="inline-block cursor-pointer transition-opacity hover:opacity-80"
        style={{ maxWidth: '100%' }}
        title="Click to view fullscreen"
      >
        <div dangerouslySetInnerHTML={{ __html: getSvgContent() }} />
      </div>

      {/* Fullscreen modal overlay */}
      {isFullscreen && (
        <div
          ref={fullscreenRef}
          className="fixed inset-0 z-50 bg-black/95 flex items-center justify-center"
          style={{ cursor: isDragging ? 'grabbing' : 'grab' }}
        >
          {/* Close button */}
          <button
            onClick={closeFullscreen}
            className="absolute top-4 right-4 z-20 p-3 rounded-full bg-white/10 hover:bg-white/20 text-white transition-colors"
            aria-label="Close fullscreen (Escape)"
          >
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor" className="w-6 h-6">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>

          {/* Zoom controls */}
          <div className="absolute bottom-4 right-4 z-20 flex gap-2">
            <button
              onClick={zoomIn}
              className="p-3 rounded-lg bg-white/10 hover:bg-white/20 text-white transition-colors"
              aria-label="Zoom in"
            >
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor" className="w-5 h-5">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 6v6m0 0v6m0-6h6m-6 0H6" />
              </svg>
            </button>
            <button
              onClick={zoomOut}
              className="p-3 rounded-lg bg-white/10 hover:bg-white/20 text-white transition-colors"
              aria-label="Zoom out"
            >
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor" className="w-5 h-5">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M20 12H4" />
              </svg>
            </button>
            <button
              onClick={resetView}
              className="p-3 rounded-lg bg-white/10 hover:bg-white/20 text-white transition-colors"
              aria-label="Reset view"
            >
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor" className="w-5 h-5">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
              </svg>
            </button>
          </div>

          {/* Zoom level indicator */}
          <div className="absolute top-4 left-4 z-20 px-3 py-1 rounded bg-white/10 text-white text-sm font-mono">
            {Math.round(zoom * 100)}%
          </div>

          {/* SVG container with transform */}
          <div
            className="w-full h-full flex items-center justify-center overflow-hidden pointer-events-none"
          >
            <div
              style={{
                transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})`,
                transformOrigin: 'center center',
                transition: isDragging ? 'none' : 'transform 0.1s ease-out'
              }}
            >
              <div
                dangerouslySetInnerHTML={{ __html: getSvgContent() }}
                className="select-none"
              />
            </div>
          </div>

          {/* Instructions hint */}
          <div className="absolute bottom-4 left-4 z-20 text-xs text-white/50">
            Scroll to zoom &bull; Drag to pan &bull; Escape to close
          </div>
        </div>
      )}
    </>
  );
}

export default MermaidDiagramViewer;
