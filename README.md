# Windows 10 (Build 20348 / Iron `fe_release`) Client Automated Official ISO Patcher

本仓库提供一套 **100% 纯微软官方源文件（零第三方修改组件）** 的全自动 GitHub Actions 构建方案：每月自动拉取微软官方最新发布的 **Windows Server 2022 月度更新版 ISO (`Build 20348.xxxx`)**，并将其无损转换为纯净、可原生安装官方月度累积更新（LCU）的 **Windows 10 (Build 20348) 桌面客户端 4 合 1 ISO**。

---

## 包含版本 (`sources\install.wim`)

所有 4 个版本共享 100% 底层文件数据流（单文件 ISO 体积仅 ~4.9 GB）：

| 索引 (Index) | Edition ID | 版本名称 | `ProductInfo` SKU | 激活与支持特性 |
| :---: | :--- | :--- | :---: | :--- |
| **1** | `EnterpriseS` | **Windows 10 企业版 LTSC 2021** | `0x7D` (`125`) | 支持 LTSC 2021 KMS / 数字权利激活 |
| **2** | `IoTEnterpriseS` | **Windows 10 IoT 企业版 LTSC 2021** | `0xBD` (`189`) | 支持 HWID 数字权利永久激活（支持周期至 2032 年） |
| **3** | `Professional` | **Windows 10 专业版** | `0x30` (`48`) | 完整专业版策略与特性，支持 KMS / 数字权利激活 |
| **4** | `Enterprise` | **Windows 10 企业版** | `0x04` (`4`) | 完整企业版策略与特性，支持 KMS / 数字权利激活 |

---

## 为什么选择本方案（核心优势）

1. **100% 微软官方源文件（零第三方魔改文件）**：
   - **底层母盘与最新补丁**：构建时自动从 [NTRiver 官方 MSDN/MVS 镜像源](https://ntriver.org/download-windows-server-2022) 获取微软当月最新发布的官方简体中文 Windows Server 2022 完整版 ISO（如 `zh-cn_windows_server_2022_updated_oct_2026_x64_dvd_3fc7f935.iso`），并强制验证官方 SHA-256 哈希。
   - **官方客户端授权、品牌与策略文件 (`OfficialClientFiles/`)**：仓库内置的 402 个小文件（共 11.5 MB）100% 提取自微软官方 **Windows 10 Enterprise LTSC 2021 ISO** (`033b7312`) 与微软官方 UUP **`Microsoft-Windows-EditionSpecific-Professional-Package.ESD`**，包含原版客户端 SPP 证书（`tokens\skus`、`pkeyconfig.xrm-ms`）、`Branding`、许可协议（`Licenses`）、`EditionMatrix.xml`、`OEMDefaultAssociations.xml` 以及 `enterprises-default` / `enterprise-default` SxS 清单中的原生客户端 `ProductPolicy`。
   - **官方打包工具**：构建引导 ISO 所用的 `oscdimg.exe` 在工作流运行时直接从微软官方 Windows ADK 安装包 CAB 实时提取。
2. **原生支持后续官方月度累积更新（LCU `.msu` / `.cab` 直装）**：
   - 镜像完整保留官方 Server 2022 的 CBS 组件树（`Microsoft-Windows-ServerStandardEdition`），未注入任何非官方自签名证书或第三方桥接包。装好系统后，未来每个月无需借助任何转换脚本，即可直接双击安装微软官方发布的 Windows Server 2022 月度累积更新包（LCU）。
3. **纯正桌面客户端体验（无服务器管理器、无强制密码复杂度限制、零预装冗余 UWP）**：
   - **彻底移除服务器管理器（Server Manager）**：从映像中移除了 `ServerManager.exe`、`ServerManagerLauncher.exe`、开机自启计划任务及开始菜单快捷方式，开机即纯正桌面。
   - **解除 Server 密码复杂度与无密码限制**：离线 `SYSTEM` 与 `SOFTWARE` 注册表已完整切换为 `ProductType = WinNT`、`InstallationType = Client` 与对应桌面 SKU 的官方 `ProductPolicy`。在首次开机引导（OOBE）或日常使用中，可直接创建**无密码本地账户**或简单密码，开机无需按 `Ctrl+Alt+Del`。
   - **纯净系统核心 UWP + 按需开启 Microsoft Store**：完整保留官方 27 个系统核心组件（开始菜单、搜索、Windows 安全中心 `SecHealthUI`、Windows Hello、输入法等）及经典秒开 Win32 工具（经典计算器 `calc.exe`、画图、截图工具），预装消费级膨胀 UWP 数量为 0。如需使用微软商店（Microsoft Store）及普通 UWP 应用，进入系统后执行 `wsreset -i` 即可由微软官方服务器自动下载安装。

---

## 工作原理 (`Patch-Official-Server2022-ISO.ps1`)

整个自动化构建过程仅需 **约 8 分钟**，分为 6 个阶段：

1. **工具链初始化 (`[1/6]`)**：通过 `winget` 安装 `aria2` 与 `wimlib-imagex`，并从微软官方 ADK CAB 提取签名版 `oscdimg.exe`。
2. **拉取并校验最新官方 Server 2022 ISO (`[2/6]`)**：解析 `ntriver.org` 最新月度 MDX 清单，通过 `aria2c` 16 线程高速下载当月官方 ISO 并校验 SHA-256。
3. **加载官方客户端资产与动态修补 `ProductPolicy` (`[3/6]`)**：加载 `OfficialClientFiles/` 中的官方客户端文件，解析 `enterprises-default.xml` 与 `enterprise-default.xml` 中的 166 项二进制策略，将 `Kernel-ProductInfo` 与 `Kernel-BrandingInfo` 精确修补为对应 SKU 值（`0x7D` / `0xBD` / `0x30` / `0x04`）。
4. **提取基础注册表与版本号 (`[4/6]`)**：使用 `wimlib-imagex` 从官方 ISO 的 `sources\install.wim` 索引 2（Server 2022 Desktop Experience）提取 `SYSTEM`、`SOFTWARE` 注册表配置单元并识别当前月度构建版本号（如 `10.0.20348.5761`）。
5. **流式合成 4 合 1 客户端 `install.wim` (`[5/6]`)**：
   - 将母盘索引 2 导出为新 `install.wim` 的索引 1，注入官方客户端文件覆盖层，删除 Server 专属授权目录与 `ServerManager` 组件；
   - 通过 `wimlib-imagex export` 在 WIM 内部零拷贝克隆出索引 2、3、4，并为每个索引独立构建并注入对应的客户端 `SYSTEM` / `SOFTWARE` 注册表配置单元与 WIM XML 映像属性（`EDITIONID`、`INSTALLATIONTYPE=Client`、`PRODUCTTYPE=WinNT`、`FLAGS`）。
6. **封装可引导客户端 ISO (`[6/6]`)**：写入通用零售/批量通道 `sources\ei.cfg`（支持安装界面自由选择 4 个版本），调用微软官方 `oscdimg.exe` 生成支持 BIOS + UEFI 双引导的最终 ISO。

---

## 下载与使用

1. **直接下载已构建镜像**：
   - 前往本仓库 [**Releases**](../../releases) 页面下载最新版本的分卷压缩包（`.iso.7z.001` ~ `.004`），使用 7-Zip 解压 `.001` 即可得到完整 `.iso` 镜像（解压后请对照 `SHA256SUMS.txt` 校验哈希）；
   - 或在 [**Actions**](../../actions) 最新成功运行的任务页面底部 **Artifacts** 区域，直接下载未分卷的单文件完整 ISO。
2. **自动与手动触发构建**：
   - **定时构建**：工作流 [`.github/workflows/auto_patch.yml`](./.github/workflows/auto_patch.yml) 在每月 15 日 `04:00 UTC` 自动运行并发布最新月度 Release。
   - **手动触发**：进入 **Actions -> Auto Patch Official Windows Server 2022 ISO to 20348 Client -> Run workflow** 即可随时触发云端构建。
3. **本地运行构建**：
   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\Patch-Official-Server2022-ISO.ps1 -WorkDir "D:\work_20348" -OutputDir "D:\out_iso"
   ```
