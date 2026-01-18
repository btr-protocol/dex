export const SOURCE_CATEGORIES = {
  contract: { icon: 'file-code', label: 'Contract' },
  sdk: { icon: 'code', label: 'SDK' },
  documentation: { icon: 'file-text', label: 'Docs' },
  test: { icon: 'flask', label: 'Test' },
} as const;

export const getCategoryIcon = (category: string): string => {
  return SOURCE_CATEGORIES[category as keyof typeof SOURCE_CATEGORIES]?.icon || 'file';
};

export const getCategoryLabel = (category: string): string => {
  return SOURCE_CATEGORIES[category as keyof typeof SOURCE_CATEGORIES]?.label || 'File';
};
