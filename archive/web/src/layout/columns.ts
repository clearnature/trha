// Column geometry for the web shell, ported from deepseek-harness
// (packages/client/ui-layout/src/client/columns.ts, used under its license).
//
// Kept as pure functions so the layout contract is unit-testable without a
// browser: the sidebar clamps into its range, the right column gives up its
// track before the centre drops below its minimum.

/** Resolved widths for one frame (px). */
export interface Columns {
  sidebar: number;
  center: number;
  rightbar: number;
}

/** Centre width protected while a normal right column is open. */
export const CENTER_MIN = 400;

/** Sidebar drag clamp floor. */
export const SIDEBAR_MIN = 264;

/** Sidebar drag clamp ceiling. */
export const SIDEBAR_MAX = 420;

/** Sidebar width before the user drags it. */
export const SIDEBAR_DEFAULT = 280;

/** Closed-sidebar rail: a 24px icon column between 16px paddings. */
export const SIDEBAR_COLLAPSED = 56;

/** Viewport width below which the sidebar auto-collapses to the rail. */
export const SIDEBAR_AUTO_COLLAPSE = 1024;

/** Right column drag clamp floor. */
export const RIGHTBAR_MIN = 300;

/** Maximum normal right panel width as a fraction of the frame. */
export const RIGHTBAR_MAX_RATIO = 0.7;

/** First-open right panel preference as a fraction of the frame. */
export const RIGHTBAR_DEFAULT_RATIO = 0.45;

/** Clamp a panel width into its contract range. */
export function clampWidth(px: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, Math.round(px)));
}

/**
 * Solve the three column widths for one viewport frame.
 *
 * @param viewport frame width in px
 * @param sidebar sidebar preference in px (0 = collapsed to the rail)
 * @param rightbar requested right panel width in px (0 = no track)
 * @param collapsedWidth track width of a collapsed sidebar
 */
export function computeColumns(
  viewport: number,
  sidebar: number,
  rightbar: number,
  collapsedWidth: number = SIDEBAR_COLLAPSED,
): Columns {
  const s = sidebar === 0 ? collapsedWidth : clampWidth(sidebar, SIDEBAR_MIN, SIDEBAR_MAX);
  const available = viewport - s - CENTER_MIN;
  const r = rightbar === 0 || available < RIGHTBAR_MIN
    ? 0
    : Math.min(available, clampWidth(rightbar, RIGHTBAR_MIN, viewport * RIGHTBAR_MAX_RATIO));
  return { sidebar: s, center: Math.max(0, viewport - s - r), rightbar: r };
}
