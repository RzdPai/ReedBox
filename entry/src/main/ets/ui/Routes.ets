/** 路由名与跳转入口（只做栈操作 + 写一个"目标 id"到全局状态，不 import 页面 → 无循环依赖）。 */

import { AppState } from '../core/AppState';

export const PAGE_PROFILE_EDIT: string = 'ProfileEditPage';
export const PAGE_ROUTE: string = 'RoutePage';
export const PAGE_SETTINGS: string = 'SettingsPage';
export const PAGE_LOGS: string = 'LogsPage';
export const PAGE_ABOUT: string = 'AboutPage';
export const PAGE_SUB_DETAIL: string = 'SubDetailPage';
export const PAGE_RULE_EDIT: string = 'RuleEditPage';

/** 侧栏分区（0/1 与 2~5 现在**都是壳内直接切换**，只有节点编辑这类详情页才压栈） */
export const SEC_PROFILES: number = 0;
export const SEC_GROUPS: number = 1;
export const SEC_ROUTE: number = 2;
export const SEC_SETTINGS: number = 3;
export const SEC_LOGS: number = 4;
export const SEC_ABOUT: number = 5;

export class ProfileEditParam {
  /** 空串 = 新建 */
  profileId: string = '';
}

export class SubDetailParam {
  url: string = '';
}

export class RuleEditParam {
  index: number = -1;
}

export function gotoProfileEdit(stack: NavPathStack, profileId: string, presetType: string = ''): void {
  // 目标 id / 预设协议走全局状态（页面里读 AppState.editingProfileId / editingProfileType）：
  // NavPathStack 的 param 在 @Builder navDestination 里取用要多绕一层 queryNavigationInfo，纯属多余。
  AppState.get().editingProfileId = profileId;
  AppState.get().editingProfileType = presetType;
  const param: ProfileEditParam = new ProfileEditParam();
  param.profileId = profileId;
  stack.pushPathByName(PAGE_PROFILE_EDIT, param);
}

/** 日志/关于现在是**壳内分区**（不再压栈）：走 pendingSection 让外壳直接切过去 */
export function gotoLogs(): void {
  AppState.get().pendingSection = SEC_LOGS;
}

export function gotoAbout(): void {
  AppState.get().pendingSection = SEC_ABOUT;
}

export function gotoSubDetail(stack: NavPathStack, url: string): void {
  const param: SubDetailParam = new SubDetailParam();
  param.url = url;
  stack.pushPathByName(PAGE_SUB_DETAIL, param);
}

export function gotoRuleEdit(stack: NavPathStack, index: number): void {
  const param: RuleEditParam = new RuleEditParam();
  param.index = index;
  stack.pushPathByName(PAGE_RULE_EDIT, param);
}
