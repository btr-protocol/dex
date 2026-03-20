import { execSync } from 'node:child_process';
import { resolve } from 'node:path';
import { existsSync } from 'node:fs';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('q4-setup');

const HF_BASE_URL = 'https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/resolve/main';

/**
 * Find the EmbeddingGemma model snapshot directory
 */
function getModelSnapshotDir(baseDir: string): string | null {
  try {
    const result = execSync(
      `find "${baseDir}/models--onnx-community--embeddinggemma-300m-ONNX/snapshots" -name "onnx" -type d 2>/dev/null | head -1`,
      { encoding: 'utf8', stdio: 'pipe' }
    );
    return result.trim() || null;
  } catch {
    return null;
  }
}

/**
 * Download a file from Hugging Face with progress indicator
 */
async function downloadHF(url: string, dest: string): Promise<void> {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to download ${url}: ${response.statusText}`);
  }

  const reader = response.body?.getReader();
  if (!reader) throw new Error('No response body');

  const buffer = await response.arrayBuffer();
  const bufferData = Buffer.from(buffer);

  // Write using Bun
  await Bun.write(dest, bufferData);
}

/**
 * Set up Q4 quantized model for EmbeddingGemma
 *
 * This ensures TEI uses the Q4 quantized weights (~188MB) instead of
 * the default fp32 weights (~1.1GB), reducing memory by ~6x with
 * minimal accuracy loss.
 *
 * The strategy:
 * 1. Download model_q4.onnx and model_q4.onnx_data if not present
 * 2. Backup existing symlinks (model.onnx.fp32.bak)
 * 3. Create new symlinks: model.onnx -> model_q4.onnx
 *
 * @param dataDir - Base data directory (default: back/agents/search/semantic/.data)
 * @returns true if Q4 setup was performed, false if already configured
 */
export async function setupQ4Model(dataDir?: string): Promise<{ configured: boolean; message: string }> {
  const baseDir = dataDir || resolve(process.cwd(), 'back/agents/search/semantic/.data');

  // Find the snapshot directory
  const snapshotDir = getModelSnapshotDir(baseDir);
  if (!snapshotDir) {
    return { configured: false, message: 'Model directory not found (run TEI once first to download)' };
  }

  const onnxDir = resolve(snapshotDir);
  const q4ModelFile = resolve(onnxDir, 'model_q4.onnx');
  const q4DataFile = resolve(onnxDir, 'model_q4.onnx_data');
  const modelLink = resolve(onnxDir, 'model.onnx');
  const modelDataLink = resolve(onnxDir, 'model.onnx_data');

  // Check if Q4 is already configured (symlinks point to Q4)
  try {
    const linkTarget = execSync(`readlink "${modelLink}"`, { encoding: 'utf8', stdio: 'pipe' }).trim();
    if (linkTarget === 'model_q4.onnx') {
      return { configured: false, message: 'Q4 model already configured' };
    }
  } catch {
    // Link doesn't exist or isn't a symlink - continue setup
  }

  log.info('📦 Setting up Q4 quantized model...');

  // Download Q4 files if missing
  if (!existsSync(q4ModelFile)) {
    log.info('   Downloading model_q4.onnx (~500KB)...');
    await downloadHF(`${HF_BASE_URL}/onnx/model_q4.onnx`, q4ModelFile);
    log.info('   ✓ model_q4.onnx downloaded');
  }

  if (!existsSync(q4DataFile)) {
    log.info('   Downloading model_q4.onnx_data (~188MB)...');
    await downloadHF(`${HF_BASE_URL}/onnx/model_q4.onnx_data`, q4DataFile);
    log.info('   ✓ model_q4.onnx_data downloaded');
  }

  // Backup existing symlinks if they exist and aren't already backed up
  const fp32Bak = resolve(onnxDir, 'model.onnx.fp32.bak');
  const fp32DataBak = resolve(onnxDir, 'model.onnx_data.fp32.bak');

  if (existsSync(modelLink) && !existsSync(fp32Bak)) {
    execSync(`cd "${onnxDir}" && mv model.onnx model.onnx.fp32.bak`, { stdio: 'pipe' });
  }
  if (existsSync(modelDataLink) && !existsSync(fp32DataBak)) {
    execSync(`cd "${onnxDir}" && mv model.onnx_data model.onnx_data.fp32.bak`, { stdio: 'pipe' });
  }

  // Create new symlinks pointing to Q4
  execSync(`cd "${onnxDir}" && ln -sf model_q4.onnx model.onnx`, { stdio: 'pipe' });
  execSync(`cd "${onnxDir}" && ln -sf model_q4.onnx_data model.onnx_data`, { stdio: 'pipe' });

  // Verify
  const newTarget = execSync(`readlink "${modelLink}"`, { encoding: 'utf8', stdio: 'pipe' }).trim();
  if (newTarget !== 'model_q4.onnx') {
    return { configured: false, message: 'Failed to create Q4 symlinks' };
  }

  // Get file size for confirmation
  const q4Size = execSync(`du -h "${q4DataFile}"`, { encoding: 'utf8', stdio: 'pipe' }).trim().split('\t')[0];

  log.info(`   ✅ Q4 model configured (${q4Size} vs ~1.1GB fp32)`);
  return { configured: true, message: `Q4 model configured (${q4Size})` };
}
