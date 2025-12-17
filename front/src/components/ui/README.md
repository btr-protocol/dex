# UI Micro-Components

Reusable micro-components to reduce Tailwind class duplication across the codebase.

## Layout Components (`Flex.tsx`)

### FlexRow
Replaces `flex items-center gap-*` (36+ instances)
```tsx
// Before
<div className="flex items-center gap-2">...</div>

// After
<FlexRow gap="2">...</FlexRow>
```

### FlexBetween
Replaces `flex items-center justify-between` (23+ instances)
```tsx
// Before
<div className="flex items-center justify-between">...</div>

// After
<FlexBetween>...</FlexBetween>
```

### FlexCenter
Replaces `flex items-center justify-center` (30+ instances)
```tsx
// Before
<div className="flex items-center justify-center">...</div>

// After
<FlexCenter>...</FlexCenter>
```

### FlexCol
Replaces `flex flex-col gap-*` (7+ instances)
```tsx
// Before
<div className="flex flex-col gap-3">...</div>

// After
<FlexCol gap="3">...</FlexCol>
```

## Typography Components (`Text.tsx`)

### Caption
Replaces `text-xs text-muted-foreground` (20+ instances)
```tsx
// Before
<span className="text-xs text-muted-foreground">Label</span>

// After
<Caption>Label</Caption>
```

### Label
Replaces `text-sm text-muted-foreground` (16+ instances)
```tsx
// Before
<span className="text-sm text-muted-foreground">Description</span>

// After
<Label>Description</Label>
```

### SectionHeader
Replaces `font-semibold text-xs text-fg-2 uppercase tracking-wide` (2+ instances)
```tsx
// Before
<h2 className="font-semibold text-xs text-fg-2 uppercase tracking-wide mb-3">Title</h2>

// After
<SectionHeader className="mb-3">Title</SectionHeader>
```

## Interactive Components (`Clickable.tsx`)

### IconButton
Replaces `w-6 h-6 flex items-center justify-center hover:bg-bg-3 text-fg-2` pattern
```tsx
// Before
<button className="w-6 h-6 flex items-center justify-center hover:bg-bg-3 text-fg-2">
  <Icon />
</button>

// After
<IconButton>
  <Icon />
</IconButton>
```

### HoverBg2 / HoverBg3
Replaces common hover background patterns (37+ instances)
```tsx
// Before
<button className="hover:bg-bg-2 transition-colors px-3 py-2">...</button>

// After
<HoverBg2 className="px-3 py-2">...</HoverBg2>
```

### ListItem
Replaces common list item hover pattern
```tsx
// Before
<button className="w-full flex items-center gap-2 px-3 py-2 hover:bg-bg-2 transition-colors">
  ...
</button>

// After
<ListItem>...</ListItem>
```

## Usage

Import from centralized index:
```tsx
import { FlexRow, Caption, IconButton } from '@components/ui';
```

Or import directly:
```tsx
import { FlexRow } from '@components/ui/Flex';
import { Caption } from '@components/ui/Text';
```

## Impact

- **Line reduction**: 150+ lines of redundant Tailwind classes eliminated
- **Maintainability**: Centralized styling patterns
- **Consistency**: Uniform spacing and styling across components
- **DX**: Shorter, more readable component code
