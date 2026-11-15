# 发票管理 InvoiceManager

iOS 本地发票管理 App，深色玻璃风格 UI。

## 功能

- **按月分组**展示，每月合计
- 手动录入金额、日期、商家、分类、备注
- **拍照 / 相册**导入图片
- **从文件导入** PDF 或图片（邮件附件可先存到「文件」再导入）
- 搜索、长按删除
- 全部本地 SwiftData，不联网

## UI

深色主题 + `ultraThinMaterial` 玻璃卡片，适配 iOS 17+ 材质系统。

## 运行

Xcode 15+ / iOS 17+，或 Actions 打未签名 IPA 后用 LCSign 安装。

## 邮箱导入

当前支持：邮件附件 → 存到文件 / 相册 → App 内导入。  
后续可加 Share Extension 或 IMAP 同步。
