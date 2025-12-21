# Border Radius System

Consistent border radius values across the application.

## Radius Scale

| Class | Value | Use Case | Examples |
|-------|-------|----------|----------|
| `rounded-xs` | 6px | Checkboxes, badges, tags, kbd, chips | `<Checkbox>`, `<kbd>`, chain badges |
| `rounded-sm` | 8px | Buttons, inputs, selects | `<Button>`, `<Input>`, `<Select>` |
| `rounded-md` | 12px | Cards, forms, containers | `<Card>`, form containers |
| `rounded-lg` | 16px | Modals, large containers | `<Dialog>`, modals |

## CSS Variables

Located in `src/styles/constants.css`:

```css
--radius-xs: 6px;   /* checkboxes, badges, tags, kbd */
--radius-sm: 8px;   /* buttons, inputs */
--radius-md: 12px;  /* cards, forms */
--radius-lg: 16px;  /* modals, containers */
```

## Tailwind Configuration

Located in `tailwind.config.js`:

```js
borderRadius: {
  'none': '0',
  'xs': 'var(--radius-xs)',
  'sm': 'var(--radius-sm)',
  'md': 'var(--radius-md)',
  'lg': 'var(--radius-lg)',
  'xl': 'var(--radius-lg)',   // alias
  '2xl': 'var(--radius-lg)',  // alias
  'full': '9999px',
  DEFAULT: 'var(--radius-md)',
}
```

## Component Guidelines

### Small UI Elements (rounded-xs - 5px)
- Checkboxes: `<Checkbox>`
- Badges & Tags: inline spans with `px-1.5 py-0.5`
- Keyboard shortcuts: `<kbd>`
- Chain badges: `<ChainBadge>`
- Small icons/avatars

### Interactive Elements (rounded-sm - 8px)
- Buttons: all `<Button>` variants
- Form inputs: `<Input>`, `<Select>`
- Dropdown menu items
- Interactive list items

### Content Containers (rounded-md - 12px)
- Cards: `<Card>`
- Form sections
- Content panels
- Token rows

### Overlays & Modals (rounded-lg - 16px)
- Dialog/Modal: `<Dialog>`
- Large popovers
- Drawer panels
- Toast notifications

## Button Groups

For button groups (multiple buttons in a container), use:
- Container: `border border-border rounded-xs bg-bg-2 overflow-hidden`
- First button: `rounded-l-xs rounded-r-none border-r border-border`
- Middle buttons: `rounded-none border-r border-border`
- Last button: `rounded-r-xs rounded-l-none`

Example:
```tsx
<div className="flex border border-border rounded-xs bg-bg-2 overflow-hidden">
  <button className="rounded-l-xs rounded-r-none border-r border-border">First</button>
  <button className="rounded-r-xs rounded-l-none">Last</button>
</div>
```

## Migration Notes

Changed from previous system:
- Old `rounded-sm` (2px) → New `rounded-xs` (6px) for small UI
- Old `rounded-md` (6px) → New `rounded-sm` (8px) for buttons
- Old `rounded-lg` (8px) → New `rounded-md` (12px) for cards
- Dialog modals now use `rounded-lg` (16px)
