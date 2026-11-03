/**
 * Composites barrel — assembled from primitives, still product-agnostic.
 * Re-exported through the top-level `@ui` barrel (`../index.ts`).
 */

export { PageShell } from './PageShell';
export type { PageShellProps, PageShellWidth } from './PageShell';

export { SectionHeader } from './SectionHeader';
export type { SectionHeaderProps } from './SectionHeader';

export { Panel } from './Panel';
export type { PanelProps, PanelPadding, PanelTone } from './Panel';

export { FormField } from './FormField';
export type { FormFieldProps } from './FormField';

export { Modal, ModalBody, ModalFooter } from './Modal';
export type { ModalProps, ModalSize } from './Modal';

export { Drawer } from './Drawer';
export type { DrawerProps, DrawerSize, DrawerSide } from './Drawer';

export { Menu, MenuItem, MenuLabel, MenuSeparator } from './Menu';
export type { MenuProps, MenuItemProps, MenuMode } from './Menu';

export { Popover } from './Popover';
export type { PopoverProps } from './Popover';

export { Tabs, TabsList, Tab, TabsPanel } from './Tabs';
export type { TabsProps, TabProps, TabsPanelProps, TabsVariant } from './Tabs';

export { Accordion, AccordionItem } from './Accordion';
export type { AccordionProps, AccordionItemProps } from './Accordion';

export { Alert } from './Alert';
export type { AlertProps } from './Alert';

export { EmptyState } from './EmptyState';
export type { EmptyStateProps } from './EmptyState';

export { Toast } from './Toast';
export type { ToastProps } from './Toast';

export { Table } from './Table';
export type { TableProps, TableColumn, TableSort } from './Table';

export { Pagination } from './Pagination';
export type { PaginationProps } from './Pagination';

export { ProgressBar } from './ProgressBar';
export type { ProgressBarProps, ProgressTone } from './ProgressBar';

export { DataList } from './DataList';
export type { DataListProps, DataListColumn, DataListMobileRole } from './DataList';

export { ActionButton } from './ActionButton';
export type { ActionButtonProps } from './ActionButton';
export { BulkActionBar } from './BulkActionBar';
export type { BulkActionBarProps, BulkSelectToggleProps } from './BulkActionBar';

export { FilterBar } from './FilterBar';
export type { FilterBarProps } from './FilterBar';

export { Breadcrumbs } from './Breadcrumbs';
export type { BreadcrumbsProps, Crumb } from './Breadcrumbs';

export { ResourceContainer } from './ResourceContainer';
export type { ResourceContainerProps } from './ResourceContainer';

export { ResourceSearchFilter, ResourceCounter } from './ResourceSearchFilter';
export type {
  ResourceSearchFilterProps,
  ResourceCounterProps,
  ResourceFilterSelect,
  ResourceFilterSelectOption,
  ResourceTabOption,
} from './ResourceSearchFilter';

export { ResourceEntryCard } from './ResourceEntryCard';
export type { ResourceEntryCardProps, ResourceMenuAction } from './ResourceEntryCard';

export { ResourceDetailHeader } from './ResourceDetailHeader';
export type { ResourceDetailHeaderProps } from './ResourceDetailHeader';

export { ResourceSectionCard } from './ResourceSectionCard';
export type { ResourceSectionCardProps } from './ResourceSectionCard';

