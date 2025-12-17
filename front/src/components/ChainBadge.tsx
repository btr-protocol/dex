interface ChainInfo {
  name: string;
  icon: string;
}

interface ChainBadgeProps {
  chain: ChainInfo;
  size?: 'sm' | 'md' | 'lg';
  position?: 'overlay' | 'inline';
}

const sizeMap = {
  sm: { width: 'w-4 h-4', borderRadius: '3px' },
  md: { width: 'w-5 h-5', borderRadius: '4px' },
  lg: { width: 'w-6 h-6', borderRadius: '5px' },
};

const positionMap = {
  overlay: 'absolute -bottom-1 -right-2',
  inline: 'relative',
};

export function ChainBadge({ chain, size = 'md', position = 'overlay' }: ChainBadgeProps) {
  const sizeConfig = sizeMap[size];
  const positionClass = positionMap[position];

  return (
    <div
      className={`${sizeConfig.width} ${positionClass} overflow-hidden`}
      style={{
        borderRadius: sizeConfig.borderRadius,
        backgroundColor: 'var(--bg-1)',
        border: '1px solid var(--border-color)',
      }}
      title={chain.name}
    >
      <img
        src={chain.icon}
        alt={chain.name}
        className="w-full h-full object-cover"
      />
    </div>
  );
}
