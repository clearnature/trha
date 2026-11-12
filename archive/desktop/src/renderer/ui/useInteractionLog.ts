// 前端交互记录 hook：开关开启时记录时间/事件/几何信息（隐私安全——
// 不记录对话内容、输入值、路径或密钥），供诊断导出。纯前端实现。

import { useEffect, useRef, useState } from 'react';

export interface InteractionEvent {
  time: number;        // 相对启动的毫秒
  type: string;        // keydown | click | scroll | resize | visibility
  target: string;      // 元素 tag/class（不含内容）
  geometry: string;    // 视口/元素几何摘要
}

/** 抽象元素身份（tag + class 前 40 字符，不含 value/text/路径）。 */
function elementDesc(el: EventTarget | null): string {
  if (!(el instanceof Element)) return 'window';
  const cls = (el.className && typeof el.className === 'string')
    ? el.className.split(' ').slice(0, 2).join('.') : '';
  return `${el.tagName.toLowerCase()}${cls ? '.' + cls : ''}`.slice(0, 60);
}

export function useInteractionLog(enabled: boolean): { events: InteractionEvent[] } {
  const [events, setEvents] = useState<InteractionEvent[]>([]);
  const startRef = useRef(Date.now());
  const enabledRef = useRef(enabled);
  enabledRef.current = enabled;

  useEffect(() => {
    if (!enabled) { setEvents([]); return; }
    startRef.current = Date.now();
    setEvents([]);
    const record = (type: string, target: EventTarget | null) => {
      const t = Date.now() - startRef.current;
      let geometry = '';
      try {
        geometry = `${innerWidth}x${innerHeight},scroll=${scrollY}`;
      } catch { geometry = ''; }
      const ev: InteractionEvent = { time: t, type, target: elementDesc(target), geometry };
      setEvents(prev => prev.length >= 2000 ? prev : [...prev, ev]);
    };
    const onKey = (e: KeyboardEvent) => record('keydown', e.target);
    const onClick = (e: MouseEvent) => record('click', e.target);
    const onScroll = () => record('scroll', null);
    const onResize = () => record('resize', null);
    const onVis = () => record('visibilitychange', null);
    window.addEventListener('keydown', onKey);
    window.addEventListener('click', onClick);
    window.addEventListener('scroll', onScroll, true);
    window.addEventListener('resize', onResize);
    document.addEventListener('visibilitychange', onVis);
    return () => {
      window.removeEventListener('keydown', onKey);
      window.removeEventListener('click', onClick);
      window.removeEventListener('scroll', onScroll, true);
      window.removeEventListener('resize', onResize);
      document.removeEventListener('visibilitychange', onVis);
    };
  }, [enabled]);

  return { events };
}