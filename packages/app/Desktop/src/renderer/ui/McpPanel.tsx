// MCP 与工具面板（集成与连接 → MCP 与工具）——形态对齐 Reasonix MCP 页：
//   顶部：4 张状态卡（已连接 / 异常 / 工具 / 不可用）
//   工具栏：搜索框 + 浏览市场 + 添加服务器
//   列表：全局 MCP 分组（服务器条目）
// 接线状态：trha Port 尚无 MCP 数据源 —— 计数/列表为预留（plannedInterface: port.mcpServers()），
//           操作按钮（浏览市场/添加服务器）为预留入口；空态诚实标注。

import { useState } from 'react';

export interface McpPanelProps {
  t: (key: string) => string;
}

// 预留：Port 未来提供的 MCP 数据形状（Reasonix mcpServers：已连接/异常/工具数/不可用）。
export interface McpServerInfo {
  name: string;
  status: 'connected' | 'error' | 'unavailable';
  toolCount: number;
  global: boolean;
}

export function McpPanel({ t }: McpPanelProps) {
  const [query, setQuery] = useState('');
  // 预留数据源：const servers = await port.mcpServers()（Port 接口待加）
  const servers: McpServerInfo[] = [];   // trha 尚无 MCP 数据，诚实空态
  const counts = {
    connected: servers.filter(s => s.status === 'connected').length,
    error: servers.filter(s => s.status === 'error').length,
    tools: servers.reduce((a, s) => a + s.toolCount, 0),
    unavailable: servers.filter(s => s.status === 'unavailable').length,
  };
  const globalServers = servers.filter(s => s.global);

  return (
    <div className="settings-pagebody">
      {/* 状态卡 */}
      <div className="mcp-stats">
        <div className="mcp-stat"><strong>{counts.connected}</strong><span>{t('settings.mcp.connected')}</span></div>
        <div className="mcp-stat"><strong>{counts.error}</strong><span>{t('settings.mcp.error')}</span></div>
        <div className="mcp-stat"><strong>{counts.tools}</strong><span>{t('settings.mcp.tools')}</span></div>
        <div className="mcp-stat"><strong>{counts.unavailable}</strong><span>{t('settings.mcp.unavailable')}</span></div>
      </div>

      {/* 工具栏 */}
      <div className="mcp-toolbar">
        <input
          type="search"
          className="mcp-search"
          placeholder={t('settings.mcp.searchPlaceholder')}
          value={query}
          onChange={e => setQuery(e.target.value)}
          aria-label={t('settings.mcp.searchPlaceholder')}
        />
        <button type="button" className="btn btn--primary" disabled title={t('settings.mcp.marketPlanned')}>
          {t('settings.mcp.browseMarket')}
        </button>
        <button type="button" className="btn" disabled title={t('settings.mcp.addPlanned')}>
          {t('settings.mcp.addServer')}
        </button>
      </div>

      {/* 全局 MCP 分组 */}
      <section className="settings-block">
        <h4 className="settings-block-title">
          {t('settings.mcp.globalTitle')} <span className="mcp-count">{globalServers.length}</span>
        </h4>
        <p className="settings-page-desc">{t('settings.mcp.globalDesc')}</p>

        {globalServers.length === 0 ? (
          <div className="mcp-empty">
            <p>{t('settings.mcp.empty')}</p>
            <code>{t('settings.mcp.plannedInterface')}</code>
          </div>
        ) : (
          <div className="mcp-list">
            {globalServers.map(s => (
              <div key={s.name} className="mcp-server">
                <strong>{s.name}</strong>
                <span className={`mcp-status mcp-status--${s.status}`}>{s.status}</span>
                <span>{s.toolCount} tools</span>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

export default McpPanel;