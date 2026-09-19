// 模型偏好面板（模型 → 模型偏好）——形态对齐 Reasonix ModelPreferences：
//   区块一「用途 · 使用模型 · 连接」：默认模型、独立规划模型、图片理解、网页搜索、
//                                   子代理模型、子代理推理强度
//   区块二「高级运行设置 · 运行偏好」：思考语言、自动压缩阈值
// 接线状态：模型下拉用 store.models 真实列表（活数据）；选择为本地状态，
//          持久化到内核 SettingsView 属预留（plannedInterface 标注）。

import { useSession, useSessionStore } from './SessionContext.js';
import { useExtSettings } from '../state/settingsStore.js';

export interface ModelPreferencesPanelProps {
  t: (key: string) => string;
}

interface ChoiceRow {
  labelKey: string;
  hintKey: string;
  allowSession: boolean;        // 是否含「跟随会话」类选项
  options: string[];            // 数据/枚举选项（真实模型名或级别名）
  selectionKey: string;         // 预留的 SettingsView 字段名
}

function ChoiceSelect({ row, value, onChange }: {
  row: ChoiceRow; value: string; onChange: (v: string) => void;
}) {
  return (
    <div className="setting-group">
      <label>{row.labelKey}</label>
      <select value={value} onChange={e => onChange(e.target.value)}>
        {row.options.map(o => <option key={o} value={o}>{o}</option>)}
      </select>
      <span className="param-hint">{row.hintKey} · <code>{row.selectionKey}</code>（预留）</span>
    </div>
  );
}

export function ModelPreferencesPanel({ t }: ModelPreferencesPanelProps) {
  const models = useSession(s => s.models);
  const selectedModel = useSession(s => s.selectedModel);
  const store = useSessionStore();
  const modelNames = models.length > 0 ? models.map(m => m.name) : [t('settings.modelPrefs.noModels')];

  // 默认模型 = 当前会话选中模型（双向同步：选这里 → setTarget 影响后续 step）
  const [defaultModelUi, setDefaultModelUi] = useState(selectedModel ?? modelNames[0] ?? '');
  const defaultModel = selectedModel ?? defaultModelUi;
  const mp = useExtSettings(s => s.modelPrefs);
  const setModelPrefs = useExtSettings(s => s.setModelPrefs);
  const { planner, vision, webSearch, subagentModel, subagentEffort, thinkLang, compactMode, compactCustom } = mp;

  const rows: ChoiceRow[] = [
    { labelKey: t('settings.modelPrefs.defaultModel'), hintKey: t('settings.modelPrefs.defaultModelHint'),
      allowSession: false, options: modelNames, selectionKey: 'defaultModel' },
    { labelKey: t('settings.modelPrefs.plannerModel'), hintKey: t('settings.modelPrefs.plannerModelHint'),
      allowSession: true, options: ['follow-session', t('settings.modelPrefs.followSession'), ...modelNames], selectionKey: 'plannerModel' },
    { labelKey: t('settings.modelPrefs.visionModel'), hintKey: t('settings.modelPrefs.visionModelHint'),
      allowSession: true, options: ['auto', t('settings.modelPrefs.autoSelect'), ...modelNames], selectionKey: 'visionModel' },
    { labelKey: t('settings.modelPrefs.webSearchModel'), hintKey: t('settings.modelPrefs.webSearchModelHint'),
      allowSession: true, options: ['auto', t('settings.modelPrefs.sessionAuto'), ...modelNames], selectionKey: 'webSearchModel' },
    { labelKey: t('settings.modelPrefs.subagentModel'), hintKey: t('settings.modelPrefs.subagentModelHint'),
      allowSession: true, options: ['follow-main', t('settings.modelPrefs.followMain'), ...modelNames], selectionKey: 'subagentModel' },
    { labelKey: t('settings.modelPrefs.subagentEffort'), hintKey: t('settings.modelPrefs.subagentEffortHint'),
      allowSession: false, options: ['auto', 'low', 'medium', 'high'], selectionKey: 'subagentEffort' },
  ];

  return (
    <div className="settings-pagebody">
      {/* 区块一：用途 · 使用模型 · 连接 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.modelPrefs.usageTitle')}</h4>
        <p className="settings-page-desc">{t('settings.modelPrefs.usageDesc')}</p>

        <ChoiceSelect row={rows[0]} value={defaultModel}
          onChange={v => { setDefaultModelUi(v); store.getState().setTarget(null, v); }} />
        <ChoiceSelect row={rows[1]} value={planner} onChange={v => setModelPrefs({ planner: v })} />
        <ChoiceSelect row={rows[2]} value={vision} onChange={v => setModelPrefs({ vision: v })} />
        <ChoiceSelect row={rows[3]} value={webSearch} onChange={v => setModelPrefs({ webSearch: v })} />
        <ChoiceSelect row={rows[4]} value={subagentModel} onChange={v => setModelPrefs({ subagentModel: v })} />
        <ChoiceSelect row={rows[5]} value={subagentEffort} onChange={v => setModelPrefs({ subagentEffort: v })} />
      </section>

      {/* 区块二：高级运行设置 · 运行偏好 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.modelPrefs.advancedTitle')}</h4>

        <div className="setting-group">
          <label>{t('settings.modelPrefs.thinkLang')}</label>
          <select value={thinkLang} onChange={e => setModelPrefs({ thinkLang: e.target.value })}>
            <option value="auto">{t('settings.modelPrefs.thinkLangAuto')}</option>
            <option value="zh">中文</option>
            <option value="en">English</option>
          </select>
          <span className="param-hint">{t('settings.modelPrefs.thinkLangHint')} · <code>reasoningLocale</code>（预留）</span>
        </div>

        <div className="setting-group">
          <label>{t('settings.modelPrefs.compactThreshold')}</label>
          <div className="compact-presets">
            <button type="button" className={`compact-preset ${compactMode === 'early' ? 'active' : ''}`}
              onClick={() => setModelPrefs({ compactMode: 'early', compactCustom: '70' })}>
              <strong>{t('settings.modelPrefs.compactEarly')} · 70%</strong>
              <span>{t('settings.modelPrefs.compactEarlyHint')}</span>
            </button>
            <button type="button" className={`compact-preset ${compactMode === 'recommended' ? 'active' : ''}`}
              onClick={() => setModelPrefs({ compactMode: 'recommended', compactCustom: '80' })}>
              <strong>{t('settings.modelPrefs.compactRecommended')} · 80%</strong>
              <span>{t('settings.modelPrefs.compactRecommendedHint')}</span>
            </button>
            <button type="button" className={`compact-preset ${compactMode === 'late' ? 'active' : ''}`}
              onClick={() => setModelPrefs({ compactMode: 'late', compactCustom: '85' })}>
              <strong>{t('settings.modelPrefs.compactLate')} · 85%</strong>
              <span>{t('settings.modelPrefs.compactLateHint')}</span>
            </button>
            <div className="compact-custom">
              <span>{t('settings.modelPrefs.compactCustom')}</span>
              <input type="number" min={1} max={99} value={compactCustom} onChange={e => {
                setModelPrefs({ compactCustom: e.target.value, compactMode: 'custom' });
              }} />
              <span>%</span>
            </div>
          </div>
          <span className="param-hint">{t('settings.modelPrefs.compactHint')} · <code>compactThreshold</code>（预留）</span>
        </div>
      </section>
    </div>
  );
}

export default ModelPreferencesPanel;