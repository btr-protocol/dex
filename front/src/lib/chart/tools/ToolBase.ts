import { Point } from '../math/geometry';
import { IDrawingTool, DrawingStyle, DrawingToolType } from '../engine/types';

export abstract class ToolBase implements IDrawingTool {
  abstract type: DrawingToolType;
  abstract requiredPoints: number;

  abstract hitTest(point: Point, screenPoints: Point[]): boolean;
  abstract render(ctx: CanvasRenderingContext2D, screenPoints: Point[], style: DrawingStyle, isTemp?: boolean): void;

  protected setDash(ctx: CanvasRenderingContext2D, style: 'solid' | 'dashed' | 'dotted', width: number) {
    if (style === 'dashed') {
      ctx.setLineDash([width * 2, width * 1.5]);
    } else if (style === 'dotted') {
      ctx.setLineDash([width, width * 2]);
    } else {
      ctx.setLineDash([]);
    }
  }

  protected drawAnchors(ctx: CanvasRenderingContext2D, pts: Point[], color: string, ratio: number = 1) {
    const r = 4 * ratio;
    ctx.fillStyle = color;
    ctx.strokeStyle = '#FBF8F4'; // Default theme fg0
    ctx.lineWidth = ratio;
    ctx.setLineDash([]);

    for (const p of pts) {
      ctx.beginPath();
      ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();
    }
  }
}
