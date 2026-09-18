// 网络面板（安全与控制 → 网络）——形态对齐 Reasonix NetworkSection：
//   代理模式：auto / system / custom（custom 展开类型/地址/认证）
// 接线状态：本地可编辑；持久化经内核 network 配置（预留）。

import { useState } from 'react';

export interface NetworkPanelProps {
  t: (key: string) => string;
}

export function NetworkPanel({ t }: NetworkPanelProps) {
  const [proxyMode, setProxyMode] = useState<'auto' | 'system' | 'custom'>('auto');
  const [proxyType, setProxyType] = useState<'socks5' | 'http'>('socks5');
  const [proxyUrl, setProxyUrl] = useState('');
  const [port, setPort] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');

  return (
    <div className="settings-pagebody">
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.network.title')}</h4>

        <div className="setting-group">
          <label>{t('settings.network.proxyMode')}</label>
          <div className="net-modes">
            {(['auto', 'system', 'custom'] as const).map(m => (
              <button key={m} type="button"
                className={`compact-preset ${proxyMode === m ? 'active' : ''}`}
                onClick={() => setProxyMode(m)}>
                {t(`settings.network.mode.${m}`)}
              </button>
            ))}
          </div>
        </div>

        {proxyMode === 'custom' && (
          <div className="net-custom">
            <div className="setting-group">
              <label>{t('settings.network.proxyType')}</label>
              <select value={proxyType} onChange={e => setProxyType(e.target.value as 'socks5' | 'http')}>
                <option value="socks5">SOCKS5</option>
                <option value="http">HTTP</option>
              </select>
            </div>
            <div className="setting-group">
              <label>{t('settings.network.proxyUrl')}</label>
              <input type="text" className="hooks-editor" value={proxyUrl}
                placeholder="127.0.0.1" onChange={e => setProxyUrl(e.target.value)} />
            </div>
            <div className="setting-group">
              <label>{t('settings.network.port')}</label>
              <input type="number" className="hooks-editor" value={port}
                placeholder="7890" onChange={e => setPort(e.target.value)} />
            </div>
            <div className="setting-group">
              <label>{t('settings.network.username')}</label>
              <input type="text" className="hooks-editor" value={username}
                onChange={e => setUsername(e.target.value)} />
            </div>
            <div className="setting-group">
              <label>{t('settings.network.password')}</label>
              <input type="password" className="hooks-editor" value={password}
                onChange={e => setPassword(e.target.value)} />
            </div>
          </div>
        )}
        <span className="param-hint"><code>network.proxyMode / proxy</code>（持久化预留，未接线）</span>
      </section>
    </div>
  );
}

export default NetworkPanel;