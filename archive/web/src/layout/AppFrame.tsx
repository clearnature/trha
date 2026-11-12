// Three-column shell frame, ported in spirit from deepseek-harness
// (packages/client/ui-layout): the frame owns the grid tracks and the drag
// handle; column occupants only report the width they want.
//
// The right column is part of the grid contract but unused in P1 — P3 fills
// it with the file/preview panel.
//
// Collapse is expressed as width 0: the grid then shows the 56px icon rail
// (SIDEBAR_COLLAPSED), which is what the reference shell does.

import React, { useCallback, useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import {
  SIDEBAR_COLLAPSED, SIDEBAR_MAX, SIDEBAR_MIN,
  clampWidth, computeColumns,
} from './columns';
import css from './AppFrame.module.css';

export interface AppFrameProps {
  sidebar: ReactNode;
  main: ReactNode;
  rightbar?: ReactNode;
  /** Sidebar width preference in px; 0 = collapsed to the rail. */
  sidebarWidth: number;
  onSidebarWidthChange: (width: number) => void;
  /** Right column width in px; 0 = no track (the column is not rendered). */
  rightbarWidth?: number;
}

function useViewportWidth(): number {
  const [width, setWidth] = useState(() =>
    typeof window === 'undefined' ? 1440 : window.innerWidth);
  useEffect(() => {
    const onResize = () => setWidth(window.innerWidth);
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);
  return width;
}

/** One drag handle between the sidebar and the centre column. */
function SidebarHandle(props: {
  onDrag: (dx: number) => void;
  onStart: () => void;
}) {
  const [dragging, setDragging] = useState(false);
  const origin = useRef(0);
  const frame = useRef<number | null>(null);
  const latest = useRef(0);
  const callbacks = useRef(props);
  callbacks.current = props;

  const endDrag = useCallback(() => {
    if (frame.current !== null) {
      cancelAnimationFrame(frame.current);
      frame.current = null;
    }
    setDragging(false);
  }, []);

  useEffect(() => endDrag, [endDrag]);

  const onPointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    if (e.button !== 0) return;
    e.preventDefault();
    origin.current = e.clientX;
    latest.current = e.clientX;
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
    setDragging(true);
    callbacks.current.onStart();
  };

  const onPointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!dragging) return;
    latest.current = e.clientX;
    if (frame.current !== null) return;
    frame.current = requestAnimationFrame(() => {
      frame.current = null;
      callbacks.current.onDrag(latest.current - origin.current);
    });
  };

  return (
    <div
      className={css.handle}
      data-dragging={dragging || undefined}
      role="separator"
      aria-orientation="vertical"
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={endDrag}
      onPointerCancel={endDrag}
    />
  );
}

export function AppFrame(props: AppFrameProps) {
  const viewport = useViewportWidth();
  const rightbarWidth = props.rightbarWidth ?? 0;
  const cols = computeColumns(viewport, props.sidebarWidth, rightbarWidth, SIDEBAR_COLLAPSED);
  const dragBase = useRef(0);

  const onDrag = (dx: number) => {
    props.onSidebarWidthChange(clampWidth(dragBase.current + dx, SIDEBAR_MIN, SIDEBAR_MAX));
  };

  return (
    <div
      className={css.frame}
      data-collapsed={props.sidebarWidth === 0 ? '' : undefined}
      style={{
        gridTemplateColumns: cols.rightbar > 0
          ? `${cols.sidebar}px minmax(0, 1fr) ${cols.rightbar}px`
          : `${cols.sidebar}px minmax(0, 1fr)`,
      }}
    >
      <div className={css.sidebarCol} data-sidebar-col>
        {props.sidebar}
      </div>
      <div className={css.centerCol}>{props.main}</div>
      {cols.rightbar > 0 && (
        <div className={css.rightbarCol} data-rightbar-col>{props.rightbar}</div>
      )}
      {props.sidebarWidth > 0 && (
        <SidebarHandle
          onStart={() => { dragBase.current = props.sidebarWidth; }}
          onDrag={onDrag}
        />
      )}
    </div>
  );
}
