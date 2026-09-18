// 存储与路径面板（应用 → 存储与路径）——形态对齐 Reasonix Storage 页：
//   数据位置：默认工作区 / 会话与记忆数据 / 缓存 / 扩展 四条路径展示。
// 接线状态：路径为静态展示（trha 数据位置语义，随内核配置变化 —— 预留 port.paths()）。

import { useState } from 'react';

export interface StoragePanelProps {
  t: (key: string) => string;
}

interface DataPath { id: string; labelKey: string; path: string; hintKey?: string; }

// 预留：真实路径来自 port.paths()（随内核配置变化）。
const DEFAULT_PATHS: DataPath[] = [
  { id: 'workspace', labelKey: 'settings.storage.workspaceLabel', path: '/home/yanli/work/trha', hintKey: 'settings.storage.workspaceHint' },
  { id: 'session', labelKey: 'settings.storage.sessionLabel', path: '/home/yanli/.trha', hintKey: 'settings.storage.sessionHint' },
  { id: 'cache', labelKey: 'settings.storage.cacheLabel', path: '/home/yanli/.cache/trha', hintKey: 'settings.storage.cacheHint' },
  { id: 'plugins', labelKey: 'settings.storage.pluginsLabel', path: '/home/yanli/.trha/plugins', hintKey: 'settings.storage.pluginsHint' },
];

export function StoragePanel({ t }: StoragePanelProps) {
  const [copied, setCopied] = useState<string | null>(null);

  const copyPath = async (path: string) => {
    try {
      await navigator.clipboard.writeText(path);
      setCopied(path);
      setTimeout(() => setCopied(null), 1500);
    } catch { /* noop */ }
  };

  return (
    <div className="settings-pagebody">
      <p className="settings-page-desc">{t('settings.storage.desc')}</p>

      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.storage.dataLocation')}</h4>
        <div className="storage-paths">
          {DEFAULT_PATHS.map(p => (
            <div key={p.id} className="storage-path">
              <div className="storage-path-text">
                <strong>{t(p.labelKey)}</strong>
                <span className="param-hint">{p.hintKey ? t(p.hintKey) : ''}</span>
                <code className="hooks-path">{p.path}</code>
              </div>
              <button type="button" className="btn btn--small" onClick={() => void copyPath(p.path)}>
                {copied === p.path ? t('settings.hooks.copied') : t('settings.hooks.copyPath')}
              </button>
            </div>
          ))}
        </div>
        <span className="param-hint"><code>port.paths()</code>（路径随内核配置变化，预留）</span>
      </section>
    </div>
  );
}

export default StoragePanel;