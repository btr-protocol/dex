import { ToolBase } from './ToolBase';
import { Point, distToSegment } from '../math/geometry';
import { DrawingStyle, DrawingToolType } from '../engine/types';

export class RectangleTool extends ToolBase {
  type: DrawingToolType = 'rectangle';
  requiredPoints = 2;

  hitTest(p: Point, pts: Point[]): boolean {
    if (pts.length < 2) return false;
    const HIT_TOLERANCE = 8;
    const corners = [
      pts[0],
      { x: pts[1].x, y: pts[0].y },
      pts[1],
      { x: pts[0].x, y: pts[1].y },
    ];
    for (let i = 0; i < 4; i++) {
      if (distToSegment(p, corners[i], corners[(i + 1) % 4]) <= HIT_TOLERANCE) return true;
    }
    return false;
  }

  render(ctx: CanvasRenderingContext2D, pts: Point[], style: DrawingStyle, isTemp?: boolean) {
    if (pts.length < 2) return;
    const a = pts[0], b = pts[1];
    const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
    const w = Math.abs(b.x - a.x), h = Math.abs(b.y - a.y);

    ctx.beginPath();
    ctx.rect(x, y, w, h);

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