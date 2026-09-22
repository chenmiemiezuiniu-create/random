// 通过 GitHub API 创建 Release 并上传分发包。
//
// 用法（token 从环境变量读，绝不写在文件里、也不打印）：
//     $env:GH_TOKEN = "..."
//     node tools/create_release.js
//
// 幂等：如果该 tag 的 Release 已存在，会复用它而不是报错；
// 同名附件已存在时先删除再上传，方便重跑。

const fs = require('fs');
const path = require('path');

const TOKEN = process.env.GH_TOKEN;
const REPO = 'chenmiemiezuiniu-create/random';
const TAG = 'v1.0.0';
const ASSET = 'C:\\Users\\30481\\Desktop\\dsh\\random_picker_v1.0.0_windows_x64.zip';

const NOTES = `## 随机抽人 v1.0.0（Windows 版）

便携式随机抽取工具。**数据跟程序放在同一个文件夹**，删掉即零残留，不写 C 盘用户目录。

### 功能

- **两种抽取模式**
  - 不重复抽取：抽中的人本轮不再出现，抽完为止；也可随时点「开始新一轮」
  - 可重复抽取：每次都在完整名单里随机，同一个人可能被反复抽到
- **单人或批量**：一次抽 1 个，或一次抽 N 个；快捷按钮 1 / 2 / 3 / 5 / 全部
- **名单导入**：支持 \`.txt\`（一行一个名字，写成「张三,3」可设权重，权重 0 表示本轮不参与）
  和 \`.json\`；也可以直接在界面里新建名单、手动输入或粘贴
- **六套主题**：浅色、深色、粉色、浅蓝、紫色、跟随系统
- **无需登录**，打开即用
- **版本更新检测**：自动检查 GitHub 上的新版本并提示下载

### 怎么用

1. 下载下面的 \`random_picker_v1.0.0_windows_x64.zip\`
2. 解压到任意位置（桌面、U 盘都行）
3. 双击 \`random_picker.exe\`

首次运行会在 exe 旁边自动创建 \`RandomPickerData\\\` 文件夹，名单、设置和抽取记录都在里面。
**不想要了就直接把整个文件夹删掉，不留任何残余。**

### 系统要求

- Windows 10 / 11（64 位）
- 免安装、免管理员权限、不需要 .NET 运行时

### 已验证

- \`flutter analyze\` 无任何问题
- 84 个自动化测试全部通过（65 个逻辑 + 19 个界面）
- 实测运行期间 \`%APPDATA%\` **无任何文件被创建或修改**（零残留）
- 中文名单在磁盘上以 UTF-8 正确保存
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
    process.exit(1);
  }

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
          name: '随机抽人 v1.0.0（Windows）',
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

  // 同名附件先删掉，保证脚本可以重复执行
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
