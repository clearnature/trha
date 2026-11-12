// LLM 设置面板（models 功能区，对齐 Reasonix「模型参数」）：
// 生成参数（temperature/topP/maxTokens）——null 字段 = 内核默认，
// 接线到 sessionStore.setGenParams → step 请求 genParams（http.ts）。
// 模型选择（selectedModel / selectedProvider）复用现有 ModelPicker 语义。

import type { Translate } from './i18n.js';
import { useSession, useSessionStore } from './SessionContext.js';

export interface LlmSettingsPanelProps {
  t: Translate;
}

const PARAM_RANGES = {
  temperature: { min: 0, max: 2, step: 0.1 },
  topP: { min: 0, max: 1, step: 0.05 },
  maxTokens: { min: 1, max: 100000, step: 100 },
} as const;

function NumParam({
  labelKey, value, onChange, range, unit, placeholder,
}: {
  labelKey: string;
  value: number | null;
  onChange: (v: number | null) => void;
  range: { min: number; max: number; step: number };
  unit?: string;
  placeholder: string;
}) {
  return (
    <div className="setting-group">
      <label>{labelKey}</label>
      <div className="param-row">
        <input
          type="number"
          min={range.min}
          max={range.max}
          step={range.step}
          value={value === null ? '' : value}
          placeholder={placeholder}
          onChange={e => {
            const raw = e.target.value;
            if (raw === '') { onChange(null); return; }
            const n = Number(raw);
            if (Number.isFinite(n)) onChange(Math.min(range.max, Math.max(range.min, n)));
          }}
        />
        {unit && <span className="param-unit">{unit}</span>}
        <button type="button" className="param-reset" onClick={() => onChange(null)}>↺</button>
      </div>
      <span className="param-hint">{placeholder}</span>
    </div>
  );
}

export function LlmSettingsPanel({ t }: LlmSettingsPanelProps) {
  const genParams = useSession(s => s.genParams);
  const models = useSession(s => s.models);
  const selectedModel = useSession(s => s.selectedModel);
  const store = useSessionStore();
  const gp = genParams ?? { temperature: null, topP: null, maxTokens: null };
  const setGenParams = (patch: Partial<typeof gp>) =>
    store.getState().setGenParams({ ...gp, ...patch });

  return (
    <div className="settings-pagebody">
      <div className="settings-page-title">
        <h3>{t('settings.tab.models')}</h3>
        <p className="settings-page-desc">{t('settings.llm.desc')}</p>
      </div>

      <div className="setting-group">
        <label>{t('settings.llm.selectedModel')}</label>
        <div className="settings-model-list">
          {models.length === 0 && <span className="param-hint">{t('settings.llm.noModels')}</span>}
          {models.map(m => (
            <button
              key={m.name}
              type="button"
              className={`settings-model-item ${m.name === selectedModel ? 'active' : ''}`}
              onClick={() => store.getState().setTarget(null, m.name)}
            >
              <strong>{m.name}</strong>
              <span>{m.description}</span>
              <span className="model-ctx">{(m.contextSize / 1024).toFixed(0)}K ctx</span>
            </button>
          ))}
        </div>
      </div>

      <div className="setting-group">
        <label>{t('settings.llm.genParams')}</label>
        <NumParam
          labelKey={t('settings.llm.temperature')}
          value={gp.temperature}
          onChange={v => setGenParams({ temperature: v })}
          range={PARAM_RANGES.temperature}
          placeholder={t('settings.llm.default', { v: '内核默认' })}
        />
        <NumParam
          labelKey={t('settings.llm.topP')}
          value={gp.topP}
          onChange={v => setGenParams({ topP: v })}
          range={PARAM_RANGES.topP}
          placeholder={t('settings.llm.default', { v: '内核默认' })}
        />
        <NumParam
          labelKey={t('settings.llm.maxTokens')}
          value={gp.maxTokens}
          onChange={v => setGenParams({ maxTokens: v })}
          range={PARAM_RANGES.maxTokens}
          unit="tok"
          placeholder={t('settings.llm.default', { v: '内核默认' })}
        />
        <span className="param-hint">{t('settings.llm.nullIsDefault')}</span>
      </div>
    </div>
  );
}

export default LlmSettingsPanel;