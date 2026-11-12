// 远程 SSH 面板（集成与连接 → 远程 SSH）——形态对齐 Reasonix RemotePanel：
//   主机列表 + 连接状态 + 端口转发 tab。
// 接线状态：本地可编辑主机；连接/文件浏览经内核远端（预留 port.remote()）。

import { useState } from 'react';

export interface RemotePanelProps {
  t: (key: string) => string;
}

interface RemoteHost { id: string; label: string; address: string; connected: boolean; }

export function RemotePanel({ t }: RemotePanelProps) {
  const [hosts, setHosts] = useState<RemoteHost[]>([]);
  const [newHost, setNewHost] = useState('');
  const [newAddr, setNewAddr] = useState('');
  const [tab, setTab] = useState<'files' | 'ports'>('files');
  // 预留：端口转发列表（port.remotePorts()）

  const addHost = () => {
    const label = newHost.trim();
    if (!label) return;
    setHosts([...hosts, { id: label, label, address: newAddr.trim(), connected: false }]);
    setNewHost(''); setNewAddr('');
  };

  return (
    <div className="settings-pagebody">
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.remote.title')}</h4>

        <div className="mcp-toolbar">
          <input type="text" className="mcp-search" placeholder={t('settings.remote.host')}
            value={newHost} onChange={e => setNewHost(e.target.value)} />
          <input type="text" className="mcp-search" placeholder={t('settings.remote.address')}
            value={newAddr} onChange={e => setNewAddr(e.target.value)} />
          <button type="button" className="btn btn--primary" onClick={addHost}>{t('settings.remote.add')}</button>
        </div>

        {hosts.length === 0 ? (
          <div className="mcp-empty">
            <p>{t('settings.remote.empty')}</p>
            <code>{t('settings.remote.planned')}</code>
          </div>
        ) : (
          <div className="net-modes">
            {hosts.map(h => (
              <div key={h.id} className={`compact-preset ${h.connected ? 'active' : ''}`}>
                <strong>{h.label}</strong>
                <span>{h.address} · {h.connected ? t('settings.remote.connected') : t('settings.remote.offline')}</span>
              </div>
            ))}
          </div>
        )}

        <div className="memory-categories" style={{ marginTop: 14 }}>
          <button type="button" className={`memory-cat ${tab === 'files' ? 'active' : ''}`} onClick={() => setTab('files')}>
            {t('settings.remote.files')}
          </button>
          <button type="button" className={`memory-cat ${tab === 'ports' ? 'active' : ''}`} onClick={() => setTab('ports')}>
            {t('settings.remote.ports')}
          </button>
        </div>
        {tab === 'ports' && (
          <div className="mcp-empty" style={{ marginTop: 8 }}>
            <p>{t('settings.remote.portsEmpty')}</p>
            <code>{t('settings.remote.planned')}</code>
          </div>
        )}
      </section>
    </div>
  );
}

export default RemotePanel;