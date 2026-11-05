# Windows Build 20348 Client (`fe_release`) Automated Monthly ISO Builder

参考 [`adavak/win_iso_build`](https://github.com/adavak/win_iso_build) 与 [`adavak/Win_ISO_Patching_Scripts`](https://github.com/adavak/Win_ISO_Patching_Scripts)，通过 GitHub Actions 每月自动拉取微软官方 Windows Server 2022 (`Build 20348`) 最新累积更新（LCU / SSU / .NET 4.8.1 / SafeOS DU），在云端自动完成 **Server LCU -> Client LCU 转换与自签名证书注入**，生成集成最新月度安全补丁的 `20348 Client` 4 合 1 镜像。

---

## 包含版本 (`sources\install.wim`)

| 索引 (Index) | Edition ID | 版本名称 | 激活与支持特性 |
| :--- | :--- | :--- | :--- |
| **1** | `EnterpriseS` | **Windows 10 企业版 LTSC** | 支持 KMS (2021 密钥) / 数字权利激活 |
| **2** | `IoTEnterpriseS` | **Windows 10 IoT 企业版 LTSC** | 支持 HWID 数字权利永久激活（至 2032 年） |
| **3** | `Professional` | **Windows 10 专业版** | 完整桌面体验 + Microsoft Store |
| **4** | `Enterprise` | **Windows 10 企业版** | 完整企业版桌面特性 |

---

## 工作原理：为什么原版 Server 2022 LCU 能无损打入 20348 Client？

微软每月只发布适用于 `ServerDatacenter` / `ServerStandard` / `ServerTurbine` 的 `Build 20348` 累积更新包（LCU）。如果直接对转换后的 Client 镜像执行 `dism /Add-Package`，CBS 会因为找不到 `Microsoft-Windows-*Edition` 依赖链而报错 `0x800f081e (CBS_E_NOT_APPLICABLE)`。

本仓库通过 [`Inject-20348-Client-LCU.ps1`](./Inject-20348-Client-LCU.ps1) 与 [`ClientTemplates/`](./ClientTemplates) 在 `W10UI.cmd` 挂载映像后、安装 LCU 前自动完成以下 5 步转换：

1. **提取并重算 WCP SxS 字典压缩与 64 位清单哈希**：
   - 自动调用离线映像 `wcp.dll` 内的原生 `DeltaDecompressBuffer` 解压 LCU 中的二进制 DCM v1 `.manifest`；
   - 实现与 `wcp.dll` (`0x1ec34` / `0x1f680`) 100% 一致的 64 位 SxS 哈希算法 (`h = h * 65599 + c`)，自动重算所有被本次 LCU 更新过的组件并合成新版本号的 Client 专属 `*-deployment.manifest`。
2. **自底向上重构 316 个 Client 专属 `.mum` 包树**：
   - 将 [`ClientTemplates/Packages`](./ClientTemplates/Packages) 中的语言包、客户端特性包、`EditionPack`、`Client-Desktop-Required` 以及 `EnterpriseSEdition` / `IoTEnterpriseSEdition` / `ProfessionalEdition` / `EnterpriseEdition` 等 316 个 `.mum` 升级为当月 LCU 的最新版本号（例如 `20348.xxxx.1.x`）。
3. **双层自签名根证书生成与离线注册表注入**：
   - 动态生成 4096 位 Root CA 与代码签名子证书，将 Root CA 写入离线映像注册表 `HKLM\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates\<Thumbprint>`；
   - 使用 `New-FileCatalog` + `Set-AuthenticodeSignature` 为所有新合成的 Client `.mum` / `.manifest` 生成具有合法签名链的 `.cat` 安全编录，并对基底映像内的全部自定义 `.cat` 重新签名。
4. **无损注入 `update.mum` 顶层包装器 (`*-Wrapper`)**：
   - 微软官方 LCU 的 `update.cat` 仅校验子包而不包含 `update.mum` 本身的哈希；脚本将 17 个客户端版本 Wrapper 追加到 `update.mum` 并复用 `update.cat`，从而让 `DISM /Add-Package` 原生识别并同时更新所有 Server 与 Client 组件。
5. **通过 `Patch-W10UI.ps1` 自动挂钩 `W10UI.cmd`**：
   - 在 `W10UI.cmd` 执行 `call :addlcu DismLCU` 前自动触发上述合成与离线授信流程，并保持 `ResetBase=0` 以确保未来每个月均可继续无损叠加更新。

---

## 使用方式

1. **自动构建**：工作流 [`.github/workflows/auto_patch.yml`](./.github/workflows/auto_patch.yml) 会在**每月第二个星期三 18:00 UTC**（微软补丁日次日）自动运行，并将构建完成的最新 ISO 分卷发布到 [Releases](../../releases)。
2. **手动触发**：进入本仓库的 **Actions -> Auto Patch Windows 20348 Client ISO -> Run workflow** 即可随时手动触发构建。
