import { WebGLRenderer } from './WebGLRenderer';
import { useSettings } from '@lib/settings';
import { useTheme } from '@lib/theme';

export function BgRenderer() {
  const { settings } = useSettings();
  const { theme } = useTheme();

  if (!settings.animateBackground) {
    return null;
  }

  // Theme colors as normalized RGB values
  // Dark theme: --black (#1B1B1B) = 0.106, --white (#FBF8F4) = 0.984
  // Light theme: inverted
  const isDark = theme === 'dark';

  return (
    <div className="fixed inset-0 z-0 pointer-events-none">
      <WebGLRenderer
        shaders={['main.glsl', 'base-vert.glsl']}
        uniforms={{
          uRingCount: settings.ringCount,
          uVelocityFactor: settings.rotationSpeed,
          uEyeSize: settings.eyeSize / 100.0,
          uIsDark: isDark ? 1.0 : 0.0,
        }}
      />
    </div>
  );
}
