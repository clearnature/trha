// 机器人面板（集成与连接 → 机器人）——形态对齐 Reasonix Bots（botConnectionSettings）：
//   接入目标：QQ / 飞书 / Lark / 微信 / 钉钉；每个目标状态 + 配置。
// 接线状态：目标选择本地；连接诊断/配置经内核预留（port.bots()）。

import { useState } from 'react';

export interface BotsPanelProps {
  t: (key: string) => string;
}

const BOT_TARGETS = ['qq', 'feishu', 'lark', 'weixin', 'dingtalk'] as const;
type BotTarget = (typeof BOT_TARGETS)[number];

export function BotsPanel({ t }: BotsPanelProps) {
  const [target, setTarget] = useState<BotTarget>('qq');

  return (
    <div className="settings-pagebody">
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.bots.title')}</h4>
        <p className="settings-page-desc">{t('settings.bots.desc')}</p>

        <div className="net-modes">
          {BOT_TARGETS.map(b => (
            <button key={b} type="button"
              className={`compact-preset ${target === b ? 'active' : ''}`}
              onClick={() => setTarget(b)}>
              {t(`settings.bots.target.${b}`)}
            </button>
          ))}
        </div>

        <div className="mcp-empty" style={{ marginTop: 12 }}>
          <p>{t('settings.bots.notConnected', { target: t(`settings.bots.target.${target}`) })}</p>
          <code>{t('settings.bots.planned')}</code>
        </div>
      </section>
    </div>
  );
}

export default BotsPanel;