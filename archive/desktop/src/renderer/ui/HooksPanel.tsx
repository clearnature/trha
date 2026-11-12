// Hooks 面板（自动化与开发者 → Hooks）——形态对齐 Reasonix Hooks 页：
//   配置范围：全局 / 项目（选择）· 说明「Hooks 会执行 shell 命令，从各自配置位置自动加载」
//   设置文件：当前范围保存到的配置文件路径 + 复制路径
//   JSON 配置：textarea 编辑 + 复制 JSON / 粘贴 JSON / 格式化 JSON + 未保存状态
// 接线状态：JSON 编辑/格式化本地可用；保存/加载到配置文件属预留（port.hooksConfig()）。

import { useEffect, useState } from 'react';
import { useSessionStore } from './SessionContext.js';

export interface HooksPanelProps {
  t: (key: string) => string;
}

// 预留：拉取当前 hooks JSON（port.hooksConfig() —— load/save 待接）
const DEFAULT_HOOKS_JSON = '{\n  "hooks": {}\n}';
const GLOBAL_HOOKS_PATH = '/home/yanli/.reasonix/settings.json';

export function HooksPanel({ t }: HooksPanelProps) {
  const [scope, setScope] = useState<'global' | 'project'>('global');
  const [json, setJson] = useState(DEFAULT_HOOKS_JSON);
  const [dirty, setDirty] = useState(false);
  const [copied, setCopied] = useState<'' | 'path' | 'json'>('');
  const [saved, setSaved] = useState(false);
  const store = useSessionStore();

  // 加载现有 hooks 配置（重启加载语义；scheduler 落盘 ~/.trha/hooks.json）
  useEffect(() => {
    void store.getState().port.hooksConfig().then(r => {
      if (r.config) setJson(r.config);
    }).catch(() => { /* 无文件用默认 */ });
  }, [store]);

  // 保存 hooks 配置（校验 + 落盘）
  const save = async () => {
    try {
      JSON.parse(json);   // 校验
      const r = await store.getState().port.saveHooksConfig(json);
      setJson(r.config); setDirty(false); setSaved(true);
      setTimeout(() => setSaved(false), 1500);
    } catch { /* 非法 JSON，不保存 */ }
  };

  const formatJson = () => {
    try {
      setJson(JSON.stringify(JSON.parse(json), null, 2));
      setDirty(true);
    } catch { /* keep as-is; invalid JSON */ }
  };

  const copy = async (what: 'path' | 'json') => {
    try {
      await navigator.clipboard.writeText(what === 'path' ? GLOBAL_HOOKS_PATH : json);
      setCopied(what);
      setTimeout(() => setCopied(''), 1500);
    } catch { /* noop */ }
  };

  const pasteFromClipboard = async () => {
    try {
      const text = await navigator.clipboard.readText();
      if (text) { setJson(text); setDirty(true); }
    } catch { /* noop */ }
  };

  return (
    <div className="settings-pagebody">
      {/* 说明 */}
      <p className="settings-page-desc">{t('settings.hooks.desc')}</p>

      {/* 配置范围 */}
      <div className="setting-group">
        <label>{t('settings.hooks.scope')}</label>
        <select value={scope} onChange={e => setScope(e.target.value as 'global' | 'project')}>
          <option value="global">{t('settings.hooks.global')}</option>
          <option value="project">{t('settings.hooks.project')}</option>
        </select>
        <span className="param-hint">{t('settings.hooks.scopeHint')}</span>
      </div>

      {/* 设置文件 */}
      <div className="setting-group">
        <label>{t('settings.hooks.configFile')}</label>
        <div className="hooks-path-row">
          <code className="hooks-path">{GLOBAL_HOOKS_PATH}</code>
          <button type="button" className="btn btn--small" onClick={() => void copy('path')}>
            {copied === 'path' ? t('settings.hooks.copied') : t('settings.hooks.copyPath')}
          </button>
        </div>
        <span className="param-hint">{t('settings.hooks.scopeInfo')}</span>
      </div>

      {/* JSON 配置 */}
      <div className="setting-group">
        <label>{t('settings.hooks.jsonConfig')}</label>
        <p className="param-hint">{t('settings.hooks.jsonHint')}</p>
        <div className="hooks-actions">
          <button type="button" className="btn btn--small" onClick={() => void copy('json')}>
            {copied === 'json' ? t('settings.hooks.copied') : t('settings.hooks.copyJson')}
          </button>
          <button type="button" className="btn btn--small" onClick={() => void pasteFromClipboard()}>
            {t('settings.hooks.pasteJson')}
          </button>
          <button type="button" className="btn btn--small" onClick={formatJson}>
            {t('settings.hooks.formatJson')}
          </button>
          <button type="button" className="btn btn--primary btn--small" onClick={() => void save()}
            disabled={!dirty} title={t('settings.hooks.save')}>
            {t('settings.hooks.save')}{saved ? ' ✓' : ''}
          </button>
        </div>
        <textarea
          className="hooks-editor"
          value={json}
          onChange={e => { setJson(e.target.value); setDirty(true); }}
          rows={12}
          spellCheck={false}
          aria-label={t('settings.hooks.jsonConfig')}
        />
        <div className={`hooks-dirty ${dirty ? 'hooks-dirty--true' : ''}`}>
          {dirty ? '● ' + t('settings.hooks.unsaved') : t('settings.hooks.noChanges')}
        </div>
        <span className="param-hint">{t('settings.hooks.saveHint')}</span>
      </div>
    </div>
  );
}

export default HooksPanel;