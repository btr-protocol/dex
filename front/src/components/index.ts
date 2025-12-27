/**
 * Components Module
 *
 * Organized using Domain-Driven Atomic Design:
 * - ui/ → Pure stateless design system atoms
 * - shared/ → Domain-aware reusable components
 * - features/ → Domain-specific logic-heavy modules
 * - layout/ → App shell and page templates
 */

// ─────────────────────────────────────────────────────────────
// UI System (Pure Design Atoms)
// ─────────────────────────────────────────────────────────────
export * from './ui/index';

// ─────────────────────────────────────────────────────────────
// Shared Components (Domain Atoms)
// ─────────────────────────────────────────────────────────────
export * from './shared/token/index';
export * from './shared/chain/index';
export * from './shared/metrics/index';
export * from './shared/ui-utilities/index';

// ─────────────────────────────────────────────────────────────
// Layout (App Shell)
// ─────────────────────────────────────────────────────────────
export { Header } from './layout/Header';
export { Footer } from './layout/Footer';
export { PageContainer } from './layout/PageContainer';

// ─────────────────────────────────────────────────────────────
// Feature Modules (Import specific submodules as needed)
// ─────────────────────────────────────────────────────────────
// import { SwapForm } from '@components/features/swap'
// import { DocsLayout } from '@components/features/docs'
// etc.
//
// This prevents a barrel export of all features which would defeat
// code-splitting benefits. Import directly from features/ instead.
