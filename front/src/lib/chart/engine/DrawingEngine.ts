import { Drawing, IDrawingTool, DrawingToolType } from './types';
import { Point } from '../math/geometry';
import { signal } from '@preact/signals';

export class DrawingEngine {
  // Use signals for reactive data that doesn't need to trigger full component re-renders
  public drawings = signal<Drawing[]>([]);
  public selectedIds = signal<Set<string>>(new Set());
  private tools = new Map<DrawingToolType, IDrawingTool>();
  
  // Keep onUpdate for legacy support if needed, but signals are preferred
  private onUpdate?: () => void;

  constructor(onUpdate?: () => void) {
    this.onUpdate = onUpdate;
  }

  registerTool(tool: IDrawingTool) {
    this.tools.set(tool.type, tool);
  }

  getDrawings() {
    return this.drawings.value;
  }

  setDrawings(drawings: Drawing[]) {
    this.drawings.value = [...drawings];
    this.onUpdate?.();
  }

  addDrawing(drawing: Drawing) {
    this.drawings.value = [...this.drawings.value, drawing];
    this.onUpdate?.();
  }

  deleteSelected() {
    this.drawings.value = this.drawings.value.filter(d => !this.selectedIds.value.has(d.id));
    this.selectedIds.value = new Set();
    this.onUpdate?.();
  }

  clearAll() {
    this.drawings.value = [];
    this.selectedIds.value = new Set();
    this.onUpdate?.();
  }

  selectAt(x: number, y: number, screenPointsMap: Map<string, Point[]>): boolean {
    const point = { x, y };
    const drawings = this.drawings.value;

    for (let i = drawings.length - 1; i >= 0; i--) {
      const d = drawings[i];
      const tool = this.tools.get(d.type);
      const pts = screenPointsMap.get(d.id);

      if (tool && pts && tool.hitTest(point, pts)) {
        const newSelection = new Set<string>();
        newSelection.add(d.id);
        this.selectedIds.value = newSelection;
        this.onUpdate?.();
        return true;
      }
    }

    if (this.selectedIds.value.size > 0) {
      this.selectedIds.value = new Set();
      this.onUpdate?.();
    }
    return false;
  }

  getSelectedIds() {
    return this.selectedIds.value;
  }
}