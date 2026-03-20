/**
 * Shared utilities for the hybrid search system.
 * Consolidates common functions used across lexical, semantic, and indexing modules.
 */

import { resolve } from 'path';

/**
 * Project root directory - works from any directory in the project.
 * Resolves from search/ -> agents/ -> back/ -> project root
 */
export const PROJECT_ROOT = resolve(import.meta.dir, '../../../');

/**
 * Infer programming language from file path extension.
 */
export function inferLanguage(filePath: string): string {
  const ext = filePath.split('.').pop()?.toLowerCase() || '';

  const langMap: Record<string, string> = {
    'ts': 'typescript',
    'tsx': 'typescript',
    'sol': 'solidity',
    'js': 'javascript',
    'jsx': 'javascript',
    'md': 'markdown',
    'markdown': 'markdown',
    'json': 'json',
    'yaml': 'yaml',
    'yml': 'yaml',
  };

  return langMap[ext] || 'unknown';
}

/**
 * Infer source type (code vs docs) from file path.
 */
export function inferSourceType(filePath: string): 'code' | 'docs' {
  const ext = filePath.split('.').pop()?.toLowerCase() || '';
  return ['ts', 'tsx', 'js', 'jsx', 'sol'].includes(ext) ? 'code' : 'docs';
}

/**
 * Escape string for SQL queries (LanceDB uses SQL-like syntax).
 * Handles single quotes and backslashes.
 */
export function escapeSqlString(str: string): string {
  return str
    .replace(/\\/g, '\\\\')  // Escape backslashes first
    .replace(/'/g, "''");     // Escape single quotes
}

/**
 * Parse line range from file string.
 * Example: "path/to/file.sol:10-25" -> { start: 10, end: 25 }
 */
export function parseLineRange(file: string): { start: number; end: number } | null {
  const match = file.match(/:(\d+)-(\d+)$/);
  if (!match) return null;
  return { start: parseInt(match[1]!, 10), end: parseInt(match[2]!, 10) };
}

/**
 * Update file string with new line range.
 */
export function updateLineRange(file: string, newRange: { start: number; end: number }): string {
  return file.replace(/:\d+-\d+$/, `:${newRange.start}-${newRange.end}`);
}

/**
 * Merge two line ranges into a combined range.
 * Example: {10-17} + {14-23} = {10-23}
 */
export function mergeLineRanges(
  range1: { start: number; end: number } | null,
  range2: { start: number; end: number } | null
): { start: number; end: number } | null {
  if (!range1) return range2;
  if (!range2) return range1;
  return {
    start: Math.min(range1.start, range2.start),
    end: Math.max(range1.end, range2.end)
  };
}

/**
 * Merge content from two search results with line-based deduplication.
 * Removes duplicate lines that appear in both results.
 */
export function mergeContentWithDedup(content1: string, content2: string): string {
  const lines1 = content1.split('\n');
  const lines2 = content2.split('\n');

  // Create a set of normalized lines from content1 for dedup
  const seen = new Set(lines1.map(line => line.trim()));

  // Add only lines from content2 that aren't duplicates
  const newLines = lines2.filter(line => {
    const trimmed = line.trim();
    // Skip empty lines and already seen content
    if (!trimmed || seen.has(trimmed)) return false;
    seen.add(trimmed);
    return true;
  });

  if (newLines.length === 0) {
    return content1;
  }

  return [...lines1, '...', ...newLines].join('\n');
}
