// 通过 GitHub API 创建 Release 并上传分发包。
//
// 用法（token 从环境变量读，绝不写在文件里、也不打印）：
//     $env:GH_TOKEN = "..."
//     node tools/create_release.js            # 版本号自动读 lib/core/constants.dart
//     node tools/create_release.js 1.0.2      # 也可以显式指定
//
// ⚠️ 如果本机访问 GitHub 要走代理（国内很常见），node 的内置 fetch
// **不会自动读系统代理**，需要显式开环境变量代理：
//     $env:HTTPS_PROXY = "http://127.0.0.1:7897"
//     $env:HTTP_PROXY  = "http://127.0.0.1:7897"
//     node --use-env-proxy tools/create_release.js
// 不加这两步会报 `TypeError: fetch failed`。
//
// 幂等：该 tag 的 Release 已存在就复用它；同名附件先删再传，方便重跑。

const fs = require('fs');
const path = require('path');

const TOKEN = process.env.GH_TOKEN;
const REPO = 'chenmiemiezuiniu-create/random';

const projectRoot = path.resolve(__dirname, '..');
const workspaceRoot = path.resolve(projectRoot, '..');

/** 版本号优先取命令行参数，否则从 constants.dart 里读，避免两处不一致。 */
function readVersion() {
  if (process.argv[2]) return process.argv[2].replace(/^v/, '');
  const src = fs.readFileSync(
    path.join(projectRoot, 'lib', 'core', 'constants.dart'),
    'utf8'
  );
  const m = src.match(/kAppVersion\s*=\s*'([^']+)'/);
  if (!m) throw new Error('读不到 kAppVersion，请显式传版本号');
  return m[1];
}

const VERSION = readVersion();
const TAG = `v${VERSION}`;
const ASSET = path.join(workspaceRoot, `random_picker_v${VERSION}_windows_x64.zip`);

const NOTES = `## 随机抽人 ${TAG}（Windows 版）

便携式随机抽取工具。**数据跟程序放在同一个文件夹**，删掉即零残留，不写 C 盘用户目录。

### 本次更新：下载更可靠、更安全

- **下载完成后用 GitHub 官方的 SHA-256 摘要校验**，确认拿到的安装包和发布端
  逐字节一致。以前只比对字节数，而字节数相同但内容被换掉是拦不住的
- **代理软件被关掉后会自动改直连重试**。之前如果代理崩溃或退出，注册表里
  可能还留着「已启用代理」，导致明明网络正常却一直提示检查更新失败
- 会自动使用系统代理（Clash 等开启「系统代理」时），**不需要额外配置**

### 自动更新怎么用

发现新版本后点「立即更新」，**在程序内显示下载进度**，下完自动替换、自动重启，
不用再去浏览器手动下载解压。

下载会校验完整性；替换前自动备份，万一覆盖失败会**自动回滚**，
不会留下一个起不来的程序。你的名单和设置完全不受影响。

如果自动下载失败（比如网络到不了 GitHub），弹窗里也有「手动下载」按钮，
会打开浏览器让你走自己的方式下载。

### 功能一览

- **两种抽取模式**
  - 不重复抽取：抽中的人本轮不再出现，抽完为止；也可随时点「开始新一轮」
  - 可重复抽取：每次都在完整名单里随机，同一个人可能被反复抽到
- **单人或批量**：一次抽 1 个，或一次抽 N 个；快捷按钮 1 / 2 / 3 / 5 / 全部
- **名单导入**：支持 \`.txt\`（一行一个名字，写成「张三,3」可设权重，权重 0 表示本轮不参与）
  和 \`.json\`；也可以直接在界面里新建名单、手动输入或粘贴
- **六套主题**：浅色、深色、粉色、浅蓝、紫色、跟随系统。
  标题栏颜色会跟着主题走，不会出现「浅色界面配黑标题栏」
- **无需登录**，打开即用

### 怎么用

1. 下载下面的 \`random_picker_v${VERSION}_windows_x64.zip\`
2. 解压到任意位置（桌面、U 盘都行）
3. 双击 \`random_picker.exe\`

首次运行会在 exe 旁边自动创建 \`RandomPickerData\\\` 文件夹，名单、设置和抽取记录都在里面。
**不想要了就直接把整个文件夹删掉，不留任何残余。**

### 系统要求

- Windows 10 / 11（64 位）
- 免安装、免管理员权限、不需要 .NET 运行时
`;

function headers(extra) {
  return Object.assign(
    {
      Authorization: `Bearer ${TOKEN}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'RandomPicker-Release',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    extra || {}
  );
}

// 只报告状态码和错误正文，绝不回显响应头（避免泄露 token）
async function call(url, options, label) {
  const resp = await fetch(url, options);
  const text = await resp.text();
  if (!resp.ok) {
    throw new Error(`${label} 失败: HTTP ${resp.status}\n${text.slice(0, 600)}`);
  }
  return text ? JSON.parse(text) : null;
}

(async () => {
  if (!TOKEN) {
    console.error('缺少 GH_TOKEN 环境变量');
    process.exit(1);
  }
  if (!fs.existsSync(ASSET)) {
    console.error('找不到分发包: ' + ASSET);
    console.error('请先构建并打包成 random_picker_v' + VERSION + '_windows_x64.zip');
    process.exit(1);
  }

  console.log('版本: ' + VERSION);
  console.log('1) 校验 token 权限');
  const me = await call('https://api.github.com/user', { headers: headers() }, '读取用户');
  console.log('   登录身份: ' + me.login);

  console.log('2) 创建/复用 Release ' + TAG);
  let release = null;
  try {
    release = await call(
      `https://api.github.com/repos/${REPO}/releases/tags/${TAG}`,
      { headers: headers() },
      '查询已有 Release'
    );
    console.log('   已存在，复用 id=' + release.id);
  } catch (e) {
    release = await call(
      `https://api.github.com/repos/${REPO}/releases`,
      {
        method: 'POST',
        headers: headers({ 'Content-Type': 'application/json' }),
        body: JSON.stringify({
          tag_name: TAG,
          name: `随机抽人 ${TAG}（Windows）`,
          body: NOTES,
          draft: false,
          prerelease: false,
          target_commitish: 'main',
        }),
      },
      '创建 Release'
    );
    console.log('   已创建 id=' + release.id);
  }

  const assetName = path.basename(ASSET);
  console.log('3) 上传附件 ' + assetName);

  const existing = await call(
    `https://api.github.com/repos/${REPO}/releases/${release.id}/assets`,
    { headers: headers() },
    '列出附件'
  );
  for (const a of existing) {
    if (a.name === assetName) {
      await call(
        `https://api.github.com/repos/${REPO}/releases/assets/${a.id}`,
        { method: 'DELETE', headers: headers() },
        '删除旧附件'
      );
      console.log('   已删除旧同名附件');
    }
  }

  const buf = fs.readFileSync(ASSET);
  const uploaded = await call(
    `https://uploads.github.com/repos/${REPO}/releases/${release.id}/assets?name=${encodeURIComponent(assetName)}`,
    {
      method: 'POST',
      headers: headers({
        'Content-Type': 'application/zip',
        'Content-Length': String(buf.length),
      }),
      body: buf,
    },
    '上传附件'
  );

  console.log('   上传完成: ' + uploaded.name +
              '  ' + (uploaded.size / 1024 / 1024).toFixed(1) + ' MB');
  console.log('');
  console.log('Release 页面: ' + release.html_url);
  console.log('下载直链   : ' + uploaded.browser_download_url);
})().catch((e) => {
  console.error('出错: ' + e.message);
  process.exit(1);
});
