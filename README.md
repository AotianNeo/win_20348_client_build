# Windows 10 (Build 20348 / Iron `fe_release`) Client Automated Official ISO Builder

本仓库提供一套全自动 GitHub Actions 构建方案：每月自动拉取微软官方最新发布的 **Windows Server 2022 月度更新版 ISO (`Build 20348.xxxx`)**，完整注入 **20348 客户端专属 CBS 组件包 (`WinSxS` + `servicing\Packages`)、71 个桌面专属硬件驱动（笔记本 I2C/GPIO 精确式触摸板驱动、蓝牙音频 A2DP/AVRCP/HFP 驱动、44 款无线网卡驱动、Xbox 手柄驱动）、99 项客户端系统服务**，并**默认开启 `.NET Framework 3.5 (NetFx3)`**，生成开箱即用的 **Windows 10 (Build 20348) 桌面客户端 4 合 1 ISO**。

---

## 包含版本 (`sources\install.wim`)

所有 4 个版本采用 WIM 单实例流共享（Single-Instancing），极大减小多版本镜像体积：

| 索引 (Index) | Edition ID | 版本名称 | `ProductInfo` SKU | 激活与支持特性 |
| :---: | :--- | :--- | :---: | :--- |
| **1** | `EnterpriseS` | **Windows 10 企业版 LTSC 2021** | `0x7D` (`125`) | 完整注入 `EnterpriseSEdition` CBS 组件树，支持 KMS / 数字权利激活 |
| **2** | `IoTEnterpriseS` | **Windows 10 IoT 企业版 LTSC 2021** | `0xBD` (`189`) | 支持 HWID 数字权利永久激活（支持周期至 2032 年） |
| **3** | `Professional` | **Windows 10 专业版** | `0x30` (`48`) | 完整注入 `ProfessionalEdition` 专属额外组件与策略，支持 KMS / 数字权利激活 |
| **4** | `Enterprise` | **Windows 10 企业版** | `0x04` (`4`) | 完整企业版组件与策略，支持 KMS / 数字权利激活 |

---

## 核心特性与技术亮点

### 1. 完整注入 20348 客户端硬件驱动库（彻底解决笔记本触摸板与蓝牙耳机无声问题）
原版 Windows Server 2022 默认裁剪了大量桌面客户端外设驱动。本构建方案将 **71 个官方 Client 专属 `DriverStore\FileRepository` 驱动包（共 4,329 条硬件设备 ID 映射）** 完整注入文件树，并精准注册到离线 **`DRIVERS\DriverDatabase`** 与 **`SYSTEM\DriverDatabase` + `SYSTEM\ControlSet001\Services`**：

- **12 个笔记本精确式触摸板（Precision Touchpad）I2C / GPIO 串行总线控制器驱动**（注册于 `SYSTEM\DriverDatabase` 及内核服务）：
  - **Intel Serial IO I2C / GPIO**：`iai2c.inf` (`iaLPSS2_I2C.sys`)、`iagpio.inf` (`iaLPSS2_GPIO2.sys`)、`ialpss2i_i2c_skl.inf`、`ialpss2i_i2c_cnl.inf`、`ialpss2i_i2c_glk.inf`、`ialpss2i_i2c_bxt_p.inf`、`ialpss2i_gpio2_skl.inf`、`ialpss2i_gpio2_cnl.inf`、`ialpss2i_gpio2_glk.inf`、`ialpss2i_gpio2_bxt_p.inf`
  - **AMD I2C / GPIO**：`amdi2c.inf` (`amdi2c.sys`)、`amdgpio2.inf` (`amdgpio2.sys`)
- **7 个蓝牙音频与耳机麦克风免提协议栈驱动 + 蓝牙音频服务组**（注册于 `DRIVERS\DriverDatabase`、`SYSTEM\DriverDatabase` 及 `Svchost\BthAppGroup`）：
  - **A2DP 高清立体声音频接收/发送**：`microsoft_bluetooth_a2dp.inf` (`BthA2dp.sys`)、`microsoft_bluetooth_a2dp_snk.inf`、`microsoft_bluetooth_a2dp_src.inf`
  - **AVRCP 蓝牙媒体播放控制**：`microsoft_bluetooth_avrcptransport.inf` (`Microsoft.Bluetooth.AvrcpTransport.sys`)
  - **HFP 蓝牙双向通话免提与音频网关**：`microsoft_bluetooth_hfp.inf` (`BthHfAud.sys`, `BthHfEnum.sys`)、`microsoft_bluetooth_hfp_ag.inf`、`microsoft_bluetooth_hfp_hf.inf`
  - **蓝牙用户态后台服务**：完整注册 `BTAGService` (`btagservice.dll`)、`BthAvctpSvc` (`bthavctpsvc.dll`)、`BluetoothUserService` (`Microsoft.Bluetooth.UserService.dll`) 与 `BthAppGroup` 服务宿主组。
- **44 个桌面级无线网卡（Wi-Fi）与 4 个 Xbox 外设驱动**：
  - 涵盖 Intel (`netwtw02/04/06/08.inf`)、Realtek (`netrtwlane*.inf`, `rtwlanu.inf`)、Qualcomm Atheros (`athw8x.inf`, `netathrx.inf`)、Broadcom (`bcmdhd64.inf`, `bcMWL63a.inf`)、Marvell 等主流无线网卡开箱即用支持；
  - 涵盖 `xboxgip.inf`、`xinputhid.inf`、`xusb22.inf`、`dc1-controller.inf` 等 Xbox 无线/有线控制器驱动。

### 2. 完整注入 581 个客户端 CBS 组件包 (`WinSxS` + `servicing\Packages`)
- 将 `ClientPayload_20348.esd` 中的 **10,099 个客户端专属文件**（包括 `WinSxS` 组件目录、`servicing\Packages\*.mum / *.cat`、`System32`、`SysWOW64`、`SystemApps`）与 **581 项客户端 CBS 注册表项**（`ClientCbsAndSvchost_Base_SOFTWARE.reg` + `ClientCbs_ProExtra_SOFTWARE.reg`）完整合入离线映像，并移除 `ServerStandardEdition` 包注册项，实现与桌面 Client 架构一致的组件栈。

### 3. 默认开启 `.NET Framework 3.5 (NetFx3)`
- 构建过程中在导出基础母盘后，直接挂载映像并通过 `dism.exe /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess` 调用官方 Server 2022 ISO 内置的 `sources\sxs\microsoft-windows-netfx3-ondemand-package~31bf3856ad364e35~amd64~~.cab`（含简体中文语言包）原生开启 `.NET Framework 3.5`（含 `.NET 2.0 / 3.0`），装机后即刻可用，无需联网二次安装。

### 4. 纯正桌面客户端体验
- **彻底移除服务器管理器（Server Manager）**：移除 `ServerManager.exe`、`ServerManagerLauncher.exe`、开机自启计划任务及开始菜单快捷方式。
- **解除 Server 密码复杂度与无密码限制**：离线 `SYSTEM` 与 `SOFTWARE` 注册表已完整切换为 `ProductType = WinNT`、`InstallationType = Client` 与对应桌面 SKU 的官方 `ProductPolicy`。在首次开机引导（OOBE）或日常使用中，可直接创建**无密码本地账户**或简单密码，开机无需按 `Ctrl+Alt+Del`。
- **纯净系统核心 UWP + 按需开启 Microsoft Store**：完整保留官方 27 个系统核心组件（开始菜单、搜索、Windows 安全中心 `SecHealthUI`、Windows Hello、输入法等）及经典秒开 Win32 工具（经典计算器 `calc.exe`、画图、截图工具），预装消费级膨胀 UWP 数量为 0。如需使用微软商店（Microsoft Store），进入系统后执行 `wsreset -i` 即可由微软官方服务器自动下载安装。

---

## 工作原理 (`Patch-Official-Server2022-ISO.ps1`)

整个自动化构建过程分为 6 个阶段：

1. **工具链初始化 (`[0/6]` - `[1/6]`)**：自动配置 `aria2c`、`wimlib-imagex`、`7z`，并从微软官方 ADK CAB 提取签名版 `oscdimg.exe`，编译内联 C# `ProductPolicy` SKU 修补器。
2. **拉取并校验最新官方 Server 2022 ISO (`[2/6]`)**：解析 `ntriver.org` 最新月度 MDX 清单，通过 `aria2c` 16 线程高速下载当月官方 ISO 并强制校验 SHA-256。
3. **加载客户端组件载荷与离线注册表补丁 (`[3/6]`)**：加载 `OfficialClientFiles/` 中的官方客户端授权/品牌文件与 4 份离线注册表包（`ClientDrivers_DRIVERS.reg`、`ClientDriversAndServices_SYSTEM.reg`、`ClientCbsAndSvchost_Base_SOFTWARE.reg`、`ClientCbs_ProExtra_SOFTWARE.reg`），并拉取解压 `ClientPayload_20348.esd` 双层载荷（`EnterpriseS` 基础载荷 + `Professional/Enterprise` 扩展载荷）。
4. **原生开启 `.NET Framework 3.5` 并更新基础 `DRIVERS` / `SYSTEM` 配置单元 (`[4/6]`)**：
   - 将官方母盘索引 2（Server 2022 Desktop Experience）导出为新 `install.wim` 索引 1；
   - 使用 `dism.exe` 挂载索引 1 并从 `sources\sxs` 原生启用 `NetFx3`；
   - 提取 `DRIVERS`、`SYSTEM`、`SOFTWARE` 配置单元，将 71 个客户端驱动与 99 项服务一次性导入基础 `DRIVERS` 与 `SYSTEM` 配置单元。
5. **流式合成 4 合 1 客户端 `install.wim` (`[5/6]`)**：
   - 向索引 1 注入 `EnterpriseS` 客户端文件载荷、`OfficialClientFiles` 覆盖层与更新后的 `DRIVERS` 配置单元，清理 Server 专属 SKU 证书与 `ServerManager`；
   - 通过 `wimlib-imagex export` 零拷贝克隆出索引 2（`IoTEnterpriseS`）与索引 3（`Professional`），向索引 3 注入 `Pro_Extra` 扩展客户端文件载荷后再零拷贝克隆出索引 4（`Enterprise`）；
   - 为 4 个版本分别合成注入含客户端 CBS 组件树与对应 `ProductPolicy` SKU（`0x7D` / `0xBD` / `0x30` / `0x04`）的 `SYSTEM` 与 `SOFTWARE` 注册表配置单元。
6. **封装可引导客户端 ISO (`[6/6]`)**：写入通用通道 `sources\ei.cfg`，调用微软官方 `oscdimg.exe` 生成支持 BIOS + UEFI 双引导的最终 ISO。

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
