import pasteboard from '@ohos.pasteboard';

/**
 * 健壮地读取剪贴板文本:
 *  1) getPrimaryText(纯文本记录)
 *  2) 逐条记录 convertToText(兼容 URI/HTML 等记录类型)
 * 取不到返回空串,由调用方提示。
 *
 * ⚠️ 2026-11-17 起本应用**不声明** ohos.permission.READ_PASTEBOARD(受限 user_grant,要在 AGC 申请 ACL、
 * 还要每次弹窗授权)。读剪贴板一律走官方安全控件 `PasteButton`:用户点一下控件 → 系统临时授权 →
 * 这里再调 `getData()` 才成功。**不要在普通按钮/页面出现时直接调这个函数**,那种调用现在只会拿到空串。
 * 写剪贴板(复制分享链接/备份)不需要任何权限,照旧。
 */

/** 写入纯文本到系统剪贴板(分享链接 / 复制节点等) */
export async function setClipboardText(text: string): Promise<void> {
  const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  await pasteboard.getSystemPasteboard().setData(data);
}
export async function getClipboardText(): Promise<string> {
  let data: pasteboard.PasteData;
  try {
    data = await pasteboard.getSystemPasteboard().getData();
  } catch (e) {
    return '';
  }
  if (data === undefined || data === null) {
    return '';
  }
  const primary: string = data.getPrimaryText();
  if (primary !== undefined && primary !== null && primary.trim().length > 0) {
    return primary;
  }
  const count: number = data.getRecordCount();
  for (let i = 0; i < count; i++) {
    const rec = data.getRecord(i);
    if (rec === undefined || rec === null) {
      continue;
    }
    try {
      const t: string = await rec.convertToText();
      if (t !== undefined && t !== null && t.trim().length > 0) {
        return t;
      }
    } catch (e) {
      // 尝试下一条记录
    }
  }
  return '';
}
