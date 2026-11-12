import { describe, expect, it } from 'vitest';
import {
  CENTER_MIN, SIDEBAR_COLLAPSED, SIDEBAR_DEFAULT,
  SIDEBAR_MAX, SIDEBAR_MIN, clampWidth, computeColumns,
} from '../src/layout/columns';

describe('clampWidth', () => {
  it('clamps into range and rounds', () => {
    expect(clampWidth(100, SIDEBAR_MIN, SIDEBAR_MAX)).toBe(SIDEBAR_MIN);
    expect(clampWidth(999, SIDEBAR_MIN, SIDEBAR_MAX)).toBe(SIDEBAR_MAX);
    expect(clampWidth(300.6, SIDEBAR_MIN, SIDEBAR_MAX)).toBe(301);
  });
});

describe('computeColumns', () => {
  it('keeps the centre at least CENTER_MIN wide without a right track', () => {
    const cols = computeColumns(1440, SIDEBAR_DEFAULT, 0);
    expect(cols.sidebar).toBe(SIDEBAR_DEFAULT);
    expect(cols.rightbar).toBe(0);
    expect(cols.center).toBe(1440 - SIDEBAR_DEFAULT);
    expect(cols.center).toBeGreaterThanOrEqual(CENTER_MIN);
  });

  it('collapses to the rail when the sidebar preference is 0', () => {
    const cols = computeColumns(1440, 0, 0);
    expect(cols.sidebar).toBe(SIDEBAR_COLLAPSED);
    expect(cols.center).toBe(1440 - SIDEBAR_COLLAPSED);
  });

  it('drops the right track before squeezing the centre below its minimum', () => {
    // 900 wide: sidebar 280 + centre 400 leaves 220 < RIGHTBAR_MIN
    const cols = computeColumns(900, SIDEBAR_DEFAULT, 400);
    expect(cols.rightbar).toBe(0);
    expect(cols.center).toBe(900 - SIDEBAR_DEFAULT);
  });

  it('opens the right column when there is room', () => {
    const cols = computeColumns(1600, SIDEBAR_DEFAULT, 500);
    expect(cols.rightbar).toBe(500);
    expect(cols.center).toBe(1600 - SIDEBAR_DEFAULT - 500);
    expect(cols.center).toBeGreaterThanOrEqual(CENTER_MIN);
  });

  it('clamps the right panel to its ratio ceiling', () => {
    const cols = computeColumns(1600, SIDEBAR_DEFAULT, 2000);
    // the ratio ceiling is 1120, but the centre keeps its 400px minimum:
    // 1600 - 280 - 400 = 920
    expect(cols.rightbar).toBe(920);
    expect(cols.center).toBe(CENTER_MIN);
  });

  it('never returns negative centre widths', () => {
    const cols = computeColumns(200, SIDEBAR_DEFAULT, 0);
    expect(cols.center).toBeGreaterThanOrEqual(0);
  });
});
