import { useState, useMemo, useEffect } from 'preact/hooks';
import { BaseModal, MODAL_PADDING } from '@components/ui/BaseModal';
import { Accordion } from '@components/ui/Accordion';
import { Expandable } from '@components/ui/Expandable';
import { Switch } from '@components/ui/Switch';
import { Slider } from '@components/ui/Slider';
import { Input } from '@components/ui/Input';
import { Dropdown } from '@components/ui/Dropdown';
import { useTheme } from '@lib/theme';
import { useSettings } from '@lib/settings';
import { SETTINGS_SCHEMA, type SettingDef } from '@/config/settings';

interface SettingsModalProps {
  isOpen: boolean;
  onClose: (open: boolean) => void;
  initialSection?: string;
}

function renderSetting(setting: SettingDef, value: any, onChange: (val: any) => void) {
  const cfg = setting.config;

  if (cfg.type === 'toggle') {
    return (
      <div className="flex items-center justify-between gap-4">
        <span className="text-sm text-muted-foreground font-normal">{setting.label}</span>
        <Switch checked={value} onCheckedChange={onChange} />
      </div>
    );
  }

  if (cfg.type === 'number') {
    return (
      <div className="flex items-center justify-between gap-4">
        <span className="text-sm text-muted-foreground font-normal">{setting.label}</span>
        <Input
          variant="number"
          type="number"
          value={value}
          onInput={(e: Event) => onChange(parseFloat(((e.target as HTMLInputElement).value) || cfg.min.toString()))}
          step={cfg.step}
          min={cfg.min}
          max={cfg.max}
        />
      </div>
    );
  }

  if (cfg.type === 'slider') {
    return (
      <div className="flex flex-col gap-2">
        <span className="text-sm text-muted-foreground font-normal">{setting.label}</span>
        <Slider
          value={[value]}
          onValueChange={(v: number[]) => onChange(v[0])}
          min={cfg.min}
          max={cfg.max}
          step={cfg.step}
          formatValue={cfg.format}
          showTicks={true}
          tickCount={5}
        />
      </div>
    );
  }

  if (cfg.type === 'select') {
    return (
      <div className="flex items-center justify-between gap-4">
        <span className="text-sm text-muted-foreground font-normal">{setting.label}</span>
        <Dropdown
          items={cfg.options.map(opt => ({ value: opt.value, label: opt.label }))}
          value={value}
          onChange={(v) => onChange(v as string)}
          className="w-32"
        />
      </div>
    );
  }

  return null;
}

export function SettingsModal({ isOpen, onClose, initialSection }: SettingsModalProps) {
  const { settings, updateSetting } = useSettings();
  const { theme, setTheme } = useTheme();
  const [searchQuery, setSearchQuery] = useState('');

  // Reset search when modal opens
  useEffect(() => {
    if (isOpen) setSearchQuery('');
  }, [isOpen]);

  // Filter settings based on search
  const filteredSchema = useMemo(() => {
    if (!searchQuery) return SETTINGS_SCHEMA;

    const query = searchQuery.toLowerCase();
    return SETTINGS_SCHEMA.map(category => {
      const categoryMatches = category.label.toLowerCase().includes(query);
      return {
        ...category,
        settings: categoryMatches
          ? category.settings
          : category.settings.filter(setting =>
            setting.label.toLowerCase().includes(query) ||
            setting.id.toLowerCase().includes(query)
          )
      };
    }).filter(category => category.settings.length > 0);
  }, [searchQuery]);

  return (
    <BaseModal
      isOpen={isOpen}
      onClose={onClose}
      title="Settings"
      headerType="input"
      placeholder="Search settings..."
      searchValue={searchQuery}
      onSearchChange={setSearchQuery}
    >
      <div className={`${MODAL_PADDING} py-4`}>
        <Accordion defaultOpen={initialSection || "execution"} autoClose={!searchQuery} className="border border-border rounded-md overflow-hidden">
          {filteredSchema.map(category => {
            const Icon = category.icon;
            return (
              <Expandable key={category.id} id={category.id} header={category.label} icon={<Icon className="w-4 h-4" />}>
                <div className="flex flex-col gap-3">
                  {category.settings.map(setting => {
                    // Handle conditional rendering
                    if (setting.showIf && !settings[setting.showIf as keyof typeof settings]) return null;

                    // Special handling for theme (uses separate context)
                    if (setting.id === 'theme') {
                      return (
                        <div key={setting.id}>
                          {renderSetting(setting, theme, setTheme)}
                        </div>
                      );
                    }

                    return (
                      <div key={setting.id}>
                        {renderSetting(setting, settings[setting.id as keyof typeof settings], (val) => updateSetting(setting.id as keyof typeof settings, val))}
                      </div>
                    );
                  })}
                </div>
              </Expandable>
            );
          })}
        </Accordion>
      </div>
    </BaseModal>
  );
}
