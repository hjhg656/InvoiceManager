# 发票管理 InvoiceManager

iOS 本地发票管理 App：手动录入、拍照/相册导入，按月份自动分类汇总。数据全部存在本机 SwiftData，不上传。

## 功能

- 按月分组展示发票，每月合计金额
- 手动录入：金额、日期、商家、分类、备注
- 拍照 / 从相册选择发票图片
- 搜索商家或备注
- 本地存储，离线可用

## 邮箱导入说明

当前版本支持手动导入和相册/拍照导入。完整「邮箱自动拉取」需要邮箱授权（IMAP/OAuth），后续版本可以加。现在可以：

1. 把邮件里的发票附件存到「文件」或相册
2. 在 App 里点 + → 选图片导入

或者用系统分享：在邮件 App 里点分享 → 打开本 App（需后续加 Share Extension）。

## 怎么跑起来

环境：Mac + Xcode 15+，iOS 17+。

1. 双击 `InvoiceManager.xcodeproj` 打开
2. Signing & Capabilities 里选自己的 Team，把 Bundle ID 改成唯一的
3. 真机 Run

## 没有 Mac：GitHub 编译 IPA

1. Actions → Build IPA → Run workflow
2. 下载 Artifacts 里的 `InvoiceManager-unsigned-ipa`
3. 用 LCSign / AltStore 签名安装

## 技术栈

- SwiftUI + SwiftData
- PhotosUI 选图
- 本地数据库，无网络依赖
