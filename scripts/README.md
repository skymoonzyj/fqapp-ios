# 构建与维护脚本

除单独注明工作目录外，下列命令从仓库根目录执行。脚本路径被 CI、Gradle 或测试引用；调整位置时同时更新调用方。

## 常用入口

| 脚本 | 用途 | 依赖与输出 |
| --- | --- | --- |
| [build_rust_backend.ps1](build_rust_backend.ps1) / [.sh](build_rust_backend.sh) | 生成 FRB 绑定并交叉编译 Rust 核心（arm64-v8a + armeabi-v7a） | Rust、NDK、FRB codegen 2.13.0；输出到 `android/app/src/main/jniLibs/<abi>/` |
| [run_rust_host_tests.ps1](run_rust_host_tests.ps1) / [.sh](run_rust_host_tests.sh) | 构建宿主核心，运行真实 Dart → FRB → Rust 集成测试 | Rust、Flutter；使用本地 Mock 上游和临时运行目录 |
| [verify_android_apk.py](verify_android_apk.py) | 检查 APK 签名、库、版本、资源及 16 KiB 对齐 | Python 3、Android Build-Tools；报告目录由参数指定 |
| [check_native_alignment.cjs](check_native_alignment.cjs) | 检查一个或多个 ELF 库（ARM64/ARM）的 LOAD 段对齐 | Node.js；只读取指定 `.so` |
| [check_so_freshness.cjs](check_so_freshness.cjs) | 打版前检查 `libfqapi_core.so` 是否比 `rust/` 的最新改动新（判据 CRIT-011）；mtime 不是内容证明，`--expect-sha256` 可比对内容哈希 | Node.js、git；只读取文件时间与 git 历史；未接入 CI（CI 每次重编 Rust） |
| [verify_audio_cenc.cjs](verify_audio_cenc.cjs) | 检查播放响应和加密 AAC 样本 | Node.js；会按响应中的地址有限下载 HTTPS 音频，属于在线诊断 |
| [generate_app_icons.py](generate_app_icons.py) | 从品牌源图生成 Android 图标及应用 Logo | Python 3、Pillow；修改已提交图片，普通构建直接使用现有图片 |

## Rust 构建与宿主集成

先准备 Flutter 依赖，再生成绑定：

```powershell
flutter pub get --enforce-lockfile
.\scripts\build_rust_backend.ps1
.\scripts\run_rust_host_tests.ps1
```

Linux/macOS 对应：

```bash
flutter pub get --enforce-lockfile
bash scripts/build_rust_backend.sh
bash scripts/run_rust_host_tests.sh
```

Windows 构建开关为 `-SkipCodegen`、`-HostLib`、`-Profile debug`；Shell 版对应 `--skip-codegen`、`--host-lib`、`--profile debug`。宿主测试的 `-SkipBuild` / `--skip-build` 只在宿主库已经更新时使用。

FRB 绑定发生变化时，还需再次生成并比较内容哈希，确认可复现。生成的文件位置见本地 `docs/project-structure.md`（不入库）。

## 常规验证

Rust 格式检查逐个文件执行，刻意排除 codegen 产物 `frb_generated.rs`：rustfmt 会沿
`mod` 声明进入该文件，而生成代码过不了 rustfmt，`cargo fmt --all -- --check` 因此在
干净树上也会失败。CI 用的是同一套做法。

```powershell
git ls-files -- 'rust/**/*.rs' 'rust/*.rs' | grep -v 'frb_generated\.rs$' | ForEach-Object { rustfmt --check --edition 2021 --config skip_children=true $_ }
cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml --locked
flutter analyze --no-pub
flutter test --no-pub --concurrency=2
node --test test/web_assets_test.cjs test/verify_audio_cenc_test.cjs test/build_rust_backend_scripts_test.cjs
```

`flutter test` 在宿主动态库存在时会运行 FRB 集成；库缺失时相关测试会明确跳过。`run_rust_host_tests.*` 可先重建宿主库再执行这组测试。C/JNI 主机回归和编译器要求见 [native/README.md](../native/README.md)。Android JVM 测试须在 `android/` 目录中执行：Windows 使用 `.\gradlew.bat :app:testDebugUnitTest`，Linux/macOS 使用 `./gradlew :app:testDebugUnitTest`。

## APK、诊断与资源

### 番茄采集的本机转换

将应用导出的原始 ZIP 解包到独立目录后，可直接使用 Dart 转换为兼容本机备份格式的 JSON：

```powershell
dart scripts/convert_fanqie_capture.dart <解包目录> <新输出文件.json> [目录响应缓存目录]
```

转换器与 Android 导入共用小说筛选、去重和章节 ID 匹配代码；输出包含书架和历史。
可选缓存目录中的 `<bookId>.json` 为现有 `/api/directory` 接口的完整响应。
没有目录时保留章节 ID，不猜章节序号；不会下载正文或访问账号。输出含个人阅读数据，请勿入库。

```powershell
flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi --no-pub
python scripts/verify_android_apk.py --help
node scripts/check_native_alignment.cjs android/app/src/main/jniLibs/arm64-v8a/libfqapi_core.so android/app/src/main/jniLibs/armeabi-v7a/libfqapi_core.so
node scripts/check_so_freshness.cjs android/app/src/main/jniLibs/arm64-v8a/libfqapi_core.so --since v1.0.88

`check_so_freshness.cjs` 未接入 CI：CI 每次都从源码重编 Rust 核心，不需要它。且它的 mtime 比较不是内容证明——`touch`、时钟偏差、用不同源码重编出相同 mtime 都能骗过它；git 历史比较也只看到已提交的 `rust/` 改动，未提交文件只靠 mtime。它只是本地快速辅查，可靠做法是重编，或用 `--expect-sha256 <构建时记录的哈希>` 比对库内容。
node scripts/verify_audio_cenc.cjs build/diagnostics/play-response.json
python scripts/generate_app_icons.py
```

APK 校验须传入 `--apk`、`--build-tools`、`--report-dir` 以及预期签名指纹，完整示例见本地
`docs/release-signing.md`（不入库）。只在没有正式签名材料的场景（fork、本地检视构建）才加
`--allow-unsigned`，此时报告里 `signature.signed` 为 `false`，其余检查照常执行。
`--help` 只显示参数，不算通过 APK 验证。

`verify_audio_cenc.cjs` 的 AAC 样本头匹配是诊断线索，不等于解码器播放成功。图标生成细节见 [品牌资源说明](../assets/branding/README.md)。诊断输出放在 `build/`；经用户验收的发布资料按版本存入 `release-archives/`。

## iOS 本地构建与来源证据

需要 macOS/Xcode、Python 3.11+、Flutter 3.44.6 / Dart 3.12.2、Rust 1.99.1、
FRB codegen 2.13.0 和 CocoaPods。最低 iOS 16.0，设备和 Apple Silicon 模拟器均为
arm64，二者独立构建。脚本不安装工具、不修改 Apple 账号/信任、不上传、不安装设备。

```bash
# 日常模拟器开发允许未提交修改，采用本机 ad-hoc 签名保留 Keychain entitlement。
bash scripts/build_ios_app.sh --mode simulator --bundle-id com.example.local --build-number 132

# 从干净提交构建本地设备产物；无需填写或虚构 Apple Team。
bash scripts/build_ios_app.sh --mode local-device --bundle-id com.example.local --build-number 132

# 只构建原生核心（普通开发可显式复用已生成且 Rust/Dart content ID 一致的绑定）。
bash scripts/build_ios_core.sh --profile debug --platform simulator --skip-codegen
```

`local-device` 使用 Release、iphoneos、`CODE_SIGNING_ALLOWED=NO`，输出到
`release-archives/ios-<version>-<build>-<完整提交SHA>-unsigned-local/`。
版本名读取已提交的 `pubspec.yaml`，构建号来自显式参数。目录已存在时失败，保留旧证据；
失败构建留下的目录也不会被自动覆盖。模拟器使用 `build/ios-app/` 的开发缓存，
模拟器显式使用 `CODE_SIGNING_ALLOWED=YES`、`CODE_SIGN_IDENTITY=-`、`DEVELOPMENT_TEAM=`。
工程通过 `CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]` 选择 `Runner-Simulator.entitlements`，
并以 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS[sdk=iphonesimulator*]=NO` 避免本机缓存的 Team prefix 注入；
脚本不覆盖工程 entitlement、prefix 或签名 style。模拟器 entitlement 的 application-identifier
与唯一 Keychain group 均为 `$(PRODUCT_BUNDLE_IDENTIFIER)`；设备保留标准 AppIdentifierPrefix 规则。
核对实际 ad-hoc 签名、TeamIdentifier 未设置、应用标识与仅本 App 的 Keychain group，不使用付费团队。
模拟器 entitlement 必须恰好只有上述两键；额外 Team、application-groups 或其他权限均拒绝。
权限从实际已签 arm64 Mach-O 的 `__TEXT,__entitlements` 区段读取，严格检查格式和读取边界，
不使用中间 `.xcent` 作为证明。Xcode 的模拟器签名字典可为空；若非空，必须与上述两键完全一致。
报告分别保存区段内容、有效权限及签名字典哈希，仍要求 codesign strict/deep、ad-hoc 和无 Team。
每次来源报告保存在新的 `build/ios-app/provenance/run.*/`。

所有最终设备产物要求干净提交；自动 codegen、依赖解析或 CocoaPods 若修改受控源码，
需要先检查并提交相应变化，再从新提交运行。`pod install --deployment` 不更新锁定依赖。
最终入口会重新运行 codegen；`--skip-codegen` 仅用于单独原生开发构建，不能作为最终
设备产物的来源证明。

`ios_artifact_provenance.py` 由构建入口调用，在编译前采集输入，在编译后重新比较：
Rust/C、Cargo 配置、生成绑定、Flutter/iOS 源码与受控资源、构建脚本、配置/锁文件，
加上工具版本与可执行文件内容哈希、SDK 信息和构建参数哈希。Cargo 全局/父目录配置
只记录哈希。参数及 Git diff 也只保存哈希，不保存可能含凭据的原文。
构建前后内容或工具发生变化即失败；mtime 不作为来源证明。
cc-rs 参数覆盖 plain、HOST/TARGET、target 连字符和下划线形式的 C/C++/归档 flags，
以及默认 flags/解析模式，均仅记录值哈希。入口在 codegen/Cargo 前拒绝自定义
RUSTC、Rust wrapper、CC/CXX/AR/RANLIB 和 target linker/runner 选择（含空覆盖）。
checkout、父目录和 Cargo home 配置也拒绝编译器/wrapper/target linker 选择、
`[env]` 注入和外部 `include`；不会把未知 wrapper 路径的字符串哈希当成工具内容证明。
每个 Cargo 子进程由脚本明确指定对应 SDK 的 clang/ar，工具内容哈希来自同一 xcrun 选择。
需要这些自定义选择的构建须先扩展受审的来源契约；本接口不会静默忽略覆盖。

原生 `manifest.json` 的 schema 2 包括 target/slice、XCFramework metadata 和库哈希。
App 的 `app-provenance.json` 绑定源提交、构建配置、前后输入哈希、完整 App 文件哈希、
原生 manifest 哈希和主可执行文件哈希；设备产物另核对 App/dSYM UUID。
最终目录保留 `Runner.xcarchive`、原生 XCFramework/manifest、`outcome.json` 与 `SHA256SUMS`。
`verified-unsigned-local-device` 仅代表 unsigned 本地产物结构/来源检查通过，
设备安装、真机功能验收和 TestFlight 上传均单独标为 `not-performed`。
模拟器类别为 `verified-adhoc-local-simulator`，与团队签名发布归档分开；报告记录实际 Xcode 参数。
模拟器 fixture 测试与实际工具/产物验证是不同证据。

### 后续签名与发布校验

仅当实际授权签名条件已齐备时使用 `--mode archive --team-id <实际团队ID>`；
缺团队或可用签名身份会在编译前失败。该模式保存到独立的 `-signed-archive/` 目录，
结果仍为 `built-signed-device-archive-pending-release-verification`，不表示可上传外测。
本地 unsigned 模式不会使以下签名校验器跳过任何身份或签名检查：

```bash
python3 scripts/verify_ios_archive.py \
  --archive <新归档目录/Runner.xcarchive> \
  --native-manifest <新归档目录/native/manifest.json> \
  --expected-team <实际团队ID> --expected-bundle <实际BundleID> \
  --expected-version <版本名> --expected-build <构建号> \
  --report <归档之外的新报告路径.json>
```

校验器交叉核对 `codesign --verify --deep --strict`、签名 entitlements、
`embedded.mobileprovision`、Mach-O 设备平台、`dwarfdump` UUID、构建时来源及工具哈希。
它还要求 App 中的隐私清单和相册使用说明，以及归档根目录中的
`publication-facts.json`、`licenses/manifest.json` 与许可证文本。
发布事实字段 `privacy`、`usage_descriptions`、`content_rights`、`encryption`、
`feedback_contact` 必须有核实证据后才设为 `verified`；未知值保留 `unknown` 并阻止发布。
仓库代码许可不等于在线内容、图标、字体或其他素材授权。

许可证收集完全离线，输出目录必须不存在；缺失证据退出 2 并列出 `unresolved`：

```bash
cargo metadata --manifest-path rust/Cargo.toml --locked --offline --format-version 1 > <本地metadata.json>
python3 scripts/collect_ios_licenses.py --cargo-metadata <本地metadata.json> \
  --flutter-root <已安装Flutter目录> --output <新归档目录/Runner.xcarchive/licenses>
```

Dart 解析版本、Cargo metadata 包版本、Pods 实际安装锁与锁文件必须匹配。清单包含
依赖、项目、tiny_aes、Flutter 和 engine 的许可证文本及哈希；文本收集成功不等于
内容权利或分发义务已经核实。上述 metadata 只作本地输入，不应入 Git。
发布材料准备完成后如增加/修改归档文件，保留原构建报告，并另生成新的最终校验报告/
校验和记录；不要修改旧包的源提交标签。未来导出 IPA 还需单独记录真实 IPA 的哈希与
身份，xcarchive 树哈希不能代替 IPA 哈希。

定向控制检查（使用临时仓库和外部工具 fixture，不执行实际 Apple/Rust 构建）：

```bash
python3 -m unittest discover -s test -p '*ios*test.py' -v
node --test test/build_ios_scripts_test.cjs
```

## iOS 串行回归门禁

App/native 构建、模拟器本地签名和设备归档身份契约见上节“iOS 本地构建与来源证据”。
宿主集成检查使用以下入口：

```bash
bash scripts/run_rust_host_tests.sh --features native-media-host-tests --machine
```

Shell host wrapper 只允许空 feature 集或 `native-media-host-tests`，始终以 `--locked --lib`
构建。`CARGO_TARGET_DIR` 可指定独立缓存。旁边的 `.provenance.json` 记录源码提交、
Rust/native/Cargo/链接配置等输入内容哈希、Rust 工具链、native 编译器身份/flags、feature 和实际库哈希。
`--skip-build` 仅在这些内容完全一致时复用；旧库缺 stamp、只改 mtime、改 feature、
未提交源码变更或库被改写均不能蒙混通过。失败重建先撤销旧 stamp，`--machine`
透传 Flutter NDJSON，供关键 skip/空测试门禁判断。PowerShell 入口保持其原有参数。

`verify_ios_checks.py` 的聚合接口如下；报告应放在忽略的 `build/` 中，每次运行使用新目录。
不能拿旧报告改写 SHA，也不能在回归过程中改源码后沿用之前的成功记录。

```bash
# tools.json 是非敏感的工具名 -> 实际版本字符串；不放环境变量/签名材料。
python3 scripts/verify_ios_checks.py --reports-dir build/ios-checks --init build/ios-checks/tools.json
python3 scripts/verify_ios_checks.py --reports-dir build/ios-checks --run-check flutter_analyze -- flutter analyze --no-pub
python3 scripts/verify_ios_checks.py --reports-dir build/ios-checks --output build/ios-checks/summary.json
```

每个必需项绑定同一 source SHA、dirty diff 摘要、工具版本和 run ID；缺失、failed、
skipped、not_run、非零退出、关键 skip 或无实际测试证据都会阻断。Flutter 全量里仅
明确的 Windows SDK backport / 可选字体截图，以及由独立必过 FRB host 检查覆盖的
host 库缺失 skip 可单列；FRB 与 iOS 验收不允许 skip。输出的 `passed` 仅指自动化门禁；
`release_ready` 保持 false，G1/G4/G5 真机矩阵单列 `not_run`，不能从模拟器/fixture 推算通过。

### 无上游内容的原生媒体 fixture

先提供带 `libx264`、`libx265`、`aac` 的 FFmpeg（`FFMPEG` 或 PATH），再生成仅供 integration
测试的 Dart define JSON。脚本自己生成 1 秒 96×64 / 6fps `testsrc2` 和低码率 mono `sine`，使用固定公开测试 key 制作
CENC，并将解密后逐帧哈希与明文比较；缺工具、缺编码器或失败均硬退出，不 skip；JSON 限制 60,000 字节，防止嵌套 base64 的 `DART_DEFINES` 超出 macOS exec 限制。

```bash
python3 scripts/generate_ios_media_fixture.py --output build/ios-fixtures/dart-defines.json --report build/ios-fixtures/generation-report.json
bash scripts/run_ios_integration.sh --entry native-media --simulator "$FQAPP_SIMULATOR_UDID" --fixtures build/ios-fixtures/dart-defines.json
```

顶层 `FQAPP_IOS_FIXTURES` 是 JSON 字符串，解码为 `{name, bytesBase64, keyHex}` 列表，
包含 `clear-avc1`、`cenc-avc1`、`offline-hvc1`。生成 JSON/base64/媒体只放忽略目录，
不加入 App 资源或产品调试 UI。原生 core/AVPlayer fixture 验收独立于 fake-player 控件
状态测试；系统 PiP、后台、锁屏、真实中断与 G1/G4 真机验收仍需单独证据。

CI `.github/workflows/ios-checks.yml` 串行调用上述产品入口，并只选择最小 JSON 检查摘要
作为 artifact，不选原始日志、运行目录、xcresult、base64 fixture、Cookie、内容密钥或签名文件。
Runner / Xcode 在配置中按已查证的 `macos-26` arm64 / Xcode 26.6 固定并严格预检；
配置落地不代表 GitHub CI 已实际运行。默认不上传 App Store Connect，不持有签名秘密。

`run_ios_integration.sh --entry acceptance|native-media --simulator <UDID>` 沿已验证的
config-only → bounded Xcode local-ad-hoc → `flutter drive --use-application-binary`
路径运行，避免 Flutter 自动重建无签名 App 后丢失 simulator Keychain entitlement。
先通过 Task 10 `ios_artifact_provenance.verify_native` 验证同源 debug simulator 核心；
实际运行前须由上述构建入口生成当前源码的原生核心；源码整合不代表已执行此检查。成功/失败都恢复无 fixture 的
`lib/main.dart` 配置并重建正常 App；恢复失败也使门禁失败。两类 driver 从真实
`IntegrationTestWidgetsFlutterBinding.results` 报告固定必需用例的结果集合，使用
独立 `fqapp.integration.result` JSON 契约，不伪造 Flutter machine 事件；零用例、
跳过/缺失或失败均不能通过。此门禁仍不等同物理 G1/G4 验收。

Runner XCTest 仅允许一个明确的 Simulator 硬件例外：
`DiagnosticsTests.testFileProtectionAttributeOnPhysicalDevice`，且命令必须显式选择
`platform=iOS Simulator`，输出必须保留原因
`Simulator does not expose Data Protection attributes; physical-device verification pending`。
报告保留该项为 skipped，不计入 passed，并保留 G5 `not_run`；真机运行、其它 skip
或缺少原因仍失败。这不放宽 native-media / UI drive 的固定必需用例清单。
