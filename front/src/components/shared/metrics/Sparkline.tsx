import { SimpleSparkline } from '@components/ui/SimpleSparkline';

interface SparklineProps {
  data: number[];
  width?: number;
  height?: number;
  color?: string;
}

export function Sparkline(props: SparklineProps) {
  return <SimpleSparkline {...props} />;
}
