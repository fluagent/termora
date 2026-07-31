<div align="center">

# Termora

**现代、高效、跨平台的全能桌面级开发工具箱**

*A Modern, High-Performance Cross-Platform Desktop Developer Toolbox*

[English](./README.md) | **简体中文**

[![GitHub Release](https://img.shields.io/github/v/release/pynets/termora?style=flat-square&color=02569B)](https://github.com/pynets/termora/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](./LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.16-02569B?style=flat-square&logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey.svg?style=flat-square)]()

</div>

---

## 💡 关于 Termora (About)

**Termora** 旨在从根本上解决开发者日常桌面工具链碎片化的痛点。不再需要打开 4~5 个庞大吃内存的 Electron 应用来分别操作 SSH 终端、SFTP 文件上传、数据库查询、Markdown/LaTeX 公式排版以及悬浮截图参考贴图——**Termora 采用 Flutter 构建，将这五大核心开发者生产力工具融合进同一个原生流畅的桌面客户端**。

| 核心维度 | 传统分散工具方案 | **Termora 一体化工具箱** |
| :--- | :--- | :--- |
| **性能与内存占用** | 需常驻 4-5 个高内存占用应用 | **单个轻量极速 Flutter 原生编译程序** |
| **SSH / SFTP 管理** | 终端命令行与图形化传输切来切去 | **多屏多会话并发管理 + 拖拽式 SFTP 文件浏览器** |
| **数据库开发** | 必须安装独立客户端 | **内置 SQL 语法高亮编写器及结构化数据浏览** |
| **技术笔记排版** | 依赖外部 Markdown 编辑器 | **实时双栏渲染 + 物理数学 LaTeX (`$$`) 公式支持** |
| **界面截屏与对比贴图** | 需额外常驻截图工具 | **全局快捷键 (`⌥+Shift+X`) + 桌面置顶贴图对照** |
| **数据隐私与持久化** | 许多商业工具强制依赖云端账号 | **纯本地优先存储 (Local-First)，数据绝对私密掌控** |

---

## 📥 下载安装包 (Release (v0.0.44)

- **macOS 安装包 (.dmg)**: [下载 Termora-v0.0.44-macOS.dmg](https://github.com/pynets/termora/releases/download/v0.0.44/Termora-v0.0.44-macOS.dmg)
- **全部发布版本**: [访问 GitHub Releases 页面](https://github.com/pynets/termora/releases)

---

## 📸 应用预览 (Preview)

| 🖥️ 终端控制台 (Terminal) | 🌐 远程主机与 SFTP (Remote) |
| :---: | :---: |
| ![终端](docs/screenshots/terminal.png) | ![远程](docs/screenshots/remote.png) |
| **🗄️ 数据库客户端 (Database)** | **📝 全能笔记与 LaTeX (Notes)** |
| ![数据库](docs/screenshots/database.png) | ![笔记](docs/screenshots/notes.png) |

---

## 🚀 核心特性 (Key Features)

### 🖥️ 1. SSH / SFTP 终端连接与文件管理器
- **多会话管理与分屏**：同时管理与连接多个 SSH 主机，支持快速切换与多会话并发。
- **内置 SFTP 浏览器**：不仅支持命令行交互，更能便捷拖拽管理远端文件。
- **命令片段与高亮**：内置常用命令片段库与日志关键词自动高亮解析。

### 🗄️ 2. 数据库客户端 (Database Explorer)
- **多数据源支持**：内置支持 PostgreSQL、SQLite 等常用数据源的高效连接与操作。
- **SQL 编写与执行**：具备高亮提示的 SQL 编写器，快速执行查询并结构化浏览表格数据。

### 📝 3. 全能 Markdown 与 LaTeX 笔记
- **实时双栏预览**：流畅的 Markdown 编辑与渲染能力，支持表格、代码段与任务列表。
- **LaTeX 公式排版**：内置对数学物理公式（`$$` 语法）的精确排版渲染。
- **高清 PDF 导出**：支持把技术文档一键生成并导出为精美的标准 PDF。

### 📸 4. 截屏编辑与桌面贴图 (Screenshot & Pin Window)
- **快捷唤起截屏**：全局快捷键 `⌥+Shift+X` (macOS/Windows 通用) 一键截取屏幕。
- **轻量编辑器**：支持框选、标注和高亮处理。
- **桌面悬浮贴图**：一键将其贴图悬浮在桌面最前列，方便随时对比研发参考图。

### 🎨 5. 现代审美设计与双语无缝适配
- **明暗两极智能适配**：内置精调深色 / 浅色模式，与品牌自选主色体系连贯融合。
- **中英文双语界面**：应用设置内一键在 **English / 简体中文 / 跟随系统** 之间切换（默认英文）。
- **常驻系统托盘**：提供便捷开机自启、置顶及快捷操作菜单。

---

## 🛠️ 技术栈 (Tech Stack)

- **框架**：[Flutter 3.x](https://flutter.dev) / [Dart 3.x](https://dart.dev)
- **状态管理**：[Riverpod 2.x](https://riverpod.dev)
- **桌面原生特性**：`window_manager`, `tray_manager`, `desktop_multi_window`, `hotkey_manager`
- **本地化存储**：`shared_preferences`, `sqlite3`

---

## 📦 构建与运行 (Building & Running)

### 环境要求
- Flutter SDK `>= 3.16.0`
- macOS / Windows / Linux 桌面开发环境

### 克隆与依赖安装
```bash
git clone https://github.com/pynets/termora.git
cd termora
flutter pub get
```

### 本地运行
```bash
# macOS
flutter run -d macos

# Windows
flutter run -d windows

# Linux
flutter run -d linux
```

### 生产打包
```bash
flutter build macos --release
```

---

## 🤝 贡献指南 (Contributing)

非常欢迎各类 Issue 与 Pull Request！如果您对 Termora 有建议或新功能构想，欢迎共同建设。

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 提交 Pull Request

---

## 📄 开源协议 (License)

本项目采用 [MIT License](./LICENSE) 开源协议。
