# 发版手册（lifedever/macshot）

新会话要改代码、给本机装测试版或发版时，先读这份。技术细节在项目 `CLAUDE.md` 的「Releasing › This fork」一节，这里写的是流程和规矩。

## 一、只有一个 App

- 本机安装的和发给别人的是**同一个 App**：bundle ID `com.lifedever.macshot`，同一张自签证书「MacShot Dev Local」，同一个更新源。两者互相覆盖，共用设置和权限。
- **不要再换 bundle ID。** 2026-11-25 换过一次（从上游的 `com.sw33tlie.macshot.macshot` 换过来），结果是设置全部重置，权限反复授权失败，排查了一下午。旧身份的数据还在 `~/Library/Containers/com.sw33tlie.macshot.macshot`，没有删。
- 授权（屏幕录制、辅助功能、麦克风、摄像头）认的是「bundle ID + 证书」，所以重装和更新都不需要重新授权。

## 二、日常改代码

1. 改完代码，跑相关测试：`scripts/run-tests.sh [ClassName]`。
2. 给本机装测试版：`scripts/build-install.sh`（等于 `scripts/release.sh --install`）。
   - 版本号沿用最新的 `v…-fork.N` tag，构建号是 commit 数，功能是当前最新的代码（包括还没提交的改动）。
   - 它会退出正在运行的 MacShot，替换 `/Applications/MacShot.app`，再重新打开。
3. 按改动拆开，在本地 commit。**不要 push**，除非用户要求。

**要让用户测试「自动更新」时：** 发版前后都**不要**在本机重装。本机装的构建号必须小于新版的构建号，否则不会提示有更新。

## 三、发版流程

用户明确说「发版」才做。发版是对外动作。

1. **定版本号**：`x.y.z-fork.N`，接着上一个 tag 递增 N（查最新：`git describe --tags --abbrev=0 --match 'v[0-9]*-fork.*'`）。跟进上游大版本时再改 `x.y.z`。
2. **写更新说明**：`release-notes/<版本号>.md`，中文，只写用户看得到的改动，一条一行，简短。先读 `~/.claude/refs/ui-copy.md`。写完单独 commit。
3. **打包**：`scripts/release.sh <版本号>`。工作区必须干净；构建号不大于线上最新版时脚本会拒绝。产物在 `/tmp/macshot-release/<版本号>/`：
   - `MacShot-Apple-Silicon.dmg`、`MacShot-Intel.dmg`（README 里的固定下载链接指向这两个名字，不要改名）；
   - `appcast-arm64.xml`、`appcast-x86_64.xml`、`appcast.xml`（App 按所在 Mac 的芯片读前两个；`appcast.xml` 留给 4.5.0-fork.1 这种更早的版本）。
4. **push 前核对**：`git fetch origin && git log --oneline origin/main..main`。用户可能同时在往 main 提交，里面有不是本会话做的提交时，先列出来问用户。然后 `git push origin main`。
5. **发布**：`scripts/release.sh <版本号> --publish`。它会在打包时的那个 commit 上打 tag、推 tag、建 GitHub Release，并上传 DMG 和 appcast。
6. **发完即止**：不下载回来验证（用户定的规矩）。删掉 `/tmp/macshot-release/<版本号>`。

用户怎么收到更新：后台每天检查一次，有新版本时发系统通知 → 点通知进入「设置 › 通用」→ 点「更新」→ 弹出更新说明 → 点「安装更新」→ 下载完自动安装并重启，中间不再要求确认。也可以随时在「设置 › 通用」点「检查更新...」。

## 四、必须保管好的两样东西

| 东西 | 在哪 | 丢了会怎样 |
|---|---|---|
| 证书「MacShot Dev Local」 | 本机登录钥匙串 | 只能换新证书，所有人下一次更新后都要重新授权 |
| Sparkle 更新签名私钥 | 钥匙串，账户 `macshot`；备份在 1Password「MacShot Sparkle 更新签名私钥」 | 已经装上的人都收不到更新 |

- **证书还没有备份**（截至 2026-11-25）。在「钥匙串访问」里把证书导出成 .p12，存进 1Password。
- 私钥恢复到新 Mac：把 1Password 里的私钥存成文件，运行 `generate_keys --account macshot -f <文件>`（工具在构建后的 `…/SourcePackages/artifacts/sparkle/Sparkle/bin/`）。公钥写死在 `scripts/release.sh` 的 `SPARKLE_PUBLIC_KEY`，脚本会拒绝用别的私钥签名。
- 证书重建方法写在 `scripts/build-install.sh` 文件开头（只有 .p12 也找不回来时才用）。

## 五、注意事项（都踩过）

- **不要在用户的 Mac 上跑另一个身份或同名的 App 副本。** 权限列表里同名的 App 分不清，用户会把开关开到错的那个上。非跑不可的话，给它起一个能区分的名字；结束后运行 `tccutil reset All <bundle id>` 清掉权限记录，再用 `lsregister -u <路径>` 注销登记。
- **排查授权问题先读系统日志**，不要凭用户说的「我已经授权了」去猜：
  ```
  /usr/bin/log show --last 30m --style compact --predicate 'process == "tccd"'
  ```
  看三样：`Publishing <TCCDEvent … identifier=…>`（改的是哪个 bundle ID、什么时候改的）、`AUTHREQ_RESULT authValue`（0 是拒绝，2 是允许）、`Failed to match existing code requirement`（记录里存的签名过时了，用 `tccutil reset <服务> <bundle id>` 删掉记录，再重新授权，**不用重启电脑**）。
- **本机的 Gatekeeper 是关着的**，所以「第一次打开被系统拦下」这一步在本机测不出来，要找朋友的 Mac 验证。
- **App 的数据目录受系统保护**，终端（Muxy）读不了，也写不了，`defaults read` 也会失败。要拿旧数据时，让用户用访达把文件复制出来，再读复制出来的那份。
- **涉及令牌、密钥的内容不要显示在对话里**：用 `pbcopy` 直接放进剪贴板，或者只显示开头几位。
- 上游的 `build-release.yml` 只在 sw33tLie/macshot 里运行，在本仓库推 tag 不会触发它。
