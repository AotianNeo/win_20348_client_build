# Windows 10 (Build 20348 / Iron `fe_release`) Client Automated 100% Native DISM/CBS ISO Builder

本仓库提供一套全自动 GitHub Actions 构建方案：每月自动拉取微软官方最新发布的 **Windows Server 2022 月度更新版 ISO (`Build 20348.xxxx`)** 与 **微软官方 UUP `20348.1` (`2ba1d737-a36b-415b-a630-85bd5146d77d`) 原版客户端 ESD/CAB 组件包**，**100% 采用微软官方原生 `DISM /Apply-Unattend` 与 `DISM /Set-Edition` (CBS / WCP / DrvInst / Transmog) 离线服务引擎**（零后期手写 `.reg` 注册表硬注入），完整安装客户端 CBS 组件树、硬件驱动、多媒体框架与桌面组件，**默认开启全部客户端视觉效果与 `.NET Framework 3.5 (NetFx3)`**，并完整支持后续每月累积更新（LCU），生成开箱即用的 **Windows 10 (Build 20348) 桌面客户端 4 合 1 ISO**。

---

## 包含版本 (`sources\install.wim`)

所有 4 个版本采用 WIM 单实例流共享（Single-Instancing），兼顾纯净 LTSC 风格体验与完整微软商店 UWP 体验：

| 索引 (Index) | Edition ID | 版本名称 | UWP 预装策略 | 激活与支持特性 |
| :---: | :--- | :--- | :--- | :--- |
| **1** | `IoTEnterprise` | **Windows 10 IoT 企业版 (精简无预装UWP)** | **零消费级膨胀 UWP**（仅保留系统核心组件） | 原生 `DISM /Set-Edition:IoTEnterprise` 转换，支持 HWID 数字权利永久激活 |
| **2** | `Professional` | **Windows 10 专业版** | **完整预装微软官方 Microsoft Store 及 41 款现代 UWP 应用** | 原生 `Microsoft-Windows-ProfessionalEdition` CBS 安装，支持 KMS / 数字权利激活 |
| **3** | `ProfessionalWorkstation` | **Windows 10 专业工作站版** | **完整预装微软官方 Microsoft Store 及 41 款现代 UWP 应用** | 原生 `DISM /Set-Edition:ProfessionalWorkstation` 转换，支持 KMS / 数字权利激活 |
| **4** | `Enterprise` | **Windows 10 企业版** | **完整预装微软官方 Microsoft Store 及 41 款现代 UWP 应用** | 原生 `DISM /Set-Edition:Enterprise` 转换，支持 KMS / 数字权利激活 |

---

## 核心特性与技术亮点

### 1. 100% 微软官方原生 DISM / CBS 引擎构建（零后期手写 `.reg` 注入）
- 直接使用微软官方 UUP `20348.1` (`2ba1d737-a36b-415b-a630-85bd5146d77d`) 原始签名的 17 个 Client ESD 组件包（`Microsoft-Windows-Client-Desktop-Required-Package`、`Microsoft-Windows-Client-Features-Package`、`Microsoft-Windows-EditionPack-Professional-Package` 等）与 5 个 `zh-CN` 语言特性按需功能包（`Basic`、`Handwriting`、`OCR`、`Speech`、`TextToSpeech`）。
- 所有硬件驱动（笔记本 I2C/GPIO 精确式触摸板驱动、蓝牙音频 A2DP/AVRCP/HFP 驱动、无线网卡驱动、Xbox 外设驱动）、系统服务、`Svchost` 服务组、`Win32PrioritySeparation = 2`（桌面短量子前台优先调度）及 `ProductPolicy` 均由 Windows 自身的 **CBS / WCP / DrvInst / Edition Transmog** 引擎在 `dism.exe /Apply-Unattend` 与 `dism.exe /Set-Edition` 阶段自动编译生成。

### 2. 完整生命周期月度累积更新（LCU）支持
- 通过版本对齐的 `Microsoft-Windows-ProfessionalEdition` 与 `Microsoft-Windows-Media-Placeholder-Package` 组件清单（`OfficialEditionManifests/`），使系统核心、桌面 Shell（`explorer.exe`、`shell32.dll`、`dwmcore.dll`、`udwm.dll`）、蓝牙协议栈（`BthEnum.sys`、`bthport.sys`）及 Media Foundation（`mfplat.dll`、`mfcore.dll`）全部保持在当月最新 LCU 版本（如 `.5761` / `KB5126655`），并原生支持后续每月 Windows Update / LCU 累积更新安装。

### 3. 默认开启全部客户端视觉效果 & `.NET Framework 3.5 (NetFx3)`
- 默认配置 `VisualFXSetting = 1`（最佳外观，完整开启全部桌面动画、阴影、平滑滚动与 Aero Peek 视觉效果）。
- 默认从官方 ISO `sources\sxs` 原生启用 `.NET Framework 3.5 (NetFx3)`。
- 彻底卸载 `ServerStandardEdition`、`ServerDatacenterEdition`、`Microsoft-Windows-Server-Shell-Package` 与 `SConfig`，确保开机直接进入纯净 Windows 10 客户端 OOBE 与 `explorer.exe` 桌面。

---

## 下载与使用

1. **直接下载已构建镜像**：
   - 前往本仓库 [**Releases**](../../releases) 页面下载最新版本的分卷压缩包（`.iso.7z.001` ~ `.003`），使用 7-Zip 解压 `.001` 即可得到完整 `.iso` 镜像（解压后请对照 `SHA256SUMS.txt` 校验哈希）；
   - 或在 [**Actions**](../../actions) 最新成功运行的任务页面底部 **Artifacts** 区域，直接下载未分卷的单文件完整 ISO。
2. **自动与手动触发构建**：
   - **定时构建**：工作流 [`.github/workflows/auto_patch.yml`](./.github/workflows/auto_patch.yml) 在每月 15 日 `04:00 UTC` 自动运行并发布最新月度 Release。
   - **手动触发**：进入 **Actions -> Auto Patch Official Windows Server 2022 ISO to 20348 Client -> Run workflow** 即可随时触发云端构建。
3. **本地运行构建**：
   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\Patch-Official-Server2022-ISO.ps1 -WorkDir "D:\work_20348" -OutputDir "D:\out_iso"
   ```
