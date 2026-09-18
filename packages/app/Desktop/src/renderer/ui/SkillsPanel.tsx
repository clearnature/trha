// Agent Skills 面板（能力扩展 → Agent Skills）——形态对齐 Reasonix Skills 页：
//   顶部开关：允许 Agent 自动调用技能（关闭后仍可通过 /skill 使用，但 Agent
//            看不到技能索引和专用工具）——预留（skills.autoInvoke 待接）
//   来源统计：有效 / 缺失 / 空目录 / 已停用
//   技能计数：可用 / 项目 / 自定义 / 全局 / 内置
// 接线状态：trha 尚无技能系统 —— 开关与统计均为预留（plannedInterface 标注）。

import { useState } from 'react';

export interface SkillsPanelProps {
  t: (key: string) => string;
}

// 预留：Port 未来提供的技能统计（Reasonix 语义）。
export interface SkillsSourceStats { valid: number; missing: number; emptyDir: number; disabled: number; }
export interface SkillsCounts { available: number; project: number; custom: number; global: number; builtin: number; }

export function SkillsPanel({ t }: SkillsPanelProps) {
  const [autoInvoke, setAutoInvoke] = useState(true);
  // 预留数据源：const stats = await port.skillsStats()（Port 接口待加）
  const src: SkillsSourceStats = { valid: 0, missing: 0, emptyDir: 0, disabled: 0 };
  const counts: SkillsCounts = { available: 0, project: 0, custom: 0, global: 0, builtin: 0 };

  return (
    <div className="settings-pagebody">
      {/* 自动调用开关 */}
      <section className="settings-block">
        <div className="setting-group setting-row">
          <div className="setting-row-text">
            <label htmlFor="skills-auto">{t('settings.skills.autoInvoke')}</label>
            <span className="param-hint">{t('settings.skills.autoInvokeHint')}</span>
          </div>
          <input
            id="skills-auto"
            type="checkbox"
            checked={autoInvoke}
            onChange={e => setAutoInvoke(e.target.checked)}
            disabled
            title={t('settings.skills.planned')}
          />
        </div>
        <span className="param-hint"><code>skills.autoInvoke</code>（预留，未接线）</span>
      </section>

      {/* 来源统计 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.skills.sourceTitle')}</h4>
        <div className="mcp-stats">
          <div className="mcp-stat"><strong>{src.valid}</strong><span>{t('settings.skills.valid')}</span></div>
          <div className="mcp-stat"><strong>{src.missing}</strong><span>{t('settings.skills.missing')}</span></div>
          <div className="mcp-stat"><strong>{src.emptyDir}</strong><span>{t('settings.skills.emptyDir')}</span></div>
          <div className="mcp-stat"><strong>{src.disabled}</strong><span>{t('settings.skills.disabled')}</span></div>
        </div>
        <span className="param-hint"><code>port.skillsStats()</code>（预留）</span>
      </section>

      {/* 技能计数 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.skills.countTitle')}</h4>
        <div className="skill-counts">
          <div className="skill-count"><strong>{counts.available}</strong><span>{t('settings.skills.available')}</span></div>
          <div className="skill-count"><strong>{counts.project}</strong><span>{t('settings.skills.project')}</span></div>
          <div className="skill-count"><strong>{counts.custom}</strong><span>{t('settings.skills.custom')}</span></div>
          <div className="skill-count"><strong>{counts.global}</strong><span>{t('settings.skills.global')}</span></div>
          <div className="skill-count"><strong>{counts.builtin}</strong><span>{t('settings.skills.builtin')}</span></div>
        </div>
        <span className="param-hint"><code>port.skillsStats()</code>（预留）</span>
      </section>
    </div>
  );
}

export default SkillsPanel;