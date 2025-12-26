import { Point } from '../math/geometry';

export type DrawingToolType =
  | 'freedraw'
  | 'highlight'
  | 'vertical'
  | 'horizontal'
  | 'cross'
  | 'trendline'
  | 'ray'
  | 'extended'
  | 'rectangle'
  | 'circle'
  | 'triangle'
  | 'channel';

export interface DrawingPoint {
  logical: number;
  price: number;
}

export interface DrawingStyle {
  color: string;
  lineWidth: number;
  lineStyle: 'solid' | 'dashed' | 'dotted';
  fillColor?: string;
  fillOpacity?: number;
}

export interface Drawing {
  id: string;
  type: DrawingToolType;
  points: DrawingPoint[];
  style: DrawingStyle;
  locked?: boolean;
  paneIndex?: number;
}

export interface IDrawingTool {
  type: DrawingToolType;
  requiredPoints: number; // -1 for variable (freedraw)
  hitTest(point: Point, screenPoints: Point[]): boolean;
  render(ctx: CanvasRenderingContext2D, screenPoints: Point[], style: DrawingStyle, isTemp?: boolean): void;
}
