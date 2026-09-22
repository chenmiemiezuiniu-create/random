<#
    一键构建 Windows 发布版。

    ⚠️ 本文件必须保存为「UTF-8 with BOM」。
    Windows PowerShell 5.1 在没有 BOM 时会按系统 ANSI（中文机器上是 GBK）
    解析 .ps1，中文注释和字符串会全部乱码并直接抛出语法错误
    （Unexpected token / Missing closing '}'）。PowerShell 7 不受影响，
    但大多数人用的是随 Windows 自带的 5.1。

    不小心存成无 BOM 时，用这两行修回来（$p 换成本文件路径）：
        $c = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($p, $c, (New-Object Text.UTF8Encoding($true)))

    用法（在项目根目录）：
        .\tools\build_windows.ps1           # Windows PowerShell 5.1
        pwsh -File tools\build_windows.ps1  # 装了 PowerShell 7 的话

    它会依次做：
        1. flutter doctor          —— 只打印，不因为安卓工具链缺失而中断
        2. 补齐平台脚手架（已存在则跳过，绝不覆盖定制过的 runner）
        3. 定制 Windows runner：生成六点骰子图标 + 中文窗口标题
        4. pub get -> analyze -> test
        5. 确保插件链接可用（开发者模式未开启时用 junction 绕过）
        6. build windows --release
#>

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

function Invoke-Checked {
    param([string]$Label, [scriptblock]$Action)
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Label 失败（退出码 $LASTEXITCODE）"
    }
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "找不到 flutter 命令。请先安装 Flutter SDK，并把 <flutter安装目录>\bin 加进 PATH，然后重开一个终端。"
}

Write-Host '== 1/6 flutter doctor ==' -ForegroundColor Cyan
flutter doctor
Write-Host '(doctor 有红叉也没关系，只要 Flutter 和 Visual Studio 两行是绿勾即可)' -ForegroundColor DarkGray
Write-Host ''

Write-Host '== 2/6 补齐平台脚手架 ==' -ForegroundColor Cyan
# 平台目录一旦存在就绝不动它：里面已经包含我们定制过的 runner（骰子图标、
# 中文标题），而且它们是要提交进 git 的。每次重建会把改动冲刷掉。
$needScaffold = -not ((Test-Path (Join-Path $projectRoot 'windows')) -and
                      (Test-Path (Join-Path $projectRoot 'android')))
if (-not $needScaffold) {
    Write-Host '  windows/ 与 android/ 已存在，跳过（不会覆盖你的定制）'
}
else {
    $scaffold = Join-Path $env:TEMP ("rp_scaffold_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scaffold | Out-Null
    try {
        Invoke-Checked '生成脚手架' {
            flutter create --platforms=windows,android --project-name random_picker $scaffold
        }
        foreach ($item in @('windows', 'android', '.metadata')) {
            $src = Join-Path $scaffold $item
            if (-not (Test-Path $src)) { continue }
            $dst = Join-Path $projectRoot $item
            if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
            Copy-Item $src $dst -Recurse -Force
            Write-Host "  已复制 $item"
        }
        # 注意：刻意不复制脚手架生成的 analysis_options.yaml。
        # 它 include 了 package:flutter_lints，而我们的 pubspec 里没有这个包，
        # 复制过来会让 flutter analyze 直接报 URI 不存在的错。
        # 项目根目录已有一份不依赖外部包的配置。
    }
    finally {
        Remove-Item $scaffold -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host ''

Write-Host '== 3/6 定制 Windows runner（骰子图标 + 中文窗口标题） ==' -ForegroundColor Cyan

# 骰子图标：脚手架刚覆盖了 windows/，必须重新生成，否则图标会被还原成 Flutter 默认的。
# tools/make_icon.py 用标准库手写 PNG + ICO，不依赖 Pillow。
$iconScript = Join-Path $projectRoot 'tools\make_icon.py'
$iconPath = Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'
if ((Test-Path $iconScript) -and (Get-Command python -ErrorAction SilentlyContinue)) {
    & python $iconScript $iconPath
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  已生成六点骰子图标 app_icon.ico'
    }
    else {
        Write-Host '  图标生成失败，沿用现有 app_icon.ico' -ForegroundColor Yellow
    }
}
else {
    Write-Host '  跳过图标生成：找不到 python 或 tools\make_icon.py' -ForegroundColor Yellow
}

$mainCpp = Join-Path $projectRoot 'windows\runner\main.cpp'
if (Test-Path $mainCpp) {
    $text = Get-Content $mainCpp -Raw -Encoding UTF8
    # L"\u968F\u673A\u62BD\u4EBA" == L"随机抽人"
    $patched = $text -replace 'window\.Create\(L"[^"]*"', 'window.Create(L"\u968F\u673A\u62BD\u4EBA"'
    if ($patched -ne $text) {
        Set-Content -Path $mainCpp -Value $patched -Encoding UTF8 -NoNewline
        Write-Host '  窗口标题已改为「随机抽人」'
    }
    else {
        Write-Host '  没有匹配到 window.Create，跳过（可能 Flutter 模板变了）' -ForegroundColor Yellow
    }
}
else {
    Write-Host '  找不到 windows\runner\main.cpp，跳过' -ForegroundColor Yellow
}
Write-Host ''

Write-Host '== 4/6 依赖 / 静态检查 / 单元测试 ==' -ForegroundColor Cyan
Invoke-Checked 'flutter pub get' { flutter pub get }

# analyze 只做提示，不阻断：风格类 lint 不该拦住打包。
# 真正卡质量的是下面的单元测试和编译本身。
flutter analyze
if ($LASTEXITCODE -ne 0) {
    Write-Host '  analyze 报了一些问题（上面），继续构建。' -ForegroundColor Yellow
}

Invoke-Checked 'flutter test' { flutter test }
Write-Host ''

Write-Host '== 5/6 确保插件链接可用 ==' -ForegroundColor Cyan
# Flutter 给插件建符号链接需要「开发者模式」或管理员权限，否则报
#   Building with plugins requires symlink support.
#   Please enable Developer Mode in your system settings.
# （底层是 ERROR_PRIVILEGE_NOT_HELD = 1314）
#
# 但 flutter_tools 的 flutter_plugins.dart 里，对每个插件先做
#   if (link.existsSync()) continue;
# 链接已存在就完全跳过创建。而目录联接（junction）不需要管理员权限，
# 且 Dart 的 Link.existsSync() 对 junction 返回 true —— 所以预建 junction
# 就能合法地绕过这个限制，不必去改系统设置。
$developerMode = $false
try {
    $unlock = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction Stop
    $developerMode = ($unlock.AllowDevelopmentWithoutDevLicense -eq 1)
}
catch { $developerMode = $false }

if ($developerMode) {
    Write-Host '  开发者模式已开启，交给 Flutter 自己建链接'
}
else {
    Write-Host '  开发者模式未开启 -> 用 junction 预建插件链接（免管理员权限）' -ForegroundColor Yellow
    $depsFile = Join-Path $projectRoot '.flutter-plugins-dependencies'
    if (Test-Path $depsFile) {
        $deps = Get-Content $depsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $linkDir = Join-Path $projectRoot 'windows\flutter\ephemeral\.plugin_symlinks'
        New-Item -ItemType Directory -Path $linkDir -Force | Out-Null
        if ($deps.plugins.windows) {
            foreach ($plugin in $deps.plugins.windows) {
                $link = Join-Path $linkDir $plugin.name
                $target = $plugin.path.TrimEnd('\')
                # 用 rmdir 删旧链接：它只移除 junction 本身，不会动目标目录内容
                if (Test-Path $link) { cmd /c rmdir "`"$link`"" 2>&1 | Out-Null }
                cmd /c "mklink /J `"$link`" `"$target`"" 2>&1 | Out-Null
                Write-Host "    $($plugin.name) -> $target"
            }
        }
    }
    else {
        Write-Host '    找不到 .flutter-plugins-dependencies，请先执行 flutter pub get' -ForegroundColor Yellow
    }
    Write-Host '  长期做 Flutter 开发建议开启开发者模式（flutter run 也需要）：' -ForegroundColor DarkGray
    Write-Host '    start ms-settings:developers' -ForegroundColor DarkGray
}
Write-Host ''

Write-Host '== 6/6 打包 release ==' -ForegroundColor Cyan
Invoke-Checked 'flutter build windows' { flutter build windows --release }

$out = Join-Path $projectRoot 'build\windows\x64\runner\Release'
Write-Host ''
Write-Host "构建完成。产物目录：" -ForegroundColor Green
Write-Host "  $out" -ForegroundColor Green
Write-Host '把该目录整个压缩成 zip 发给用户即可；首次运行会在 exe 旁边生成 RandomPickerData\。' -ForegroundColor Green
