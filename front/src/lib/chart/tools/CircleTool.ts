import { ToolBase } from './ToolBase';
import { Point, dist } from '../math/geometry';
import { DrawingStyle, DrawingToolType } from '../engine/types';

export class CircleTool extends ToolBase {
  type: DrawingToolType = 'circle';
  requiredPoints = 2;

  hitTest(p: Point, pts: Point[]): boolean {
    if (pts.length < 2) return false;
    const HIT_TOLERANCE = 8;
    const r = dist(pts[0], pts[1]);
    const d = dist(p, pts[0]);
    return Math.abs(d - r) <= HIT_TOLERANCE;
  }

  render(ctx: CanvasRenderingContext2D, pts: Point[], style: DrawingStyle, isTemp?: boolean) {
    if (pts.length < 2) return;
    const center = pts[0], edge = pts[1];
    const r = dist(center, edge);

    ctx.beginPath();
    ctx.arc(center.x, center.y, r, 0, Math.PI * 2);

    if (style.fillColor && style.fillColor !== 'transparent') {
      ctx.fillStyle = style.fillColor;
      ctx.globalAlpha = style.fillOpacity ?? 0.05;
      ctx.fill();
      ctx.globalAlpha = 1;
    }

    if (style.color !== 'transparent') {
      ctx.strokeStyle = style.color;
      ctx.lineWidth = style.lineWidth;
      this.setDash(ctx, isTemp ? 'dashed' : style.lineStyle, style.lineWidth);
      ctx.stroke();
    }
  }
}
