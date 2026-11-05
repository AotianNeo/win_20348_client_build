# Windows 20348 (Iron / Fe) Client Automated Official ISO Patcher

本仓库提供一套 **100% 纯微软官方源文件（零任何第三方修改文件）** 的全自动 GitHub Actions 构建方案，每月自动拉取微软官方最新发布的 **Windows Server 2022 月度更新版 ISO (`Build 20348.xxxx`)**，并将其无损转换为完整的 **Windows 10 (Build 20348) 桌面客户端多合一 ISO**。

## 核心特性与零第三方文件架构

本仓库不包含任何预打包二进制文件或第三方修改模板，所有输入均在构建时实时从微软官方镜像与微软官方更新服务器拉取并校验哈希：

1. **最新月度基线底座 (`20348.xxxx`)**：
   - 自动解析并从 [NTRiver (Windows Server 2022 Official MSDN/MVS ISOs)](https://ntriver.org/download-windows-server-2022) 下载微软每月最新发布的官方简体中文 Windows Server 2022 完整版 ISO（如 `zh-cn_windows_server_2022_updated_oct_2026_x64_dvd_3fc7f935.iso`），强制校验官方 SHA-256 哈希。
2. **官方 LTSC 客户端授权、策略与品牌资源（HTTP Range 稀疏流提取）**：
   - 通过内置 C# `OfficialIsoHelper` 针对 [NTRiver 官方 Windows 10 Enterprise LTSC 2021 ISO](https://ntriver.org/download-windows-ltsc) (`zh-cn_windows_10_enterprise_ltsc_2021_x64_dvd_033b7312.iso`) 发起约 12 次 HTTP Range 字节范围请求（仅传输 ~1.5 MB 数据，耗时 `<10 秒`，无需下载整张 4.7 GB ISO），直接从官方 WIM 精确提取 `EnterpriseS` / `IoTEnterpriseS` 的 SPP 证书、客户端 `pkeyconfig`、`Branding`、`EditionMatrix.xml` 以及 `enterprises-default` SxS 清单中的原生 `ProductPolicy`。
3. **官方专业版 / 企业版客户端资源（微软官方 UUP 直连）**：
   - 通过 UUP API 从微软官方 `download.windowsupdate.com` 下载 `Microsoft-Windows-EditionSpecific-Professional-Package.ESD`（17 MB），提取 `Professional` / `Enterprise` 等版本的官方 SPP 证书、`Edition.xml` 与 `enterprise-default` 原生 `ProductPolicy`。
4. **CBS 顶层产品包切换与四合一客户端映像合成**：
   - 挂载官方 Server 2022 ISO 的 Index 2（带桌面体验的 `ServerStandard`），通过离线 CBS 根证书注入将顶层 Product Package 切换为 `Microsoft-Windows-EnterpriseSEdition` 与 `Microsoft-Windows-ProfessionalEdition`，写入 `ProductType=WinNT` 及对应 SKU 的官方 `ProductPolicy`，自动禁用 `ServerManager` 随登录自启，最终导出包含以下 4 个桌面版本的标准客户端 `install.wim` 并封装可引导 ISO：
     1. **Windows 10 企业版 LTSC 2021 (`EnterpriseS`)**
     2. **Windows 10 IoT 企业版 LTSC 2021 (`IoTEnterpriseS`)**
     3. **Windows 10 专业版 (`Professional`)**
     4. **Windows 10 企业版 (`Enterprise`)**
