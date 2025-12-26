import { ToolBase } from './ToolBase';
import { Point, distToSegment } from '../math/geometry';
import { DrawingStyle, DrawingToolType } from '../engine/types';

export class LineTool extends ToolBase {
  type: DrawingToolType = 'trendline';
  requiredPoints = 2;

  hitTest(p: Point, pts: Point[]): boolean {
    if (pts.length < 2) return false;
    const HIT_TOLERANCE = 8;
    return distToSegment(p, pts[0], pts[1]) <= HIT_TOLERANCE;
  }

  render(ctx: CanvasRenderingContext2D, pts: Point[], style: DrawingStyle, isTemp?: boolean) {
    if (pts.length < 2) return;
    if (style.color === 'transparent') return;

    ctx.strokeStyle = style.color;
    ctx.lineWidth = style.lineWidth;
    this.setDash(ctx, isTemp ? 'dashed' : style.lineStyle, style.lineWidth);
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    ctx.lineTo(pts[1].x, pts[1].y);
    ctx.stroke();
  }
}