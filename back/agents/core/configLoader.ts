import type { AgentConfig } from './types.js';

async function loadArchivistConfig(): Promise<AgentConfig | null> {
  try {
    let path: string;

    if (import.meta.dir) {
      path = `${import.meta.dir}/../archivist/config.ts`;
    } else {
      path = `${process.cwd()}/back/agents/archivist/config.ts`;
    }

    const module = await import(path);
    return module.config as AgentConfig;
  } catch {
    return null;
  }
}

export { loadArchivistConfig };
