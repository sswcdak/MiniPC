import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DEFAULT_QUICK_INPUTS } from './TabletQuickInputs';
export { DEFAULT_QUICK_INPUTS } from './TabletQuickInputs';

export interface TabletPreferences {
  quickInputs: string[];
  quickInputsVersion?: number;
  sidebarCollapsed: boolean;
  routingCollapsed: boolean;
  sidebarWidth: number;
}
const STORE = 'loop_tablet_settings';
const QUICK_INPUTS_VERSION: number = 5;
const LEGACY_QUICK_INPUTS: string[] = ['总结一下当前结果', '列出下一步计划', '帮我分析这个问题'];
const LEGACY_SIMPLE_QA: string = '请用100～200字介绍一下华为公司，涵盖成立时间、总部所在地、主要业务和技术领域。语言简洁、客观，适合不了解这家公司的读者。直接给出一段介绍，不使用标题、列表或宣传口号。';
const LEGACY_CAT_ANALYSIS: string = '请分析这张图片，用中文描述：\n1. 图中动物的种类、毛色和外观特征。\n2. 它的姿态、视线方向及身体各部分的位置。\n3. 周围环境、光线和画面构图。\n4. 两到三个容易被忽略的可见细节。\n\n请以图中实际可见的信息为依据；无法确定的内容请明确说明，不要仅凭外观推断具体品种、年龄、性别或健康状况。总字数控制在200～400字。';
export function normalizeTabletPreferences(value: TabletPreferences): TabletPreferences {
  const inputs: string[] = [];
  for (let i = 0; i < DEFAULT_QUICK_INPUTS.length; i++) {
    const saved = Array.isArray(value.quickInputs) ? value.quickInputs[i] : undefined;
    const legacyDefault = (value.quickInputsVersion ?? 0) < 2 && i < LEGACY_QUICK_INPUTS.length &&
      saved === LEGACY_QUICK_INPUTS[i];
    const legacySimpleQa = (value.quickInputsVersion ?? 0) < 3 && i === 3 && saved === LEGACY_SIMPLE_QA;
    const legacyCatAnalysis = (value.quickInputsVersion ?? 0) < 4 && i === 1 && saved === LEGACY_CAT_ANALYSIS;
    const legacyLongSummary = (value.quickInputsVersion ?? 0) < 5 && i === 0 &&
      saved === DEFAULT_QUICK_INPUTS[0].replace('生成一份100～200字的中文总结', '生成一份300～500字的中文总结');
    inputs.push(typeof saved === 'string' && !legacyDefault && !legacySimpleQa && !legacyCatAnalysis && !legacyLongSummary ? saved.substring(0, 4000) : DEFAULT_QUICK_INPUTS[i]);
  }
  return { quickInputs: inputs, quickInputsVersion: QUICK_INPUTS_VERSION,
    sidebarCollapsed: value.sidebarCollapsed === true, routingCollapsed: value.routingCollapsed === true,
    sidebarWidth: Number.isFinite(value.sidebarWidth) ? Math.max(160, Math.min(300, value.sidebarWidth)) : 200 };
}
export function loadTabletPreferences(context: common.Context): TabletPreferences {
  try {
    const store = preferences.getPreferencesSync(context, { name: STORE });
    return normalizeTabletPreferences(JSON.parse(store.getSync('layout', '{}') as string) as TabletPreferences);
  } catch (_error) { return normalizeTabletPreferences({ quickInputs: DEFAULT_QUICK_INPUTS, sidebarCollapsed: false, sidebarWidth: 200, routingCollapsed: false }); }
}
export async function saveTabletPreferences(context: common.Context, value: TabletPreferences): Promise<void> {
  const store = preferences.getPreferencesSync(context, { name: STORE });
  // An explicit edit is never mistaken for an old default during a later load.
  store.putSync('layout', JSON.stringify(normalizeTabletPreferences({ quickInputs: value.quickInputs,
    quickInputsVersion: QUICK_INPUTS_VERSION, sidebarCollapsed: value.sidebarCollapsed,
    routingCollapsed: value.routingCollapsed, sidebarWidth: value.sidebarWidth })));
  await store.flush();
}
