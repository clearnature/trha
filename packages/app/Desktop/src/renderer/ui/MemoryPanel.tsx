// 记忆面板（记忆与上下文 → 记忆）——形态对齐 Reasonix Memory 页：
//   顶部统计：N 条背景记忆 · N 条归档 · N 个指令文件 · 当前工作区
//   侧栏存储位置：背景记忆 / 归档的记忆 / 指令文件 / 召回记录（+ 候选建议入口）
//   列表区：记忆类型标题 + 说明 + 搜索框 + 分类筛选（全部/反馈/项目背景/用户偏好）
// 接线状态：trha 无记忆系统 —— 统计/列表/筛选均为预留（port.memories()）。

import { useState } from 'react';

export interface MemoryPanelProps {
  t: (key: string) => string;
}

export interface MemoryStats { background: number; archived: number; instructionFiles: number; }
export interface MemoryItem {
  title: string;
  slug: string;
  category: 'feedback' | 'project' | 'preferences';
  excerpt: string;
}

type StorageTab = 'background' | 'archived' | 'files' | 'recall';
type CategoryTab = 'all' | 'feedback' | 'project' | 'preferences';

export function MemoryPanel({ t }: MemoryPanelProps) {
  const [storage, setStorage] = useState<StorageTab>('background');
  const [category, setCategory] = useState<CategoryTab>('all');
  const [query, setQuery] = useState('');
  // 预留数据源：const { stats, items } = await port.memories()（Port 接口待加）
  const stats: MemoryStats = { background: 0, archived: 0, instructionFiles: 0 };
  const items: MemoryItem[] = [];

  const categoryLabels: { id: CategoryTab; key: string }[] = [
    { id: 'all', key: 'settings.memory.catAll' },
    { id: 'feedback', key: 'settings.memory.catFeedback' },
    { id: 'project', key: 'settings.memory.catProject' },
    { id: 'preferences', key: 'settings.memory.catPreferences' },
  ];

  const storageTabs: { id: StorageTab; key: string }[] = [
    { id: 'background', key: 'settings.memory.background' },
    { id: 'archived', key: 'settings.memory.archived' },
    { id: 'files', key: 'settings.memory.files' },
    { id: 'recall', key: 'settings.memory.recall' },
  ];

  return (
    <div className="settings-pagebody">
      {/* 顶部统计 */}
      <div className="mcp-stats">
        <div className="mcp-stat"><strong>{stats.background}</strong><span>{t('settings.memory.background')}</span></div>
        <div className="mcp-stat"><strong>{stats.archived}</strong><span>{t('settings.memory.archived')}</span></div>
        <div className="mcp-stat"><strong>{stats.instructionFiles}</strong><span>{t('settings.memory.instructionFiles')}</span></div>
        <div className="mcp-stat"><strong>{t('settings.memory.currentWorkspace')}</strong><span>{t('settings.memory.workspace')}</span></div>
      </div>

      <div className="memory-layout">
        {/* 侧栏：存储位置 */}
        <nav className="memory-nav" aria-label={t('settings.memory.storageLocation')}>
          <div className="settings-navgroup-label">{t('settings.memory.storageLocation')}</div>
          {storageTabs.map(s => (
            <button key={s.id} type="button"
              className={`settings-navtab ${storage === s.id ? 'active' : ''}`}
              onClick={() => setStorage(s.id)}>
              {t(s.key)}
            </button>
          ))}
          <button type="button" className="settings-navtab memory-recall-suggest" title={t('settings.memory.suggestPlanned')}>
            {t('settings.memory.suggestions')}
          </button>
        </nav>

        {/* 列表区 */}
        <div className="memory-content">
          <h4 className="settings-block-title">{t(`settings.memory.listTitle.${storage}`)}</h4>
          <p className="settings-page-desc">{t('settings.memory.verifyHint')}</p>

          <div className="mcp-toolbar">
            <input
              type="search"
              className="mcp-search"
              placeholder={t('settings.memory.searchPlaceholder')}
              value={query}
              onChange={e => setQuery(e.target.value)}
              aria-label={t('settings.memory.searchPlaceholder')}
            />
          </div>

          <div className="memory-categories">
            {categoryLabels.map(c => (
              <button key={c.id} type="button"
                className={`memory-cat ${category === c.id ? 'active' : ''}`}
                onClick={() => setCategory(c.id)}>
                {t(c.key)}
              </button>
            ))}
          </div>

          {items.length === 0 ? (
            <div className="mcp-empty">
              <p>{t('settings.memory.empty')}</p>
              <code>{t('settings.memory.planned')}</code>
            </div>
          ) : (
            <div className="memory-list">
              {items.map(m => (
                <div key={m.slug} className="memory-item">
                  <strong>{m.title}</strong>
                  <code>{m.slug}</code>
                  <p>{m.excerpt}</p>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

export default MemoryPanel;