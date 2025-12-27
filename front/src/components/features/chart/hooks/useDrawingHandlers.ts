import { useCallback } from 'preact/hooks';
import type { JSX } from 'preact';
import type { DrawingToolType, DrawingToolsPrimitive } from '../DrawingTools';

interface UseDrawingHandlersProps {
  engine: DrawingToolsPrimitive | null;
  drawingTool: DrawingToolType | null;
  isAreaSelectMode: boolean;
  onToolChange: (tool: DrawingToolType | null) => void;
  onAreaSelectModeChange: (mode: boolean) => void;
  onSelectionChange: () => void;
}

export function useDrawingHandlers({
  engine,
  drawingTool,
  isAreaSelectMode,
  onToolChange,
  onAreaSelectModeChange,
  onSelectionChange,
}: UseDrawingHandlersProps) {
  const handlePointerDown = useCallback((e: JSX.TargetedPointerEvent<HTMLDivElement>) => {
    if (!engine) return;

    const rect = e.currentTarget.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    const singlePointTools = ['freedraw', 'highlight', 'vertical', 'horizontal', 'cross'] as const;

    if (drawingTool && singlePointTools.includes(drawingTool as any)) {
      const handled = engine.onPointerDown(x, y);
      if (handled) e.stopPropagation();
    } else if (drawingTool) {
      const handled = engine.onClick(x, y);
      if (handled) e.stopPropagation();
    } else if (isAreaSelectMode) {
      engine.startAreaSelect(x, y);
      e.stopPropagation();
    } else {
      const controlHit = engine.selectAt(x, y);
      if (controlHit || engine.isDragging()) {
        e.stopPropagation();
      }
    }

    onSelectionChange();
  }, [engine, drawingTool, isAreaSelectMode, onSelectionChange]);

  const handlePointerMove = useCallback((e: JSX.TargetedPointerEvent<HTMLDivElement>) => {
    if (!engine) return;

    const rect = e.currentTarget.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    if (engine.isAreaSelecting()) {
      e.stopPropagation();
      engine.updateAreaSelect(x, y);
      onSelectionChange();
      return;
    }

    if (engine.isDragging()) {
      e.stopPropagation();
      engine.onDragMove(x, y);
      return;
    }

    if (drawingTool && engine.isDrawingActive()) {
      e.stopPropagation();
    }

    engine.onPointerMove(x, y);
  }, [engine, drawingTool, onSelectionChange]);

  const handlePointerUp = useCallback(() => {
    if (!engine) return;

    if (engine.isAreaSelecting()) {
      engine.endAreaSelect();
      onSelectionChange();
      return;
    }

    engine.onPointerUp();
    engine.onDragEnd();
    onSelectionChange();
  }, [engine, onSelectionChange]);

  const handleSelectAll = useCallback(() => {
    if (!engine) return;
    engine.selectAll();
    onSelectionChange();
  }, [engine, onSelectionChange]);

  const handleDelete = useCallback(() => {
    if (!engine) return;
    engine.deleteSelected();
    onSelectionChange();
  }, [engine, onSelectionChange]);

  const handleStyleChange = useCallback((style: { color?: string; fillColor?: string }) => {
    if (!engine) return;
    engine.updateSelectedStyle(style);
  }, [engine]);

  const handleKeyDown = useCallback((e: KeyboardEvent) => {
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;

    if ((e.key === 'Delete' || e.key === 'Backspace') && engine?.getSelectedCount()! > 0) {
      e.preventDefault();
      handleDelete();
    } else if (e.key === 'Escape') {
      if (drawingTool) onToolChange(null);
      if (isAreaSelectMode) onAreaSelectModeChange(false);
      if (engine) {
        engine.clearSelection();
        onSelectionChange();
      }
    }
  }, [engine, drawingTool, isAreaSelectMode, handleDelete, onToolChange, onAreaSelectModeChange, onSelectionChange]);

  return {
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
    handleSelectAll,
    handleDelete,
    handleStyleChange,
    handleKeyDown,
  };
}
