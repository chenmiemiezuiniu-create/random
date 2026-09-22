/// 全局常量。
///
/// 发新版本时，这里和 pubspec.yaml 的 version 都要改，
/// 否则 GitHub 更新检测会判断错误。
const String kAppName = '随机抽人';

/// 当前程序版本，与 GitHub Release 的 tag（可带 v 前缀）比较。
const String kAppVersion = '1.0.1';

/// 默认的更新分支（用 version.json 兜底方案时才会用到）。
const String kDefaultBranch = 'main';

/// 用户数据文件夹名（与可执行文件同级）。
///
/// 注意：**不能叫 `data`**。Flutter 打包出来的 Windows 产物里已经有一个
/// `data/` 目录存放 flutter_assets、icudtl.dat 等运行时资源，
/// 用户名单混进去会在覆盖更新时被牵连。
const String kDataFolderName = 'RandomPickerData';
