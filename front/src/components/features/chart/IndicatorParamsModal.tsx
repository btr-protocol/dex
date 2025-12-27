/**
 * Modal for editing indicator parameters
 */
import { BaseModal } from '@components/ui/BaseModal';
import { ModalActions } from '@components/ui/ModalActions';
import type { IndicatorParams } from '@utils/indicators';
import { type IndicatorKey, getIndicatorBaseName } from './indicatorsConfig';

interface IndicatorParamsModalProps {
  open: boolean;
  preset: IndicatorKey | null;
  params: IndicatorParams;
  onChange: (p: IndicatorParams) => void;
  onCancel: () => void;
  onApply: () => void;
}

export function IndicatorParamsModal({
  open,
  preset,
  params,
  onChange,
  onCancel,
  onApply,
}: IndicatorParamsModalProps) {
  return (
    <BaseModal
      isOpen={open}
      onClose={onCancel}
      title={preset ? `${getIndicatorBaseName(preset)} Parameters` : 'Parameters'}
      headerType="title"
      maxWidth="max-w-xs"
      footerControls={
        <ModalActions
          onCancel={onCancel}
          onConfirm={onApply}
          confirmLabel="Apply"
        />
      }
    >
      <div className="p-4 space-y-3">
        <ParamInput
          label="MTF Fast Period"
          value={params.fast}
          min={1}
          max={100}
          onChange={v => onChange({ ...params, fast: v })}
        />
        <ParamInput
          label="MTF Slow Period"
          value={params.slow}
          min={1}
          max={200}
          onChange={v => onChange({ ...params, slow: v })}
        />
        <ParamInput
          label="Signal Period"
          value={params.signal}
          min={1}
          max={100}
          onChange={v => onChange({ ...params, signal: v })}
        />
      </div>
    </BaseModal>
  );
}

function ParamInput({
  label,
  value,
  min,
  max,
  onChange,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  onChange: (v: number) => void;
}) {
  return (
    <label className="flex items-center justify-between gap-4 text-sm">
      <span className="text-fg-2">{label}</span>
      <input
        type="number"
        min={min}
        max={max}
        value={value}
        onChange={e => onChange(parseInt((e.target as HTMLInputElement).value) || 1)}
        lang="en-US"
        className="w-20 px-2 py-1.5 bg-bg-2 border border-border rounded-xs text-fg-1 text-right"
      />
    </label>
  );
}
