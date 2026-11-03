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
const QUICK_INPUTS_VERSION: number = 2;
const LEGACY_QUICK_INPUTS: string[] = ['总结一下当前结果', '列出下一步计划', '帮我分析这个问题'];
export function normalizeTabletPreferences(value: TabletPreferences): TabletPreferences {
  const inputs: string[] = [];
  for (let i = 0; i < DEFAULT_QUICK_INPUTS.length; i++) {
    const saved = Array.isArray(value.quickInputs) ? value.quickInputs[i] : undefined;
    const legacyDefault = (value.quickInputsVersion ?? 0) < QUICK_INPUTS_VERSION && i < LEGACY_QUICK_INPUTS.length &&
      saved === LEGACY_QUICK_INPUTS[i];
    inputs.push(typeof saved === 'string' && !legacyDefault ? saved.substring(0, 4000) : DEFAULT_QUICK_INPUTS[i]);
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
