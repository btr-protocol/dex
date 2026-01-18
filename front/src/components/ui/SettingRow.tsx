import { ComponentChildren } from 'preact';

export interface SettingRowProps {
  label: string;
  children: ComponentChildren;
}

export function SettingRow({ label, children }: SettingRowProps) {
  return (
    <div className="flex items-center justify-between gap-4">
      <span className="text-sm text-muted-foreground font-normal">{label}</span>
      {children}
    </div>
  );
}
