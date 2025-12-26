import { useMemo } from 'preact/hooks';
import { signal } from '@preact/signals';
import { DrawingEngine } from '@/lib/chart/engine/DrawingEngine';
import { RectangleTool } from '@/lib/chart/tools/RectangleTool';
import { LineTool } from '@/lib/chart/tools/LineTool';
import { CircleTool } from '@/lib/chart/tools/CircleTool';
import { DrawingToolType } from '@/lib/chart/engine/types';

export function useDrawingSystem() {
  const engine = useMemo(() => {
    const eng = new DrawingEngine();
    eng.registerTool(new RectangleTool());
    eng.registerTool(new LineTool());
    eng.registerTool(new CircleTool());
    return eng;
  }, []);

  // Use a signal for the active tool to avoid re-rendering the whole chart on tool change
  const activeTool = useMemo(() => signal<DrawingToolType | null>(null), []);

  return {
    engine,
    activeTool, // .value to read/write
    setActiveTool: (tool: DrawingToolType | null) => { activeTool.value = tool; },
  };
}
