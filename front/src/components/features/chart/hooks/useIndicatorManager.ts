import { useState, useEffect, useCallback } from 'preact/hooks';
import type { IndicatorParams } from '@utils/indicators';
import type { IndicatorKey } from '../indicatorsConfig';
import type { InitialIndicator } from '../useIndicatorParams';
import { useIndicatorParams } from '../useIndicatorParams';
import { DEFAULT_PARAMS } from '../indicatorsConfig';

export interface IndicatorEditorState {
  editingKey: IndicatorKey | null;
  editDraft: IndicatorParams;
}

export function useIndicatorManager(
  activeIndicators: IndicatorKey[],
  initialIndicators: InitialIndicator[],
  onIndicatorsChange?: (indicators: InitialIndicator[]) => void
) {
  const { getParams, setParams } = useIndicatorParams(initialIndicators);
  const [editorState, setEditorState] = useState<IndicatorEditorState>({
    editingKey: null,
    editDraft: { ...DEFAULT_PARAMS },
  });

  // Notify parent when indicators change
  useEffect(() => {
    const indicators: InitialIndicator[] = activeIndicators.map(preset => ({
      preset,
      params: getParams(preset),
    }));
    onIndicatorsChange?.(indicators);
  }, [activeIndicators, getParams, onIndicatorsChange]);

  const openEditor = useCallback((key: IndicatorKey) => {
    setEditorState({
      editingKey: key,
      editDraft: { ...getParams(key) },
    });
  }, [getParams]);

  const closeEditor = useCallback(() => {
    setEditorState(prev => ({ ...prev, editingKey: null }));
  }, []);

  const applyParams = useCallback(() => {
    if (editorState.editingKey) {
      setParams(editorState.editingKey, editorState.editDraft);
      closeEditor();
    }
  }, [editorState, setParams, closeEditor]);

  const updateDraft = useCallback((params: IndicatorParams) => {
    setEditorState(prev => ({ ...prev, editDraft: params }));
  }, []);

  return {
    editorState,
    openEditor,
    closeEditor,
    applyParams,
    updateDraft,
    getParams,
  };
}
