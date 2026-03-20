import { useEffect, useRef } from 'preact/hooks';
import { getGPUInfo } from '@utils/gpu-detection';
import { logger } from '@sdk/utils';

const log = logger.withContext('WebGLRenderer');

interface WebGLRendererProps {
  shaders: string[];
  uniforms: Record<string, number>;
  maxWidth?: number;
  maxHeight?: number;
  className?: string;
  onGPUInfoDetected?: (hasGPU: boolean, renderer: string) => void;
}

interface BgState {
  time: number;
  prevTime: number;
  computedTime: number;
  speed: number;
  lastFrame: number;
}

const bgState: BgState = {
  time: 0,
  prevTime: 0,
  computedTime: 0,
  speed: 0.1,
  lastFrame: 0,
};

// Target ~30fps (33ms per frame) for significant CPU savings
const TARGET_FRAME_TIME = 33;

async function fetchShader(path: string): Promise<string> {
  const response = await fetch(path);
  if (!response.ok) {
    throw new Error(`Failed to fetch shader: ${path}`);
  }
  return response.text();
}

function createShader(gl: WebGLRenderingContext, type: number, source: string): WebGLShader | null {
  const shader = gl.createShader(type);
  if (!shader) return null;

  gl.shaderSource(shader, source);
  gl.compileShader(shader);

  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    log.error('Shader compile error', gl.getShaderInfoLog(shader));
    gl.deleteShader(shader);
    return null;
  }

  return shader;
}

function createProgram(
  gl: WebGLRenderingContext,
  vertexShader: WebGLShader,
  fragmentShader: WebGLShader
): WebGLProgram | null {
  const program = gl.createProgram();
  if (!program) return null;

  gl.attachShader(program, vertexShader);
  gl.attachShader(program, fragmentShader);
  gl.linkProgram(program);

  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    log.error('Program link error', gl.getProgramInfoLog(program));
    gl.deleteShader(program);
    return null;
  }

  return program;
}

async function fetchCreateProgram(
  gl: WebGLRenderingContext,
  shaderPaths: string[]
): Promise<WebGLProgram> {
  const [fragSource, vertSource] = await Promise.all([
    fetchShader(`/shaders/${shaderPaths[0]}`),
    fetchShader(`/shaders/${shaderPaths[1]}`),
  ]);

  const vertShader = createShader(gl, gl.VERTEX_SHADER, vertSource);
  const fragShader = createShader(gl, gl.FRAGMENT_SHADER, fragSource);

  if (!vertShader || !fragShader) {
    throw new Error('Failed to create shaders');
  }

  const program = createProgram(gl, vertShader, fragShader);
  if (!program) {
    throw new Error('Failed to create program');
  }

  return program;
}

export function WebGLRenderer({
  shaders,
  uniforms,
  maxWidth = 1080,
  maxHeight = 1080,
  className = '',
  onGPUInfoDetected,
}: WebGLRendererProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const animationFrameRef = useRef<number>(0);
  const uniformsRef = useRef(uniforms);
  const gpuInfoDetectedRef = useRef(false);

  // Keep uniforms ref updated
  useEffect(() => {
    uniformsRef.current = uniforms;
  }, [uniforms]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    let width = 0;
    let height = 0;

    const resizeCanvas = () => {
      if (!canvas) return;

      const pxRatio = window.devicePixelRatio || 1;
      const rect = canvas.getBoundingClientRect();

      canvas.style.width = '100%';
      canvas.style.height = '100%';

      width = Math.round(rect.width * pxRatio);
      height = Math.round(rect.height * pxRatio);

      if (width > maxWidth || height > maxHeight) {
        const scaleW = maxWidth / width;
        const scaleH = maxHeight / height;
        const scale = Math.min(scaleW, scaleH);
        width = Math.round(width * scale);
        height = Math.round(height * scale);
      }

      canvas.width = width;
      canvas.height = height;
    };

    const initRenderer = async () => {
      // Detect GPU info if callback is provided
      if (onGPUInfoDetected && !gpuInfoDetectedRef.current) {
        gpuInfoDetectedRef.current = true;
        const gpuInfo = await getGPUInfo();
        onGPUInfoDetected(gpuInfo.hasGPU, gpuInfo.renderer);
      }

      const gl = canvas.getContext('webgl');
      if (!gl) {
        log.error('WebGL not supported');
        return;
      }

      resizeCanvas();

      const prog = await fetchCreateProgram(gl, shaders);

      const positionAttributeLocation = gl.getAttribLocation(prog, 'a_position');
      const positionBuffer = gl.createBuffer();

      gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
      gl.bufferData(
        gl.ARRAY_BUFFER,
        new Float32Array([
          -1, -1,
          1, -1,
          -1, 1,
          -1, 1,
          1, -1,
          1, 1,
        ]),
        gl.STATIC_DRAW
      );

      const resolutionLocation = gl.getUniformLocation(prog, 'iResolution');
      const computedTimeLocation = gl.getUniformLocation(prog, 'iTime');

      const uniformLocations: Record<string, WebGLUniformLocation | null> = {};
      for (const name of Object.keys(uniformsRef.current)) {
        uniformLocations[name] = gl.getUniformLocation(prog, name);
      }

      const render = (timestamp: number) => {
        // Throttle to ~30fps
        const elapsed = timestamp - bgState.lastFrame;
        if (elapsed < TARGET_FRAME_TIME) {
          animationFrameRef.current = requestAnimationFrame(render);
          return;
        }
        bgState.lastFrame = timestamp;

        bgState.time = timestamp * 0.001;
        bgState.computedTime += (bgState.time - bgState.prevTime) * bgState.speed;
        bgState.prevTime = bgState.time;

        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.useProgram(prog);
        gl.enableVertexAttribArray(positionAttributeLocation);
        gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
        gl.vertexAttribPointer(positionAttributeLocation, 2, gl.FLOAT, false, 0, 0);

        gl.uniform2f(resolutionLocation, canvas.width, canvas.height);
        gl.uniform1f(computedTimeLocation, bgState.computedTime);

        for (const [name, value] of Object.entries(uniformsRef.current)) {
          const location = uniformLocations[name];
          if (location !== null) {
            gl.uniform1f(location, value);
          }
        }

        gl.clearColor(0, 0, 0, 1);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.drawArrays(gl.TRIANGLES, 0, 6);

        animationFrameRef.current = requestAnimationFrame(render);
      };

      const resizeObserver = new ResizeObserver(() => {
        resizeCanvas();
      });
      resizeObserver.observe(canvas);

      window.addEventListener('resize', resizeCanvas);

      // Initialize timing state before first render
      bgState.lastFrame = performance.now();
      bgState.prevTime = bgState.lastFrame * 0.001;
      animationFrameRef.current = requestAnimationFrame(render);

      return () => {
        resizeObserver.disconnect();
        window.removeEventListener('resize', resizeCanvas);
        cancelAnimationFrame(animationFrameRef.current);
      };
    };

    const cleanupPromise = initRenderer();

    return () => {
      cleanupPromise.then((cleanup) => cleanup?.());
      cancelAnimationFrame(animationFrameRef.current);
    };
  }, [shaders, maxWidth, maxHeight]);

  return (
    <canvas
      ref={canvasRef}
      className={`w-full h-full ${className}`}
      style={{
        imageRendering: 'pixelated',
      }}
    />
  );
}
