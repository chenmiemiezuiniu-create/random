# 随机抽人 (Random Picker)

便携式随机抽取工具。Windows 优先，同一套代码后续可直接打包安卓。

## 功能

| 需求 | 实现 |
| --- | --- |
| 数据便携、零残留 | 所有数据写在**可执行文件同级的 `RandomPickerData/` 目录**，绝不写 C 盘用户目录。删掉整个文件夹 = 什么都不剩 |
| 名单导入/输入 | 支持 `.txt`（一行一个名字）、`.json`，也可在界面里新建名单直接输入/粘贴，还能设置权重 |
| 不重复抽取 | 抽中的人本轮不再出现，抽完为止；也可随时手动「开始新一轮」 |
| 可重复抽取 | 放回抽取，每次都在完整名单里随机 |
| 一次抽多个 / 一次抽一个 | 人数输入框 + 1/2/3/5/全部 快捷按钮 |
| 界面 + 无登录 | Flutter 桌面 GUI，打开即用 |
| GitHub 版本更新检测 | 读 `releases/latest`，弹窗提示并提供下载直链；没发 Release 时退回读 `version.json` |

## 数据文件

全部位于程序旁边的 `RandomPickerData/` 文件夹：

| 文件 | 内容 |
| --- | --- |
| `config.json` | 设置：模式、人数、GitHub 仓库、开关项 |
| `lists.json` | 所有名单及其中的人（含权重） |
| `state.json` | 不重复模式「已被抽走的人」；池子由名单减去它现算，所以加人不会让已抽的人复活 |
| `history.json` | 最近 500 条抽取记录 |

## 名单格式

**txt** —— 一行一个名字，`#` 开头的行忽略：

```
张三
李四
王五,3      ← 权重 3，被抽中的概率是普通人的 3 倍
赵六,0      ← 权重 0 == 本轮不参与抽取（不会被抽到，也不占池子）
```

> txt 必须是 **UTF-8** 编码。老的 GBK 文件请先用记事本「另存为」→ 编码选 UTF-8。

**json** —— 支持这三种写法：

```json
["张三", "李四", "王五"]
```
```json
{ "name": "三班", "people": ["张三", { "name": "李四", "weight": 2 }] }
```
```json
{ "listName": "三班", "names": [{ "name": "张三", "weight": 1, "note": "班长" }] }
```

## 构建（Windows）

### 重要：分两阶段，别傻等

Flutter 的验证和打包需要的东西**不一样**：

| 命令 | 需要 Flutter SDK | 需要 Visual Studio |
| --- | --- | --- |
| `flutter pub get` | ✅ | ❌ |
| `flutter analyze`（静态检查） | ✅ | ❌ |
| `flutter test`（跑单元测试） | ✅ | ❌ |
| `flutter build windows`（出 exe） | ✅ | ✅ **必须要** |

所以正确顺序是：

1. **先装 Flutter SDK**（约 1GB，十几分钟）→ 立刻就能 `analyze` + `test`，
   把代码错误全部暴露出来，不用干等 6~8GB 的 Visual Studio 下完。
2. Visual Studio 可以同时后台下载。

### 阶段一：Flutter SDK

去 [docs.flutter.dev/get-started/install/windows](https://docs.flutter.dev/get-started/install/windows)
下载 Stable 版 zip，解压到**没有中文、没有空格、不需要管理员权限**的路径（例如 `D:\dev\flutter`），
把 `D:\dev\flutter\bin` 加进系统环境变量 `Path`，然后新开终端：

```powershell
flutter doctor
flutter pub get
flutter analyze
flutter test
```

### 阶段二：Visual Studio 2022（只为出 exe）

需要勾选的工作负载只有一个：**使用 C++ 的桌面开发**（Desktop development with C++）。

机器上如果已经有 Visual Studio Installer（`C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe`），
可以直接命令行装：

```powershell
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" install `
  --add Microsoft.VisualStudio.Workload.NativeDesktop `
  --includeRecommended --passive --norestart
```

> 只想装编译器、不要 IDE 的话，改用 Build Tools（体积更小）：
> 下载 <https://aka.ms/vs/17/release/vs_BuildTools.exe>，然后
> `vs_BuildTools.exe --quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`

### 一键构建

```powershell
pwsh -File tools\build_windows.ps1
```

它会自动补平台脚手架 + 改中文窗口标题 + 检查 + 测试 + 打包。

### ⚠️ 踩坑记录：开发者模式 / 符号链接

首次 `flutter build windows` 很可能会报：

```
Building with plugins requires symlink support.
Please enable Developer Mode in your system settings.
```

原因是 Flutter 要给每个插件建符号链接，而 Windows 上建符号链接需要「开发者模式」或管理员权限，
否则底层抛 `ERROR_PRIVILEGE_NOT_HELD (1314)`。

三个办法，任选其一：

1. **开启开发者模式**（推荐，长期开发也需要）：
   `start ms-settings:developers` → 打开「开发人员模式」。
2. **用管理员身份运行终端**再打包。
3. **用目录联接（junction）绕过** —— 不需要任何权限。
   `tools\build_windows.ps1` 已经自动做了这件事。原理是
   `flutter_tools/lib/src/flutter_plugins.dart` 里对每个插件先判断：

   ```dart
   if (link.existsSync()) { continue; }   // 链接已存在就跳过创建
   ```

   junction 不需要管理员权限，而 Dart 的 `Link.existsSync()` 对 junction 返回 `true`，
   所以预先用 `mklink /J` 建好链接，Flutter 就会直接跳过，永远不会去建符号链接。

> 只有 `flutter build` 和 `flutter run` 需要这个；`flutter analyze` 和 `flutter test` 完全不受影响。

### 手动步骤

```powershell
flutter doctor          # 确认 Windows toolchain 是绿勾
flutter pub get
flutter analyze         # 静态检查
flutter test            # 单元测试（抽取算法 / 导入解析 / 版本比较）
flutter build windows --release
```

产物在：

```
build\windows\x64\runner\Release\
```

> 注意：**用户数据目录不能叫 `data`** —— Flutter 的 Windows 产物里已经有一个 `data/`
> 存放 `flutter_assets` / `icudtl.dat` 等运行时资源，用户名单混进去会在覆盖更新时被牵连。
> 所以本项目用的是 `RandomPickerData/`。

把这个目录里的所有东西一起发给用户即可。首次运行会在 `random_picker.exe` 旁边自动创建 `RandomPickerData\`。

开发时直接跑：

```powershell
flutter run -d windows
```

> 注意：`flutter run` 调试时，数据会落在 `build\windows\x64\runner\Debug\RandomPickerData\` 里；
> 发布版才会落在 exe 旁边。这是刻意设计 —— 数据永远跟着可执行文件走。

## 已验证的构建环境

本项目已在以下环境**实际构建并运行通过**：

| 项目 | 版本 |
| --- | --- |
| Flutter | 3.47.5 (stable, revision 6a19cca564) |
| Dart | 3.13.4 |
| Visual Studio | **Community 2026 (18.10.1)** — 比文档里常说的 2022 更新，实测可用 |
| MSVC | 14.44.35207 / 14.51.36231 |
| Windows SDK | 10.0.26100.0 |

验证结果：

- `flutter analyze` → **No issues found!**
- `flutter test` → **65 个测试全部通过**（46 个逻辑 + 19 个界面）
  - 逻辑层：抽取算法、池子推导、权重、txt/json 解析、版本号比较、
    发布附件选择、序列化往返
  - 界面层：真实 widget 树里模拟点击，验证「开始抽取」出结果、一次抽多人、
    连抽到本轮结束并弹出「本轮已抽完」、切模式、改人数、编辑名单保存、
    清空名单被拦下、开始新一轮重置、各对话框可打开
  - 响应式：**900×600 到 1400×900 共 6 种窗口尺寸均无布局溢出**，
    且窄窗口下主按钮仍可点击
- `dart run tools/verify_updater.dart` → **21 项全过**，包含真实 GitHub API 调用
- `flutter build windows --release` → 成功
- 实际启动 exe → 正常运行，自动在 exe 旁创建 `RandomPickerData\`
- 运行期间 `%APPDATA%` **无任何文件被创建或修改** → 零残留成立
- 中文名字在 `lists.json` 里以 **UTF-8** 正确落盘（用记事本打开也不会乱码）

分发包约 **11.4 MB**，解压后结构：

```
random_picker\
  random_picker.exe                       0.09 MB   ← 双击这个
  flutter_windows.dll                    20.29 MB
  dartjni.dll / file_selector_windows_plugin.dll / url_launcher_windows_plugin.dll
  data\                                  ← Flutter 运行时资源，别删
    app.so / icudtl.dat / flutter_assets\
```

（打 zip 时**不要**把 `RandomPickerData\` 打进去，那是用户数据。）

## 发布更新（GitHub）

1. 建一个 **Public** 仓库。
2. 改 `lib/core/constants.dart` 里的 `kAppVersion` 和 `pubspec.yaml` 的 `version`。
3. 重新 `flutter build windows --release`。
4. 仓库页面 → Releases → *Draft a new release* → Tag 填 `v1.0.1`（要比当前版本大）→ 把新 exe 压缩包拖进附件 → **Publish release**。
5. 程序里「设置 → GitHub 仓库」填 `用户名/仓库名`，之后启动会自动检查更新。

不想发 Release 也行：在仓库根目录放一个 `version.json`：

```json
{ "version": "1.0.1", "notes": "修复了 xxx", "download": "https://.../random_picker.zip" }
```

## 安卓

```powershell
flutter create --platforms=android .
flutter build apk --release
```

安卓端数据放在应用私有目录（系统卸载时自动清除，同样零残留）—— 见 `lib/core/paths.dart`。
注意：Windows 上产出的是**一个文件夹**（`random_picker.exe` + DLL + `data/`），
Flutter 做不出真正的单文件 exe。分发时把整个 Release 文件夹打包成 zip 即可；
确实想要单文件，可以再用 Enigma Virtual Box 之类工具封装。

## 代码结构

```
lib/
  main.dart                      入口，主题
  core/
    constants.dart               应用名与版本号
    models.dart                  Person / NameList / AppConfig / DrawRecord
    paths.dart                   便携数据目录（便携策略都在这）
    store.dart                   状态 + 抽取算法 + JSON 持久化
    importer.dart                txt / json 导入解析
    updater.dart                 GitHub 版本检测与版本号比较
  ui/
    home_page.dart               主界面
    list_editor_dialog.dart      名单编辑器
    settings_dialog.dart         设置
    update_dialog.dart           发现新版本弹窗
test/
  logic_test.dart                46 个逻辑单元测试（真实 I/O）
  widget_test.dart               19 个界面测试（模拟点击 + 响应式布局）
tools/
  build_windows.ps1              一键构建
  verify_algorithm.py            算法验证镜像（见下）
  verify_updater.dart            更新检测的联网验证（见下）
```

## 关于 tools/verify_algorithm.py

`lib/core/store.dart` 里的核心算法（池子推导、权重抽取、两种模式的批量抽取）
在 `tools/verify_algorithm.py` 里有一份**逐行对应的 Python 镜像**，跑的是同一批断言。

用途：在 Flutter 环境就绪之前，先用能立刻运行的 Python 验证**算法语义**是否正确。
它已经抓到过一个真实错误（测试里构造名单时多删了一个人，期望值和实际语义对不上）。

```powershell
python tools\verify_algorithm.py
```

它验证的是算法，**不是 Dart 语法**。等 Flutter 装好后跑 `flutter test`，
两边结论必须一致；不一致就说明 Python 镜像和 Dart 实现发生了偏离，需要查。

## 关于 tools/verify_updater.dart

更新检测是**唯一会对外发起网络请求**的功能，单元测试没法覆盖真实链路。
`tools/verify_updater.dart` 会打真实的 GitHub API 做端到端验证：

```powershell
dart run tools\verify_updater.dart
```

它验证：

- `normalizeRepo` 能把 `用户名/仓库名`、完整网址、`.git` 后缀、
  粘贴错的子页面地址、ssh 写法都归一成 `owner/repo`
- `compareVersions` 按数字而非字符串比较（`1.10.0 > 1.9.0`）
- 真实仓库能拿到版本号 / 更新说明 / 下载直链 / 发布页地址
- **不会误挑 arm64 的包**（见下）
- 没有发布附件的仓库不会崩，`downloadUrl` 为 null
- 不存在的仓库抛可读的 `UpdateException`，而不是崩溃
- 还没配置仓库时给出「去设置里填」的引导

之所以不放进 `test/`：它会真的联网、会消耗 GitHub 未认证配额（60 次/小时），
放进测试套件会让 `flutter test` 依赖网络。

### 踩坑记录：Release 附件的架构选择

第一次跑联网验证时，`microsoft/PowerToys` 挑中的是：

```
PowerToysSetup-0.101.2362.0-arm64.exe     ← arm64！
```

原因是旧实现只取「第一个名字匹配后缀的附件」，而 PowerToys 的 JSON 里 arm64 排在
x64 前面 —— 在 x64 机器上会把 arm64 的包装下来。现在 `pickAssetUrl` 的选择顺序是：

1. 后缀匹配 **且** 名字看起来是 Windows x64（含 `x64`/`amd64`/`win`，且不含 `arm`/`aarch`）
2. 只要求后缀匹配
3. 兜底取第一个附件

这条规则同时有**离线单元测试**（`test/logic_test.dart` 里的 `pickAssetUrl` 分组）
和**联网回归检查**两份覆盖。

> 顺带一提：本项目分发的是 **zip**，所以 `checkForUpdate` 的 `assetSuffix`
> 默认是空字符串（不限后缀）。如果你的 Release 里同时挂了源码包和 Windows 包，
> 建议把附件名取得明确些，例如 `random_picker_v1.0.1_windows_x64.zip`。
