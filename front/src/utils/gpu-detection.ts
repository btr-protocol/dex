export interface GPUInfo {
  hasGPU: boolean;
  renderer: string;
  method: 'webgl' | 'webgpu' | 'unknown';
}

const KNOWN_SOFTWARE_RENDERERS = ['swiftshader', 'llvmpipe', 'software', 'mesa', 'cpu'];

export async function detectGPUAcceleration(): Promise<GPUInfo> {
  const result: GPUInfo = {
    hasGPU: false,
    renderer: 'unknown',
    method: 'unknown' as const,
  };

  // Try WebGPU first (modern and more reliable)
  if ((navigator as any).gpu) {
    try {
      const adapter = await (navigator as any).gpu.requestAdapter();
      if (adapter) {
        result.method = 'webgpu';
        result.hasGPU = true;
        // WebGPU adapters are almost always hardware unless explicitly "software"
        try {
          const info = await adapter.requestAdapterInfo?.();
          if (info) {
            result.renderer = `${(info as any).vendor || 'Unknown'} ${(info as any).architecture || 'GPU'}`.trim();
          } else {
            result.renderer = 'WebGPU Adapter';
          }
        } catch {
          result.renderer = 'WebGPU Adapter';
        }
        return result;
      }
    } catch {
      // Fall through to WebGL
    }
  }

  // Fallback to WebGL
  const canvas = document.createElement('canvas');
  try {
    const contextAttributes = {
      failIfMajorPerformanceCaveat: true,
      powerPreference: 'high-performance' as const,
    };

    const gl = (
      canvas.getContext('webgl', contextAttributes as any) ||
      canvas.getContext('experimental-webgl', contextAttributes as any)
    ) as WebGLRenderingContext | null;

    if (gl) {
      result.method = 'webgl';

      // Try to get debug info (may be blocked by privacy settings)
      const debugInfo = gl.getExtension('WEBGL_debug_renderer_info') as any;
      if (debugInfo) {
        try {
          result.renderer = gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL) || 'WebGL';
          const lowerRenderer = result.renderer.toLowerCase();

          // Check known software rasterizers
          result.hasGPU = !KNOWN_SOFTWARE_RENDERERS.some(sw => lowerRenderer.includes(sw));
        } catch {
          // If we can't get the renderer string, assume it's OK
          result.hasGPU = true;
          result.renderer = 'WebGL (privacy masked)';
        }
      } else {
        // Extension blocked (privacy protection), but context created successfully
        // Assume it's likely hardware-accelerated (most common case)
        result.hasGPU = true;
        result.renderer = 'WebGL (info masked)';
      }
    } else {
      // Context creation failed
      result.hasGPU = false;
      result.renderer = 'No WebGL support';
    }
  } catch {
    result.hasGPU = false;
    result.renderer = 'Error detecting GPU';
  }

  return result;
}

// Cache the detection result
let cachedGPUInfo: GPUInfo | null = null;

export async function getGPUInfo(): Promise<GPUInfo> {
  if (cachedGPUInfo) {
    return cachedGPUInfo;
  }

  const info = await detectGPUAcceleration();
  cachedGPUInfo = info;
  return info;
}
