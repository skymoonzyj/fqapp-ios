# fqapp 自动续签工具

macOS 菜单栏工具，使用本机 Xcode 已登录的 Apple 开发账号，为配置中的 fqapp 重新签名并覆盖安装。账号密码由 Xcode 管理，工具不保存账号密码。默认剩余签名有效期不超过 **48 小时**时尝试续签；程序启动、每小时和 Mac 唤醒后检查。手机暂时不可达时延后重试。

这是源码及本机配置流程，不包含签名材料、已签名 App 或个人设备配置，也不代表 TestFlight 发布或新设备验收完成。`config.example.json` 中的团队、设备、证书、日期和绝对路径都是占位示例，不能直接使用。

## 使用条件与范围

- macOS 13 或更高版本、完整 Xcode、可用的 `xcrun devicectl`、`/usr/bin/python3` 和 Swift 编译器。Xcode 需要已登录可为目标设备签名的 Apple 账号，并有配置所列证书的私钥。
- iPhone 已信任并配对该 Mac，可通过 USB 或已配置的无线连接访问；按 Xcode 要求启用开发者模式。Mac 必须已登录、唤醒且可连接 Apple 服务；关机或睡眠期间无法续签。
- iPhone 已安装经过确认的 `com.fqapp.fqapp`。本机保留与该安装**版本号、构建号完全相同**的可信未签名 `Runner.app`，以及这次已安装签名的真实到期时间。首次安装手机 App 不由本工具完成。
- 保留既有引擎范围：只处理无 App Extension、含 `Runner`、`App.framework/App` 和恰好 13 个 `.framework` 的 fqapp Flutter 归档。其他依赖布局需要单独验证，不能只改计数绕过检查。
- 在签名前及安装前检查手机现有版本；版本不一致时停止覆盖，防止后台装回旧版本。更新手机 App 后必须另行核实和更新运行目录里的源、清单及配置；首次配置/安装脚本不会自动覆盖现有工具或状态。

## 1. 准备本机配置

在 `tools/autorenew` 目录执行：

```sh
cp config.example.json config.json
chmod 600 config.json
```

编辑 `config.json`，替换所有占位值。它已被当前目录的 `.gitignore` 忽略，应只保留在本机。

| 字段 | 内容 |
| --- | --- |
| `team_id` | Xcode 对应团队的 10 位大写字母/数字 ID |
| `device_udid` | 已配对的目标 iPhone UDID |
| `version` / `build` | 已安装 App 和未签名源 `Info.plist` 中一致的版本/构建号 |
| `source_app` | 可信未签名 `Runner.app` 的**绝对路径**；不能有根目录签名或嵌入描述文件 |
| `provisioning_project` | 待生成的本地工程**绝对路径**，以 `ProfilePreparation.xcodeproj` 结尾；其父目录必须尚不存在 |
| `allowed_certificate_sha1` | 已确认签名证书的 40 位大写 SHA-1 指纹；对应私钥须在钥匙串可用 |
| `profile_cache_dirs` | 此 Mac 使用的 Xcode 描述文件缓存绝对路径；示例给出两个常见目录 |
| `installed_expires_at` | **当前已安装签名**的 UTC 到期时间，格式为 `YYYY-MM-DDTHH:MM:SSZ`；模板特意使用无效占位符，必须替换后才能初始化 |
| `renewal_window_hours` | 保持默认 `48`；菜单说明按 48 小时设计 |

JSON 路径不会展开 `~`、`$HOME` 或其他环境变量。不要把新构建但尚未安装的描述文件到期时间写成已安装到期时间，也不要用当前时间加七天估算。

若已保存实际安装所用的已签名 App，可在私有目录中离线检查它的描述文件及证书：

```sh
# 将下面两个值替换为真实绝对路径；PRIVATE_DIR 应是仓库外的新目录。
SIGNED_APP="/ABSOLUTE/PATH/TO/ACTUALLY-INSTALLED/Runner.app"
PRIVATE_DIR="/ABSOLUTE/PATH/TO/PRIVATE/installed-signing-check"
mkdir -m 700 "$PRIVATE_DIR"
/usr/bin/security cms -D -i "$SIGNED_APP/embedded.mobileprovision" > "$PRIVATE_DIR/profile.plist"
/usr/bin/codesign --display --extract-certificates="$PRIVATE_DIR/signer-" "$SIGNED_APP"
/usr/bin/shasum -a 1 "$PRIVATE_DIR/signer-0"
/usr/bin/plutil -p "$PRIVATE_DIR/profile.plist"
```

核对 `TeamIdentifier`、`ProvisionedDevices`、`ExpirationDate` 和证书指纹，并确认这个 App 就是已成功安装的同一构建。以上文件包含个人签名信息，保留在本机。工具的首次配置只验证本地输入及复制完整性，不能独立证明手机上安装了哪一份签名。

## 2. 生成最小签名准备工程并初始化

`prepare_project.rb` 需要 Ruby 的 `xcodeproj` gem（已有 CocoaPods 环境可能已具备）。在本机所用 Ruby 环境安装缺少的依赖后运行：

```sh
gem install --user-install xcodeproj
ruby prepare_project.rb "$PWD/config.json"
/usr/bin/python3 setup_runtime.py --config "$PWD/config.json"
```

生成器只生成工程文件，不访问账号或设备。初始化也不调用签名或设备命令，只校验本地配置、未签名源的 `Info.plist`/文件类型/内容、复制源并复核 SHA-256 和权限，然后写入：

```text
~/Library/Application Support/FqappAutoRenew/
  config.json
  state.json
  source-manifest.json
  source/Runner.app
  profile-preparation/
  logs/  runs/  evidence/
```

运行目录权限为 `0700`，配置、状态及清单为 `0600`。签名准备工程仅复制 `main.c`、entitlements、`project.pbxproj` 和共享 scheme；不会复制账号状态、用户工程配置或历史构建产物。源文件保持原位，后续续签操作针对运行目录里的工作副本。

也可用 `--installed-expires-at <UTC时间>` 显式传入已安装到期时间；它覆盖配置里的同名字段。`--home` 只用于隔离开发测试，当前 GUI 和安装器使用上述固定默认目录。已有运行目录一律拒绝初始化；若初始化途中失败，先检查报错和新产生的部分目录，再由操作者清理该部分目录后重试，不要删除有效的既有运行状态。

## 3. 验证、构建与安装工具

以下测试只使用临时假数据；原生 `--self-test` 在读取真实状态、发通知和执行引擎之前返回：

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s tests -v
bash macos/tests/run_tests.sh
bash build_app.sh "$PWD/build/Fqapp Auto Renew.app" /usr/bin/python3
"$PWD/build/Fqapp Auto Renew.app/Contents/MacOS/FqappAutoRenew" --self-test
```

构建产物使用本机临时签名，供本机运行。安装器固定使用 `/usr/bin/python3`，因此按上面的解释器路径构建。

确认本机配置后安装（不加 `--start` 时只写入工具和登录启动项）：

```sh
/usr/bin/python3 install_utility.py --start
```

这会写入 `~/Applications/Fqapp Auto Renew.app` 和 `~/Library/LaunchAgents/com.fqapp.autorenew.plist`，复制引擎到私有运行目录，并在当前登录会话启动。**启动会立即执行真实检查，满足 48 小时条件时可能签名并覆盖安装手机 App。** 安装器发现已有 App 或启动项会停止，保留现有安装。

## 4. 手动核验与日常使用

双击工具打开状态窗口，菜单栏提供“立即检查”“立即续签”“暂停自动续签”和日志入口。立即续签会请求新的签名，暂停期间也允许手动续签；关闭状态窗口继续后台运行，选择退出会停止本次登录期间运行，下次登录重新启动。恢复自动续签后会检查一次。

本机只读查看状态：

```sh
/usr/bin/python3 "$HOME/Library/Application Support/FqappAutoRenew/renew.py" \
  --home "$HOME/Library/Application Support/FqappAutoRenew" status
```

首次实际续签后，核对状态显示成功且到期时间确实延长，打开 iPhone 上的 fqapp 检查首页和既有数据，并查看运行日志中的安装及安装后版本核验结果。后台自动触发、完整一小时时间间隔、睡眠/唤醒、无线重连和系统通知需在目标 Mac/iPhone 上分别验收；源码测试不替代这些检查。

如果设备离线、Apple 尚未签发更晚到期的描述文件，工具延后重试。账号需要重新登录或证书变化时，先在 Xcode/钥匙串完成核查，再修订本机配置或重试。工具不会自动撤销证书，也不会卸载或清空手机 App。安装未明确成功、安装后版本核验失败时，保留原到期记录和本机诊断信息。

`build/`、`profile-preparation/`、本机 `config*.json`、运行日志、签名证书与描述文件都不应提交到 Git。仓库只分发源码、虚构示例和离线测试。
