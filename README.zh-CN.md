# say vibe

<p align="center">
  <a href="./README.md">English</a> ·
  <a href="./README.zh-CN.md"><strong>简体中文</strong></a>
</p>

<p align="center">
  <img src="assets/logo/ltr-logo.svg" width="108" alt="say vibe logo" />
</p>

<p align="center">
  <strong>把 iPhone 系统输入法的语音输入能力，接到 Mac 的真实输入工作流里。</strong>
</p>

<p align="center">
  say vibe 是一个面向 <code>iPhone + Mac</code> 的局域网输入同步项目，重点解决低摩擦语音采集、安静 vibe 和快速落字。
</p>

## 界面预览

### Vibe 操作演示

<p align="center">
  <img src="docs/media/vibe-demo.gif" width="240" alt="say vibe vibe flow demo" />
</p>

### 手机界面

<table>
  <tr>
    <td width="50%" align="center">
      <img src="docs/media/mobile-settings.jpg" width="280" alt="say vibe 手机设置界面" />
    </td>
    <td width="50%" align="center">
      <img src="docs/media/mobile-vibe.jpg" width="280" alt="say vibe 手机 vibe 界面" />
    </td>
  </tr>
  <tr>
    <td align="center"><strong>设置</strong></td>
    <td align="center"><strong>Vibe</strong></td>
  </tr>
</table>

### PC 界面

<p align="center">
  <img src="docs/media/desktop-console.png" alt="say vibe 桌面控制台" />
</p>

## 核心价值

1. 利用输入法的语音模块，天然吃到系统输入法对普通话、英文和各种方言的适配能力。
2. 像聊微信一样，小声 vibe，把想法先低摩擦地说出来，再在电脑端补改，尽量保持输入心流。

## 当前开源范围

这个仓库当前主要公开并维护两个目录：

- `ios/`
  - SwiftUI iPhone 客户端
  - 负责连接电脑、同步输入、管理会议纪要
- `pc_rust/`
  - `Vue + Vite + Tauri + Rust` 桌面端
  - 负责本地中继、配对、状态展示和自动输出

其他目录目前属于历史实验或过渡产物，不作为这次开源整理的重点。

## 功能概览

### iOS

- 三个主板块：`设置`、`Vibe`、`会议纪要`
- 局域网扫描、最近设备、扫码配对
- 输入自动防抖同步到电脑
- 远程切换电脑端自动输出动作
- 远程触发 `PC Enter`
- 会议纪要按文档保存，支持导出
- 中英文切换、浅色 / 深色 / 跟随系统
- 主屏 Widget 快速打开输入区

### 桌面端

- 使用 `npm` 管理前端依赖，使用 `Rust + Tauri` 提供桌面能力
- 启动本地 relay，兼容移动端当前协议
- 桌面端展示配对二维码、局域网地址、同步状态和日志
- 自动输出支持“待修改”和“直接发送”两种模式
- 支持独立的 `PC Enter` 控制接口
- 当前文本视图默认不可复制，避免误触影响工作流

## 工作方式

1. 在 Mac 上启动桌面 relay。
2. 用 iPhone 扫码配对或手动填写局域网地址。
3. 使用 iPhone 输入法的语音输入，把文本稳定送到当前桌面工作流中。

## 目录结构

- `ios/SayVibe.xcodeproj`
- `ios/SayVibe/`
- `ios/SayVibeWidget/`
- `ios/scripts/`
- `pc_rust/src/`
- `pc_rust/src-tauri/`
- `docs/media/`
- `assets/logo/`

## 快速开始

### 桌面端

```bash
cd pc_rust
npm install
npm run tauri:dev
```

默认 relay 端口是 `18700`。

如果端口冲突：

```bash
cd pc_rust
PORT=18701 npm run tauri:dev
```

桌面打包：

```bash
cd pc_rust
npm run tauri:build
```

### iOS

1. 用完整 Xcode 打开 `ios/SayVibe.xcodeproj`
2. 在 `Signing & Capabilities` 里选择你自己的 Team
3. 运行到 iPhone
4. 通过扫码或手动输入连接到桌面端

如需打包 IPA：

```bash
./ios/scripts/package-iphone.sh
```

如需重建 App Icon：

```bash
./ios/scripts/generate-appicon.sh
```

## 桌面 Relay 接口

当前桌面端会暴露这些本地接口：

- `GET /health`
- `GET /api/state`
- `GET /events`
- `GET /dashboard`
- `GET /android`
- `POST /api/push_text`
- `POST /api/control/auto-ime`
- `POST /api/control/auto-ime-mode`
- `POST /api/control/pc-enter`

## 隐私与限制

- 当前定位是局域网内使用，不走云端同步。
- 目前未加入 TLS、账号体系和鉴权。
- macOS 自动输出依赖辅助功能权限；build 版授权对象应为 `say vibe.app`。
- iOS IPA 导出依赖你本机自己的 Apple Team、证书和签名环境。

## 社区与支持

如果你在使用 `say vibe`，或者想跟进后续更新，可以通过下面几种方式联系和支持我：

- 群聊二维码只有短期有效，过期后可以先加个人微信，我会在新群可用时继续拉你进群。
- 如果这个项目对你有帮助，也欢迎打赏赞助，为开发者提供持续迭代的动力。

<table>
  <tr>
    <td width="33%" align="center">
      <img src="docs/media/wechat-group.jpg" width="220" alt="say vibe 微信群" />
    </td>
    <td width="33%" align="center">
      <img src="docs/media/personal-wechat.jpg" width="220" alt="say vibe 个人微信" />
    </td>
    <td width="33%" align="center">
      <img src="docs/media/sponsor-wechat-pay.jpg" width="220" alt="say vibe 微信赞赏" />
    </td>
  </tr>
  <tr>
    <td align="center"><strong>微信群</strong></td>
    <td align="center"><strong>个人微信</strong></td>
    <td align="center"><strong>微信赞赏</strong></td>
  </tr>
</table>

## 维护信息

- Maintainer: `aqiangai`
- License: `MIT`

