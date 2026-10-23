// 用量统计面板（模型 → 用量统计）——形态对齐 Reasonix UsageStatsPanel：
//   时间范围预设（7/14/30/90 天或自定义）+ 来源 + 统计展示。
// 接线状态：范围选择本地可用；统计来自内核 App.UsageStats（预留 port.usageStats()）。

import { useEffect, useState } from 'react';
import { useSessionStore } from './SessionContext.js';

export interface ModelStatsPanelProps {
  t: (key: string) => string;
}

export function ModelStatsPanel({ t }: ModelStatsPanelProps) {
  const [range, setRange] = useState('30');
  const [source, setSource] = useState('all');
  // 真实数据源：scheduler 聚合 sessions（按 mode 统计请求/messages/约 tokens）
  const store = useSessionStore();
  const [rows, setRows] = useState<{ model: string; tokens: number; requests: number; cost: string }[]>([]);
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    void store.getState().port.usageStats().then(r => {
      setRows(r.map(x => ({ model: x.model, tokens: x.tokens, requests: x.requests, cost: x.cost })));
      setLoaded(true);
    }).catch(() => { setLoaded(true); });
  }, [store]);

  return (
    <div className="settings-pagebody">
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.stats.title')}</h4>
        <div className="mcp-toolbar">
          <select value={range} onChange={e => setRange(e.target.value)} aria-label={t('settings.stats.range')}>
            <option value="7">{t('settings.stats.range7')}</option>
            <option value="14">{t('settings.stats.range14')}</option>
            <option value="30">{t('settings.stats.range30')}</option>
            <option value="90">{t('settings.stats.range90')}</option>
          </select>
          <select value={source} onChange={e => setSource(e.target.value)} aria-label={t('settings.stats.source')}>
            <option value="all">{t('settings.stats.allSources')}</option>
          </select>
        </div>

        {loaded && rows.length === 0 ? (
          <div className="mcp-empty">
            <p>{t('settings.stats.empty')}</p>
            <code>{t('settings.stats.live')}</code>
          </div>
        ) : !loaded ? (
          <p className="param-hint">{t('settings.stats.loading')}</p>
        ) : (
          <table className="stats-table">
            <thead><tr><th>{t('settings.stats.model')}</th><th>{t('settings.stats.tokens')}</th>
              <th>{t('settings.stats.requests')}</th><th>{t('settings.stats.cost')}</th></tr></thead>
            <tbody>{rows.map(r => (
              <tr key={r.model}><td>{r.model}</td><td>{r.tokens}</td><td>{r.requests}</td><td>{r.cost}</td></tr>
            ))}</tbody>
          </table>
        )}
      </section>
    </div>
  );
}

export default ModelStatsPanel;