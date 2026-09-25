# Husk

把网站当成独立 app 用的 iOS 容器。每个站点有自己的图标、缩放、User-Agent、外链规则和**独立存储**，互相看不见对方的登录状态。

解决的是 Safari「添加到主屏幕」那套 PWA 的老问题：缩放改不了、UA 锁死、点个外链就被甩出 app、图标丑、所有站共用一份 cookie。

- SwiftUI + `WKWebView`，最低 **iOS 26.0**
- 外观只做 **Liquid Glass 一套**，代码里没有一处 `#available` 降级分支
- 无第三方依赖（打包了一份 Public Suffix List 数据文件），Swift 6 语言模式
- MIT License

---

## 产物形态：源码 + XcodeGen

仓库里**没有 `.xcodeproj`**。`project.yml` 是 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 的工程定义，在 Mac 上生成：

```bash
brew install xcodegen      # 只要装一次
cd Husk
xcodegen generate          # 产出 Husk.xcodeproj
open Husk.xcodeproj
```

改了 `project.yml` 或者加删了源文件，重跑一次 `xcodegen generate` 即可。`.xcodeproj` 已经在 `.gitignore` 里。

### 改 Bundle ID 和签名

1. `project.yml` → `targets.Husk.settings.base.PRODUCT_BUNDLE_IDENTIFIER`，把 `org.example.husk` 换成你自己的。
2. 同一处的 `DEVELOPMENT_TEAM` 填你的 Team ID；或者留空，生成工程后在 Xcode 的 Signing & Capabilities 里选。
3. URL scheme `husk` 写在 `Support/Info.plist` 的 `CFBundleURLTypes` 里。想换名字的话，`Sources/App/DeepLink.swift` 里的 `DeepLink.scheme` 要同步改。

个人开发者账号（免费）装上去，app 每 7 天过期一次，重新用 Xcode 装一下就行。

### 下载

最新版的未签名 ipa 永远在这个**固定链接**上（每次合进 `main` 自动更新）：

```
https://github.com/sketchain/Husk/releases/latest/download/Husk-unsigned.ipa
```

文件名刻意不带版本号，就是为了这条链接不用改。版本号写在 Release 标题、说明和 ipa 里 `Info.plist` 的 `CFBundleShortVersionString` 中。

### CI（GitHub Actions）

`.github/workflows/build.yml`：push 到 `claude/**` 分支、以及手动触发时跑，**只编译不发版**。

`main` 刻意不在它的触发列表里——合进 `main` 走 `release.yml`，后者用 `workflow_call` 复用同一套编译步骤再接着发版，两边都监听的话同一个提交会编译两遍。

- runner `macos-26`（Apple Silicon，2026-02 起 GA），默认 Xcode 26.6，自带 iOS 26.x SDK
- `brew install xcodegen` → `xcodegen generate` → `xcodebuild build`
- **只编译不签名**（`CODE_SIGNING_ALLOWED=NO`），CI 上没有证书
- 产物是未签名的 `Husk-unsigned.ipa`（就是个 zip，里面 `Payload/Husk.app`），作为 artifact 留存 30 天

下载下来之后用你自己的证书签：

```bash
unzip -q Husk-unsigned.ipa
codesign -f -s "Apple Development: 你的名字 (XXXXXXXXXX)" \
  --entitlements your.entitlements Payload/Husk.app
zip -qry Husk-signed.ipa Payload
```

或者直接把 `Payload/Husk.app` 丢给 Xcode / 你惯用的侧载工具。

### 发版：合进 main 就自动发

`.github/workflows/release.yml`。**什么都不用做**——改动合进 `main`、编译通过，就会自动建 tag、建 Release、传 ipa。不需要任何人有推 tag 的权限。

版本号由 CI 自己算：取仓库里**最新那个 Release 的版本号，末位 +1**（`v1.2.9` → `v1.2.10`）。一个 Release 都还没有就从 `v0.1.0` 起。算出来的号要是已经被某个 tag 或 Release 占了（手动发过版、或者 Release 删了 tag 还在），就继续 +1 直到空位。

整条流水线：

1. **version** — 算出这次的版本号
2. **build** — 复用 `build.yml` 的编译步骤（`workflow_call`，不是复制一份），把版本号注进去：`v1.2.0` → `MARKETING_VERSION=1.2.0`，`CURRENT_PROJECT_VERSION` 用 workflow 的运行序号；打包前 `PlistBuddy` 读一遍确认真写进去了
3. **publish** — 建 tag + Release，标题 `Husk v1.2.0`，把 `Husk-unsigned.ipa` 作为 **Release 附件**上传（不是 artifact，不会过期）

Release 说明里有：未签名提示、上面那条固定直链、**本次包含的提交列表**（跟上一个 Release 做 compare 得来）、以及 GitHub 自动生成的那段。

原来那两个入口都还在：

```bash
git tag v1.2.0 && git push origin v1.2.0     # 手动指定版本号
```

或者在 Actions 页面手动跑 **Release**，填上版本号——tag 不存在的话由 CI 建在触发时所在的提交上。这两条路径**撞上已有的 Release 会直接报错**而不是悄悄跳过：手动填了个发过的版本号，基本只可能是填错了。

版本号里带连字符的（`v1.2.0-beta1`）按 semver 惯例自动标成预发布，`releases/latest` 不会指向它；自动算出来的号永远不带连字符。

功能分支 push 不发版，只编译。

---

## URL Scheme

```
husk://open?id=<UUID>                 # 打开列表里的站点
husk://open?url=<percent-encoded>     # 打开临时站点，不入列表
```

首页长按任一站点 → 「复制 husk:// 链接」拿到第一种。第二种可以从快捷指令、备忘录之类的地方直接调起。

**进来的时候首页一帧都不会出现**，实现见下面「不闪首页是怎么做到的」。

## 快捷指令（App Intents）

「打开站点」是注册给快捷指令的动作，站点本身是一个 `AppEntity`：在快捷指令里加这个动作时，
站点参数是一个**带名字和图标的下拉列表**，不用手打 UUID。

除此之外 `AppShortcutsProvider` 会让**每个站点**在「快捷指令」app 的 Husk 分组里各占一条，
装完就能直接跑，不用自己先攒一条快捷指令。站点增删改之后会调
`updateAppShortcutParameters()` 刷新那份快照（`Sources/Storage/SiteStore.swift`）。

Siri 短语（每条都必须带上 app 名，这是框架的硬性要求）：

```
在 Husk 里打开〈站点〉
用 Husk 打开〈站点〉
Open 〈站点〉 in Husk
```

想把某个站点放上主屏：在快捷指令里建一条「打开站点」→「添加到主屏幕」，
图标选相册里那张（见下一节）。

---

## 主屏图标：存到相册，不再是 Web Clip

**移除了 `.mobileconfig` / Web Clip 那一整条路。** 实测下来它有两个绕不过去的毛病：

- 指向 `husk://` 时，多任务切换器里会多出一张**空白网页壳**——那是 Web Clip 自己的
  Safari 容器，点开 Husk 之后它还赖在那儿；
- 改成 `FullScreen=false` 倒是不留壳了，代价是点图标先经过 Safari 弹一下再跳回来。

两条都不如快捷指令的「添加到主屏幕」干净，而后者只需要一张图。所以原来「导出 Web Clip」
的位置换成了**「存储图标到相册」**：

- 站点长按菜单 → 存储图标到相册
- 站点设置 → 维护 → 存储图标到相册
- 全局设置 → 图标 → 把全部站点图标存进相册

产出的是 **1024×1024、方形、不带圆角、不透明**的 PNG。不自己切圆角是因为系统会再切一遍，
自己先切等于边上留一圈怪东西。

底色一律铺首字母占位图那套渐变，再把站点图标等比铺满盖上去——很多 favicon 是透明 PNG，
直接存会变成一块黑。源图小于 **128px** 时就不硬放了，直接按占位图风格重画一张。

门槛按**最终显示尺寸**算而不是按 1024 算：主屏图标显示出来大约 180pt，3x 屏上是 540 像素。
所以 180 的 apple-touch-icon（最常见的一种）实际是 3 倍放大，偏软但认得出，
用它比给人一个字母强；32/64 的 favicon 是 8 倍以上，那才是真糊。

这条门槛能成立，前提是**图标缓存只缩不放**：`IconFetcher.targetSize` 以前写死 180，
会把 32 像素的 favicon 也放大成 180，缓存文件的像素数从此和源图的真实清晰度脱钩，
导出这边就没法判断"这张图值不值得放到 1024"。现在它是**上限 512**，
缓存文件多大就代表源图真有多清楚。

权限只申请 **`NSPhotoLibraryAddUsageDescription`（仅添加照片）**，
不要完整相册读取权限——这个功能只需要往里放。站点设置里的「从相册选一张」走
`PhotosPicker`，那是进程外选择器，本来就不需要任何权限。

---

## 功能一览

**首页（iOS 26 改版）** — 底部系统 TabView：

| tab | 内容 |
|---|---|
| 站点 | 图标网格，`+` 在导航栏右上角 |
| 设置 | 原来的全局设置弹窗，现在是平级的一个 tab |
| 搜索 | `role: .search`，iOS 26 下单独一颗圆形按钮落在右边，点开整条 tab bar 变搜索框 |

tab bar 上方有一条 **`tabViewBottomAccessory`**「继续上次」：上次打开的站点图标 + 名字，点一下直接回去。没有上次记录时这条整个不显示。

站点长按出菜单：编辑 / 移到最前 / 复制 `husk://` 链接 / 存储图标到相册 / 删除。

**浏览界面** — 全屏 WebView，除页面外没有任何常驻 UI。加载进度默认是顶部一条 2pt 细条，加载完淡出；设置里可以改成**「环绕灵动岛」**——进度沿着灵动岛那颗胶囊的轮廓画一圈，淡出行为和细条完全一样。设备读不到灵动岛、或者横屏时自动退回细条（详见[进度环](#进度环环绕灵动岛)）。支持边缘滑动前进后退。设置里可以开「浏览时隐藏状态栏」，把时间电池那条一起藏掉，两种进度样式下都照常生效。

**手势工具箱** — 四种唤出手势可逐个开关（默认开前两个）：

| 手势 | 默认 |
|---|---|
| 双指下滑 | 开 |
| 底边上滑 | 开 |
| 三指点按 | 关 |
| 双指长按 | 关 |

刻意避开单指边缘滑（撞前进后退）和单指长按（撞选中文字、链接预览）。

工具箱现在是**原生 sheet**，两档 detent：

- **半屏档**是 iOS 26 的悬浮玻璃卡片（圆角、边距、材质全是系统的），底下的网页还能继续点、继续滚；
- 往上拖到**大档**，下半截直接就是**本站设置**——缩放、UA、外链档位与例外、存储 profile，不用再点一下跳新页面。

上半截固定是：刷新 / 站点首页 / 分享 / 在 Safari 打开、当前 URL（点一下复制）、返回列表。

**站点配置** — 图标（自动抓取 / 相册选图 / 首字母渐变）、缩放 10%–200%、UA（6 个预设 + 自填）、外链行为与档位、手动例外名单、存储 profile、按 profile 的 HTTPS 代理（见[按 profile 配 HTTPS 代理](#按-profile-配-https-代理)）。

**全局设置** — 浏览时隐藏状态栏、加载进度样式（顶部细条 / 环绕灵动岛）、手势开关、新建站点默认值、图标（Google 回退开关 / 批量存图标）、配置导入导出（JSON）、网络代理（按 profile 列出）、存储管理（按站点清 / 全部清 / 孤儿清理）。

设置页最底下压着一条不起眼的**「实验室」**，见下。

---

## 实验室：灵动岛几何探测

设置 → 最底部 → 实验室。为「加载进度环绕灵动岛」做的前期验证，**本身不画进度环**——环在浏览页，见本节末尾的[进度环](#进度环环绕灵动岛)。几何公式和私有 API 的读取逻辑已经挪到 `Sources/Island/`，这一页和浏览页共用同一份。

公开 API 拿不到灵动岛的位置和尺寸：`safeAreaInsets.top` 只给一个高度，横向范围完全没有，圆角更没有。已知唯一的来源是私有属性 **`UIScreen._exclusionArea`**——按逆向资料它返回一个 `UISDisplaySingleRectShape`，其 `rect` 是**传感器避让区的外接矩形**（单位 screen points），iOS 16 到 26 都有使用证据。本 app 自签侧载，用私有 API 没有上架风险。

但它给的是避让区，不保证和系统画的那颗黑胶囊边缘严丝合缝，也不带圆角。所以这一页做两件事：

**1. 原始诊断信息**（一键复制全部）：`utsname.machine`、iOS 版本、`UIScreen` 的 bounds / nativeBounds / scale / nativeScale、`_displayCornerRadius`、当前窗口的 `safeAreaInsets`、以及 `_exclusionArea` 的读取结果——返回对象的类名、`description`、取到的 `rect`。读失败时写清楚**卡在哪一步**。最后一行是**「进度环判定」**：和浏览页用的是同一个函数，它说"会画环"浏览页就会画，说"退回细条"后面跟着原因。

**2. 可视化叠加**：按读到的 rect 在全屏最上层画一圈 1pt 细描边，圆角半径 / 向外扩 / X 偏移 / Y 偏移全是滑块，实时生效并显示数值。调到和灵动岛贴合为止，参数会跟着诊断信息一起进剪贴板。

三个实现上的点：

- **KVC 每一跳都先 `responds(to:)`**。对不存在的 key 调 `value(forKey:)` 抛的是 ObjC 的 `NSUnknownKeyException`，Swift 的 `do-catch` 根本接不住，结果是直接闪退。私有 API 随时会改名、换类型或消失，所以每一步都先确认选择器在，不在就带着"卡在哪一步"原地返回。取出来的 `NSValue` 还要比一遍 `objCType` 再碰 `cgRectValue`——类型对不上时它不是返回 nil 而是崩。
- **描边挂在自己的 `UIWindow` 上**，不是 SwiftUI 的 `.overlay`。要在离开这一页之后还看得见，否则页面自己的导航栏就挡在灵动岛底下，根本没法观察。窗口 `hitTest` 永远返回 nil（触摸全部穿透，UI 照常能用），并且**不** `makeKeyAndVisible`（key window 仍是 SwiftUI 那个，状态栏归它管，浏览页的「隐藏状态栏」不受影响——已实测），层级压在 `.normal + 1`。
- **读不到时退回估计值**并在页面上明确标注"这是估计值不是读取值"，用的是下面实测出来的那组数。

校准参数存 `UserDefaults`，刻意不进 `AppSettings`——调试用的临时值，不该混进导出的配置 JSON。

这一页**长期保留**，不随进度环一起删——换机型、换系统版本都得重新验一遍。

### 已测得

**iPhone 16 Pro（`iPhone17,1`）/ iOS 26.6.2 / 402 × 874 @3x：**

| 项 | 值 |
|---|---|
| `_exclusionArea` 类型 | `UISDisplaySingleRectShape` |
| `rect` | `{138.333, 14, 125, 36.6667}` |
| `safeAreaInsets.top` | 62 |
| `_displayCornerRadius` | 62 |

人眼校准出来的贴合参数：**向外扩 1、圆角夹成胶囊、X 偏移 +0.15**，Y 不用偏。

由此两条结论：

**1. 避让区比眼睛看到的边缘整整小一圈 1pt。** 进度环要贴的是扩完之后那颗胶囊，不是原始 rect。

**2. 那个 +0.15 不是玄学，是半个设备像素。** 把这台机器的数换算成像素：

| | pt | px @3x |
|---|---|---|
| 屏宽 | 402 | 1206 |
| 岛宽 | 125 | 375 |
| 岛 y / h | 14 / 36.6667 | 42 / 110 |
| `_exclusionArea` 的 x | 138.3333 | **415.0** |
| 真正居中的 x | 138.5 | **415.5** |

y、w、h 全是整像素，唯独居中位置落在 415.5px 这个半像素上，被向下取整成了 415px——@3x 下差 0.1667pt，正好就是手调出来的那 0.15。

所以**可见的岛是严格水平居中的**，横向别直接用读出来的 x，按屏幕居中算。这条已经固化成 `IslandEstimate.visiblePill(exclusionRect:screenWidth:)`，进度环直接调它，别再自己拿 rect 硬算，不然会踩回半像素这个坑。

**这两条（外扩 1pt、按屏幕重新居中）目前只在 iPhone 16 Pro / iOS 26.6.2 这一台上验证过**，其他带岛机型还没测，不是已确认的普遍结论。换机型时用下面这行对一下。

页面上「实测公式推算」那行就是这个函数的输出：**换机型时先看它和手调出来的「描边矩形」差多少**，一致就说明公式还成立，不用从零拖一遍滑块；对不上再调，然后把新的一组记在这儿。

顺带一个容易看走眼的点：`RoundedRectangle` 的圆角半径超过高度一半就会被夹成胶囊，所以圆角调到 24 和调到 40 画出来完全一样。页面上现在会在夹住时标一行「已夹成胶囊」。

叠加窗口不抢状态栏控制权这条**已实测**：打开描边后进站点浏览，「浏览时隐藏状态栏」照常生效。

### 进度环（环绕灵动岛）

设置 → 浏览 → 加载进度 →「环绕灵动岛」。默认仍是「顶部细条」，旧配置、旧导出文件里没有这个字段，按细条处理（`decodeIfPresent` + 默认值；认不出的值也当缺省，不让整份设置解码失败）。

**几何**

- 胶囊位置和尺寸一律走 `IslandEstimate.visiblePill`，不自己拿 rect 硬算。
- 环画在可见胶囊**外侧**，线的内边缘离胶囊留 `IslandRing.gap = 1.5pt`，线宽 `IslandRing.lineWidth = 2.5pt`。不能贴着边画：岛在所有 app 内容之上，压在边缘上的话内侧那半条线会被黑胶囊吃掉。两个常量都在 `Sources/Island/IslandRingResolver.swift` 顶上，调观感只动那一处。
- 描边的中心线矩形 = 胶囊四边各扩 `gap + lineWidth/2`，圆角 = 这个矩形高度的一半（`PillOutline` 直接按矩形高度算，不另存圆角），**和胶囊同心**，外扩之后仍然是胶囊形。
- 几何**只在**进浏览页、窗口尺寸变化（转屏）、scene 回到前台、改设置时重算，progress 变化只改 trim，不碰私有 API。尺寸量的是忽略安全区（含键盘）的整窗尺寸，所以弹键盘不会触发重算。转屏的检测用 SwiftUI 的 `onGeometryChange`，没用 `effectiveGeometry` 的 KVO——那个属性能不能 KVO，Apple 自己的说法前后不一，出错的方式是崩溃。
- **方向以视图自己量到的整窗尺寸为准**，scene 的方向和 `UIScreen.bounds` 只做交叉核对。转屏时这几样东西谁先更新没有文档保证：只信 scene 的话，竖→横那一刻它要是晚一步仍报竖屏、`UIScreen.bounds` 也还是竖的，就会在横屏界面上按竖屏坐标留一个环，之后也不会再有尺寸变化来触发重算。现在是：
  - 尺寸宽大于高 → 直接退回细条，**连私有 API 都不读**；
  - 尺寸是竖的，但 scene 还报横屏、或者 `UIScreen.bounds` 的宽度和视图宽度对不上（iPhone 上浏览页的窗口就是整块屏幕）→ 判为"转屏还在路上"，先画细条，300ms 后复查，最多 5 次（转屏动画 0.3–0.4 秒，足够盖住）。新的一次重算、或者离开浏览页会取消还没跑的复查。查满还对不上就一直是细条——这个方向只会"晚一点画上"，不会画错；
  - 三者一致 → 才去读 `_exclusionArea`。
- 环按**屏幕坐标**对准岛，画在浏览页这一层的 overlay 里，自己铺满整个窗口，再用 `frame(in: .global)` 换算回本地坐标。

**起笔和走向：从胶囊底边正中起笔，两边对称往上长，在顶边正中合拢。**

- 岛是屏幕正中一个左右对称的东西。单向绕圈的话，进度走到一半时整颗岛看上去是歪的，还很像系统的"转圈等待"；对称长法在任何时刻都是平衡的，也和"加载进度"这个语义更贴——它在"填满"，不是在"转"。
- 底边朝着网页内容，是眼睛最容易扫到的一侧；顶边离屏幕上沿只有十来个 pt，还挨着屏幕圆角。WebKit 的进度经常在前 10%–30% 停好一会儿，这一段应该落在最显眼的地方；合拢那一下发生在不起眼的顶边，紧接着就淡出了。
- 实现上是同一条胶囊路径剪两段（`trim(0, p/2)` 和 `trim(1-p/2, 1)`）。路径是手写的：起点固定在底边正中、左右镜像对称，顶边正中正好在全长一半处。没用 `Capsule().path(in:)`——它的起点和方向没有文档保证，而 trim 的 0/1 就落在起点上。圆弧用 `addArc(tangent1End:tangent2End:radius:)`，由切线唯一确定，不用操心 y 轴朝下时"顺时针"指哪边。
- 淡出和细条共用同一个 modifier（`loadingProgressFade`）：进度 0.2 秒缓出，加载完 0.4 秒淡出，保证两种样式行为永远一致。
- **刻意保留，不是 bug：新导航时环会带着动画往回收。** 进度从上一页的 1 直接跳回 0.1 左右，进度动画不分方向，环的两端一起往底边中点退回去（细条同理往左缩），同时从透明淡回来。这一下"收回去再重新长"正好交代了"换了一页、重新开始加载"。别为了"进度不该倒退"去掉动画或者按方向区分。

**什么时候退回顶部细条**（`IslandRingResolver`，选了环但下面任一条成立就画细条，不画错位的环）：

| 情况 | 为什么 |
|---|---|
| 不是 iPhone | iPad 没有灵动岛 |
| 横屏 | **待验证。** 横屏下 `_exclusionArea` 的坐标系、岛在哪条边上都没在真机上测过，这一版一律退回。带岛的 iPhone 不支持倒置竖屏（Info.plist 里 iPhone 也没开），所以"竖屏"只认 `.portrait` |
| `_exclusionArea` 没读到 | `IslandEstimate` 那组兜底常数只是 16 Pro 一台机器的实测值，拿来给未知设备画环大概率是错位的。**兜底常数只给实验室页占位用，进度环绝不用** |
| 读到了但不像灵动岛 | 见下 |

"像不像灵动岛"是几条互相独立的粗条件同时成立，每条都放得很宽，只拦明显不对的：

- **离屏幕顶 5–30pt**（实测 14）。刘海的避让区贴着顶边（y≈0），这是区分岛和刘海最硬的一条；
- **高 28–46、宽 95–165、宽高比 2.4–4.6**（实测 36.67 × 125，3.41）。刘海宽 200 多、宽高比 6 以上；私有 API 哪天变成返回整条状态栏或者一个 0 高的东西，也在这儿被拦下；
- **水平居中**，中心偏离屏幕中线不超过 2pt（实测只差半个设备像素）；
- **整个在屏幕范围内**。

范围以 16 Pro 的实测值为中心放宽了一大截，没有卡死在那一组数上——其他带岛机型没实测过。

**设置里的表现：选项在所有设备上照常显示、照常可选，选中后下面注明这台设备会不会生效。** 没有隐藏或禁用，是因为设置能导出导入：在 iPad 上改好配置导到 iPhone 上用是正常用法，藏起来或禁用会让这个值在不支持的设备上看不见、改不了。

**和其他界面的关系**

- **「浏览时隐藏状态栏」**：互不影响。灵动岛是硬件开孔加 SpringBoard 画的那颗胶囊，状态栏隐藏只藏时间、电池那些字，岛不受影响；环画在 app 内容层，不碰状态栏，也不走 `statusBarHidden`。状态栏显示时，时间和电池画在岛两侧较远处，环只比胶囊宽出 4pt，碰不到。
- **工具箱 sheet**：半屏档底下的页面不动、还能点，环照常显示；拉到**大档时环淡出**。大档在 iPhone 上是 page sheet，系统可能把底下的页面往后缩一点，环跟着页面缩就和岛错位了；况且大档时在看设置，不是在看加载。为此 sheet 的 detent 从 `ToolboxSheet` 的 `@State` 提到了 `BrowserScreen`（关掉时手动复位成半屏档，保持原来"每次都从半屏档开始"的行为）。大档时页面到底缩不缩、半屏→大档拖动过程中环会不会短暂偏一下，**待真机确认**。
- **弹窗（`fullScreenCover`）**：环在浏览页这一层，弹窗整个盖在上面，环跟着页面一起被盖住，不会浮在弹窗的导航栏上。弹窗里加载的是另一个 WebView，本来就不该显示主页面的进度。
- 实验室的描边窗口（`.normal + 1`）会压在环上面，这是调试用的，正好拿来对比环和岛的位置。

**已知限制：其他 app 的实时活动会把岛撑宽，环不会跟着变。** 音乐、计时器、导航之类的实时活动在后台跑时，岛会变成更宽的紧凑形态（两侧各多出一截），而 `_exclusionArea` 给的是**传感器避让区**，是固定的硬件开孔，不跟着变。查过的结论是 app 这边**没有任何办法**知道岛现在是什么形态：

- 公开 API 没有。ActivityKit 只能管自己 app 的实时活动，展开/收起由系统决定、不回调；Apple DTS 在论坛上明确答复过，app 不能影响别的 app 的实时活动显示（[Apple Developer Forums #804164](https://developer.apple.com/forums/thread/804164)）。
- 私有 API 也没有可用的：岛是 SpringBoard 进程里的 `SBSystemApertureWindowScene` 画的，第三方 app 进程里没有对应的对象可读（[pookjw 的逆向笔记](https://pookjw.github.io/Develop/Aperture_with_Clear_Color/article.html)）；专门做这件事的开源库 DynamicIslandUtilities 也写明只能拿到静态尺寸，"有实时活动时岛会变大"不在它能力范围内。

所以此时环绕的仍是没展开时那颗胶囊的外圈，会被展开的岛部分盖住。**不做猜测逻辑**（比如看有没有在放音乐），这种猜法猜错了比不猜更难看。真在意的话在有实时活动时切回细条。

---

## 按 profile 配 HTTPS 代理

设置 → **网络代理**，或者站点设置 / 工具箱大档里「存储与网络」那一组的**网络代理**一行。任何 profile（包括临时站点共用的那个，以及几个站点共用的）都可以单独配一个 HTTPS 代理，每个 profile 自己开关，关掉就是直连。

这里的「HTTPS 代理」指 **app 和代理之间走 TLS**，隧道用 HTTP CONNECT（也就是 CONNECT over TLS）。支持用户名密码（`Proxy-Authorization: Basic`）。

### 为什么挂在 profile 上，界面怎么讲清楚

网络走哪条路是 `WKWebsiteDataStore.proxyConfigurations` 决定的，而 data store 是按 profile 一个的（见 `WebsiteDataStoreManager` 的坑 2：一个标识只能有一个实例）。所以**同一个 profile 的站点不可能走不同的代理**，代理只能挂在 profile 上。

profile 原来在界面上只是站点里的一个字符串，这次第一次把它当成一个东西列出来：

- **设置 → 网络代理**按 profile 列。只有一个站点在用的（默认的"一站一个 profile"），直接叫那个站点的名字；几个站点共用的，叫 profile 名，下面列出是哪几个站点；临时站点单独一行。站点删了但配置还在的，归到"没有站点在用的配置"，左滑删除（连同 Keychain 里的密码）。
- **代理编辑页顶上**先说影响范围：共用 profile 的写"⚠︎ 这 N 个站点共用这个 profile，改了代理它们全都跟着变"，临时站点那一行写"影响所有临时站点"。
- **站点设置**里代理那一行放在 profile 选择的正下面，分区改名「存储与网络」，脚注再说一遍"共用 profile 的站点也共用同一个代理"。这一行用 sheet 打开编辑页，因为工具箱 sheet 刻意没有 NavigationStack，push 不了。

### 两种连接方式

| | 本地中继（默认） | 直连代理 |
|---|---|---|
| 怎么走 | WKWebView → `127.0.0.1:随机端口`（明文，只在回环接口）→ app 里的中继 → TLS → 上游代理 | WKWebView 的网络进程直接 TLS 连上游代理，app 不参与转发 |
| 实现 | `NWListener` + `NWConnection`，证书校验在 app 进程的 verify block 里 | `ProxyConfiguration(httpCONNECTProxy:tlsOptions:)` |
| 系统验证 | ✅ | ✅ |
| 公钥指纹 | ✅ | ❌ WKWebView 不调 verify block |
| 不验证 | ✅ | ❌ 同上 |
| 失败原因 | 分得清：连不上 / 握手失败 / 证书不对 / 407 / 代理拒绝 | 只有 WebKit 给的错误码，分不清是代理的证书还是站点的证书 |
| 依赖 | app 在前台（后台挂起期间中继不工作，见下） | WebKit bug 264307 是否已修（**待真机验证**） |

两种方式**共用同一组地址、端口、用户名、密码、验证方式和指纹**，切换方式不用重填。直连模式下选了指纹或不验证，选项旁边标「（直连不支持）」，下面出一行红字，保存会被拒绝——不偷偷降级成系统验证，也不偷偷改成本地中继。「测试连接」拿到指纹后点「用这个指纹」，会同时把方式切到本地中继。

**新建配置默认用本地中继。** 理由：

1. 三种验证都支持，而自签证书恰恰是自己搭 HTTPS 代理最常见的情况；
2. 失败原因分得清，用户能看出"代理不通"还是"证书不对"——这是需求里的硬要求，直连模式做不到；
3. 绕开了 WebKit bug 264307（给 WebKit 的是 `tlsOptions: nil` 的明文本地代理，不涉及 TLS 选项的跨进程序列化）；
4. 代价是中继跑在 app 进程里，app 被挂起时它也停了。但 Husk 的网页本来就只在前台看，WebView 在后台时同样被挂起，这个代价几乎不可见。

### 查证过的事实（2026-09）

| 问题 | 结论 | 来源 |
|---|---|---|
| `proxyConfigurations` 的 TLS verify block 在 WKWebView 下调不调 | **不调**，自签证书直接 -1202。帖子里没有 Apple 回复，没有修复记录 | [Apple 论坛 750644](https://developer.apple.com/forums/thread/750644) |
| WebKit bug 264307（CONNECT 带 TLS 选项时网络进程崩溃）修没修 | bugs.webkit.org 上状态仍是 **NEW**，无修复提交，内部 rdar://118028072。找不到 iOS 26 上的定论 → 照样实现，标成待真机验证，实验室有专门一项测它 | [bug 264307](https://bugs.webkit.org/show_bug.cgi?id=264307) |
| `allowFailover` 默认值 | 文档原话 "Failover isn't allowed by default"。代码里照样显式写 `false` | [ProxyConfiguration.allowFailover](https://developer.apple.com/documentation/network/proxyconfiguration/allowfailover) |
| HTTP CONNECT 代理转不转 UDP | 不转。文档原话 "These HTTP CONNECT proxies only handle TCP connections" | [init(httpCONNECTProxy:tlsOptions:)](https://developer.apple.com/documentation/network/proxyconfiguration/init(httpconnectproxy:tlsoptions:)) |
| `applyCredential` 在 WKWebView 下能不能用 | **有争议**。2023 年 DTS 在论坛确认是 bug（r. 113346270，FB13350370），真机上会弹系统的"需要代理认证"框；2026 年有开源项目在较新系统上实测凭据确实发出去了。结论：**不能单押它**，见下面的"两条腿" | [论坛 734679](https://developer.apple.com/forums/thread/734679)、[webspace_app #603/#604](https://github.com/theoden8/webspace_app/pull/604) |
| 本机别的 app 能不能连 127.0.0.1 上的端口 | **能**。iOS 的回环接口全设备共用，沙盒不隔离它（app 和扩展之间拿 localhost 通信就是靠这个）；只是被挂起的 app 连不了。所以本地一跳必须防蹭 | [论坛 712626](https://developer.apple.com/forums/thread/712626)、[论坛 724864](https://developer.apple.com/forums/thread/724864) |
| 监听端口在后台 | TN2277：挂起期间监听套接字可能被系统回收，且挂起时进来的连接没人处理 → **进后台关监听、回前台重开** | [TN2277](https://developer.apple.com/library/archive/technotes/tn2277/_index.html) |
| `NWListener` 的 `requiredLocalEndpoint` | 有报告说 listener 会忽略它、照样绑临时端口 → 不靠它，改用 `requiredInterfaceType = .loopback` + `NWListener(using:on:)`，再在接连接时检查对端是不是回环地址（第二道闸） | [dinky #28](https://github.com/heyderekj/dinky/pull/28) |
| WebKit 绕开代理的泄露口 | 三个：DNS 预取（iOS 26.0 起）、WebAuthn Related Origin 请求（iOS 18.0 起）、WebTransport（iOS 26.4 起）。都不走 `proxyConfigurations` | [Mysk 2026-08-04](https://mysk.blog/2026/08/04/webkit-proxy-icloud-private-relay-ip-leak/) |
| 代理认证 challenge 的 async 委托方法名 | `webView(_:respondTo:) async -> (AuthChallengeDisposition, URLCredential?)` | [WKNavigationDelegate](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webview(_:didreceive:completionhandler:)) |

### 本地中继

`Sources/Proxy/`：`LocalRelay`（监听）、`RelayConnection`（一条客户端连接）、`UpstreamLink`（到上游的一条 TLS 连接）、`ConnectionIO`（读头、双向对拷）。

**每个 profile 一个监听，不是全 app 共用一个。** 端口本身就标识了 profile，中继不用靠凭据反查"这条连接是谁的"；于是本地凭据只干"防蹭"一件事。万一 `applyCredential` 在某个系统上真坏了，实验室里关掉凭据校验照样能用，不用改架构。十几个监听不过是十几个文件描述符。

**防蹭：本地一跳的随机凭据。** 用户名固定 `husk`，密码每次启动 `SecRandomCopyBytes` 生成 24 字节、只在内存里。比对用常量时间，免得本机别的 app 靠计时一位一位猜。凭据通过**两条腿**交给 WebKit：

1. `ProxyConfiguration.applyCredential`——正常情况下它就够了；
2. `WKNavigationDelegate.webView(_:respondTo:)`——`applyCredential` 失灵、中继回 407 时，这里按同一份凭据再答一次。开了代理的 profile **绝不**走默认处理（默认处理在真机上会弹系统的认证框，用户在里面填什么都和 Husk 的设置对不上），答不上就取消，页面报错。

两条腿都断了的表现是：页面一直失败，实验室里「认证拒绝」计数一直涨。这时可以临时打开实验室的「本地一跳不校验凭据」，代价是本机别的 app 猜到端口就能借你的代理出网——所以它只存 UserDefaults，不进导出，默认关。

"在监听端校验连接来源"做不到：TCP 回环连接拿不到对端进程，`LOCAL_PEERPID` 只对 Unix 域套接字有效，而 `ProxyConfiguration` 只收 `NWEndpoint.hostPort`。

**CONNECT 和绝对形式都接。** `ProxyConfiguration(httpCONNECTProxy:)` 按名字应该对 `http://` 也开 CONNECT 隧道，但查不到 WKWebView 的明确说法，而同类项目的中继确实收到过绝对形式的请求，所以两种都处理：

- `CONNECT host:port` → 向上游发同样的 CONNECT，2xx 后两边对接成透明隧道；
- `GET http://host/path HTTP/1.1`（绝对形式）→ 原样转给上游（上游本来就是 HTTP 代理，这是它的本职；不改成 CONNECT 到 80 端口，因为很多代理默认只许 CONNECT 443），换掉 `Proxy-Authorization`，强制 `Connection: close`——一条连接只跑一个请求，中继就不用理解 keep-alive 的分帧。上游回 407 时不原样转给 WebKit（会弹系统认证框），换成 502。
- 源形式（`GET /path`）说明对方把中继当成了普通服务器，回 400。

对拷是"写完一段再读下一段"，天然有背压；一边读到 EOF 就向另一边半关闭，两边都结束才关。

**进后台 / 回前台。** 按 TN2277：`didEnterBackground` 时记下端口、关掉监听；`willEnterForeground` 时**先试原端口**。拿回原端口的话 `proxyConfigurations` 一个字都不用改，页面无感（Apple 文档说改代理配置会打断进行中的请求，所以能不改就不改）。原端口被占了就换一个新端口、更新 `proxyConfigurations`，并让这个 profile 开着的页面重建。已经建好的隧道不动（数据连接，TN2277 允许留着，被回收了自己会报错断开）。监听关着的那段时间里 WebView 发出的请求会连接失败——是失败，不是直连。

同一个 profile 同时有几处要起中继（浏览页、保存设置、图标抓取、回前台）时合并成一次，否则后一次会把前一次正在起的监听顶掉。

### 代理证书的三种验证

| 方式 | 做什么 | 适合 |
|---|---|---|
| 系统验证 | `SecPolicyCreateSSL(true, 代理主机名)` + `SecTrustEvaluateWithError`：系统信任链 + 主机名 | 代理用的是正经 CA 签的证书 |
| 公钥指纹 | 叶子证书 **SPKI 的 SHA-256** 命中列表里任意一个即通过，不看信任链和主机名 | 自签证书 |
| 不验证 | 什么证书都收 | 只在排查时临时用，界面上有橙色警告 |

**为什么是 SPKI 的 SHA-256，而不是整张证书的 SHA-256：**

- 续签时只要密钥不变，SPKI 指纹就不变；整张证书的指纹**每次续签都变**（有效期、序列号都在里面）。代理证书一年一续甚至三个月一续，按整张证书比对等于每次续签都要回来改配置，忘了就是全站打不开。
- 这是 RFC 7469（HPKP）和 curl `--pinnedpubkey` 选的写法，`sha256//<base64>` 大家都认得，自己搭代理的人手边的工具能直接算出来。
- SPKI 是从证书 DER 里原样切出来的（`CertificateFingerprint.subjectPublicKeyInfo`），不用 `SecKeyCopyExternalRepresentation`——后者给的是裸公钥（RSA 是 PKCS#1、EC 是 X9.63 点），得按密钥类型自己补 ASN.1 头，漏一种类型就算错一种。

**支持多个指纹**，命中任意一个即通过：换密钥时新旧两个都填上，服务器换完再删旧的，中间不断。

**只比叶子证书，不比链上的其他证书。** 指纹模式不验证签名链，如果"链上任意一张命中就放行"，攻击者把公开的中间证书塞进自己出示的链里就骗过去了。

填写格式：`sha256/` 开头的 base64（`sha256//` 也认），或者 64 位十六进制（冒号、空格可有可无）。存的时候统一规范化成 base64。

**「测试连接」**用的是和中继完全相同的代码（`UpstreamLink`）：TCP → TLS → 按所选方式验证 → 发一次 `CONNECT www.apple.com:443`（只建隧道不发数据）。结果里有证书主体、系统信任链是否通过（三种模式都会算一遍）、**公钥指纹**（点按复制，或者「用这个指纹」直接填进去）、整张证书的 SHA-256（只供和浏览器 / openssl 核对，不拿来比对）、CONNECT 的响应。指纹模式下一个指纹都还没填时也允许测——测的目的之一就是拿到指纹。直连模式下它只能说明"代理本身是好的"，WebKit 那条路能不能通去实验室测。

### 失败时的行为

**开了代理的 profile，任何环节失败都是报错，没有任何代码路径会回落成直连：**

- 代理就绪之前**不建 WebView**。浏览页先问 `ProxyManager.readiness`：没开代理、或者代理已经就绪（直连模式配置已落到 store 上 / 中继已在监听）的，第一帧照常有 WebView，和以前一样不闪；要等中继起来的，先显示"正在连接代理…"；配置不完整、缺密码、中继起不来的，直接显示失败界面。
- `allowFailover = false` 显式写上。
- 中继里根本没有直连的代码：上游连不上、握手失败、证书不对、407、代理拒绝，统统回 502（带 `X-Husk-Proxy-Error` 头）并关连接。
- 密码缺了（典型场景：刚从别的设备导入）不是"那就不认证"，而是报"代理需要密码"。
- 图标抓取拿不到走代理的 session 时**不抓**，不拿 `URLSession.shared` 凑合。

失败界面复用原来那个，标题和图标按原因分：

| 标题 | 什么时候 |
|---|---|
| 代理配置不完整 | 没地址、端口不对、指纹模式没填指纹、直连选了不支持的验证、缺密码 |
| 代理连不上 | DNS、拒绝连接、超时、TLS 握手失败、代理回非 2xx、中继起不来 |
| 代理的证书没通过验证 | 系统验证不过（附系统给的原因）、指纹不匹配（附代理实际出示的指纹） |
| 代理拒绝了用户名或密码 | 上游回 407 |
| 站点的证书没通过验证 | 本地中继模式下中继没报错、页面却报证书错——那就是站点自己的证书（或者代理在中间换了证书） |

本地中继模式下靠"中继最近 20 秒报过什么错"来判断是不是代理的锅；直连模式下 WebKit 只给错误码，证书类错误会同时点出"代理或站点"两种可能，并建议换本地中继。失败界面在开了代理的 profile 上多一个「网络代理」按钮直达设置——没有 WebView 就没有手势，工具箱唤不出来。

### 改了代理配置后，已经打开的页面

**自动拆掉 WebView、重建、重新加载当前地址**，不提示。

代理开关是出口 IP 级别的事：刚把代理打开，已经打开的页面却还在按旧路发请求，恰恰是用户最不想要的；而 Apple 文档说改 `proxyConfigurations` 本来就会打断进行中的请求，页面状态本来也保不住。重建而不只是 reload，是因为 WebRTC / WebTransport 的关闭是在 configuration 上做的，只有新建的 WebView 才吃得到。

顺序是**先拆后配**：`configurationDidChange` 先 bump 版本号，浏览页立刻进入"准备中"、不再渲染旧 WebView，然后才准备新配置。代价：当前页的前进后退历史、没提交的表单会丢；弹窗会被关掉。站点换了 profile（存储那一组里改的）也走同一条路。

### 会绕开代理的东西，以及怎么堵

| 泄露 | 为什么绕开 | 怎么堵 | 可靠程度 |
|---|---|---|---|
| **WebRTC** | ICE 用 UDP 问 STUN，HTTP CONNECT 代理只转 TCP，出去的就是真实 IP | 私有偏好 `-[WKPreferences _setPeerConnectionEnabled:]` = NO；再用脚本删掉 `RTCPeerConnection` | 私有开关是主力；实验室能看到它关没关上 |
| **WebTransport**（iOS 26.4 起） | WebKit 自己拼 QUIC 连接，不带会话的代理设置 | `+[WKPreferences _features]` 里 `WebTransportEnabled` 那项 `_setEnabled:forFeature:` 关掉；脚本删构造器 | 同上 |
| **DNS 预取**（iOS 26.0 起） | `<link rel=dns-prefetch>` 让网络进程直接调系统解析 | 内容规则拦 `ping` 类型的资源——对着 WebKit 源码确认过，`FrameLoader::prefetchDNSIfNeeded` 在发 DNS 预取前会按 `ResourceType::Ping` 过一遍内容规则 | **待真机验证**：iOS 26 自带的 WebKit 里有没有这段检查没法从外面确认 |
| **通行密钥 Related Origin 请求** | 系统凭据服务自己去取 `/.well-known/webauthn`，不在 WebKit 的会话里 | 没有私有开关可用，只能脚本把 `navigator.credentials.get/create` 拒掉、删 `PublicKeyCredential` | **尽力而为**：页面刻意绕（比如从新建的 iframe 里拿干净的原型）挡不住 |

以上**只对开了代理的 profile 生效**，没开代理的 profile 一样都不碰。副作用：开了代理的 profile 里视频通话、通行密钥登录不可用；`ping` 规则顺带拦掉 `navigator.sendBeacon` 和 `<a ping>`（本来就走代理，拦掉只是统计打点发不出去）。

私有 API 的用法和灵动岛那套一样：每一步先 `responds(to:)`，不在就原地放弃。两个开关都没了的话，脚本那一层还在。

### app 自己发出的请求

**图标抓取跟着站点所在 profile 走代理。** 图标请求会把"这台设备对这个站点感兴趣"连同真实 IP 告诉站点（和 Google favicon 服务），对开了代理的站点来说这就是泄露。实现：`ProxyManager.urlSession(forProfile:)` 给一个 `URLSessionConfiguration.proxyConfigurations` 和 WebView 完全相同的 session；没开代理的站点照旧 `URLSession.shared`；开了代理但没就绪时返回 nil，这次就不抓。

其他 app 侧请求：快捷指令、App Intents、存相册都不联网；实验室「出口 IP 对比」的第一行是**刻意**直连的（要拿真实 IP 做对比），按钮下面写明了。

### 密码与导入导出

- 密码存 Keychain（`kSecClassGenericPassword`，service `Husk.proxy`，account 是 profile 名），`AfterFirstUnlockThisDeviceOnly`：锁屏时被快捷指令唤起也能读；不进 iCloud 钥匙串、不随备份迁移。
- 代理的地址、端口、用户名、连接方式、验证方式、指纹放在库文件顶层的 `profileProxies`（profile 名 → 配置），**照常进导出**。放顶层而不是 `settings` 里：它跟着 profile 走，导入站点时要一起进来，不该受「导入时一并覆盖全局设置」那个开关管。
- **导出不带密码，不询问。** 导出文件是明文 JSON，会被发到各种地方；"导出前问一句"的结果多半是顺手点了"包含"。代价是换设备要重填密码——导入后要密码的 profile 会报"代理需要密码"（不是直连），导入结果的提示里会写"N 个代理要补密码"。
- 旧配置 / 旧导出文件里没有 `profileProxies` → 按"没配代理"处理（`decodeIfPresent` + 默认 `[:]`）。
- **条目存在但某个字段坏了**，不能让它消失（那等于静默改成直连）：`ProfileProxy` 每个字段单独兜底，`isEnabled` 缺省为 true，认不出的验证方式按最严格的系统验证，地址缺了会在加载时报"配置不完整"。
- 导入合并：本机没人用的 profile，导入的代理配置直接收下；本机已经有站点在用的 profile，只有选了「覆盖已有」才动，另外两种一律保留本机现状（包括"本机没配代理"这个现状）。「都留着（新建副本）」时副本换了新 profile，代理配置跟着搬过去，不然副本会悄悄不走代理。

### 实验室 → 代理诊断

给真机验证用：

1. **直连模式实测**：拿所选 profile 的地址和认证，临时拼一个 `ProxyConfiguration(httpCONNECTProxy:, tlsOptions: 默认)` 给一次性的 data store，用真 WKWebView 加载一次。结果是成功、失败（错误连同 underlying 链原样展开）、还是超时——网络进程崩溃（bug 264307）的典型表现就是超时或者 `NSURLErrorNetworkConnectionLost`，配合 Console 里 `com.apple.WebKit.Networking` 的日志看。
2. **出口 IP 对比**：app 直连问一次，再用这个 profile 的真 data store 在**同一个 WebView 里连续导航两次**。第二次专门查"第一次走代理、后面的导航走直连"这种有人报告过的问题（[webspace_app #609](https://github.com/theoden8/webspace_app/pull/609)，Flutter 封装，不确定是不是它自己的问题）。
3. **中继状态**：端口、隧道数、认证拒绝数、失败数、最近一次上游错误。
4. **加固是否生效**：WebRTC / WebTransport 的私有开关关没关上、DNS 预取规则编没编好。
5. 「本地一跳不校验凭据」开关（见上）和一键复制诊断结果。

### 已知限制

- **app 在后台时本地中继不工作。** 后台里 WebView 发出的请求会失败（不是直连）。回前台自动恢复。
- **直连代理模式只能系统验证**，而且分不清是代理的证书还是站点的证书出了问题。
- **通行密钥的泄露只能尽力而为**，挡不住刻意绕的页面；介意的话别在开了代理的 profile 里用通行密钥。
- **开了代理的 profile 里 WebRTC 用不了**（视频会议、网页版语音）。这是有意的，没做"允许 WebRTC"的开关——HTTP CONNECT 代理根本转不了 UDP，允许就等于泄露。
- **改代理配置会重建已打开的页面**，前进后退历史和未提交的表单会丢。
- **本地一跳是明文**，只在回环接口上跑。本机别的 app 在前台时理论上能嗅探到端口号，但没有凭据用不了；能读 app 内存的恶意软件本来就不在防御范围里。
- 上游代理只支持 **HTTP/1.1 CONNECT over TLS**，不支持 HTTP/2 / HTTP/3 的 CONNECT，也不支持 SOCKS。
- 代理地址只填主机名或 IP，不带 scheme 和路径。IPv6 地址直接填（不带方括号）。

### 需要真机验证的

没有 Xcode 也没有设备，下面这些只做到了"CI 编译通过、逻辑按文档写"：

- [ ] **直连模式在 iOS 26 上能不能跑通**（bug 264307）——实验室「直连模式实测」
- [ ] **`applyCredential` 对本地中继生效没有**——正常浏览时实验室里「认证拒绝」不涨就是生效了；涨了但页面能开，说明是 `respondTo` 那条腿在答；两条都不行就只能临时关凭据校验
- [ ] **WKWebView 访问 `http://` 时走 CONNECT 还是绝对形式**——两种都实现了，但哪种真被用到没测过
- [ ] **出口 IP**：两次导航都是代理 IP——实验室「出口 IP 对比」
- [ ] **WebRTC / WebTransport 的私有开关在 iOS 26 上还在、还管用**——实验室「状态」；再用 browserleaks.com/webrtc 这类页面交叉验证
- [ ] **DNS 预取拦截**：iOS 26 自带的 WebKit 有没有 `prefetchDNSIfNeeded` 里那段内容规则检查——需要抓 DNS 包
- [ ] **回前台拿回原端口**的成功率，以及拿不回时页面重建的体验
- [ ] **图标抓取经本地中继**：URLSession 对 `127.0.0.1` 明文代理会不会被 ATS 拦（按理 ATS 管的是目标站点，不是代理这一跳）
- [ ] **`requiredInterfaceType = .loopback` 的监听**用 `127.0.0.1` 能不能连上（有可能只绑了 `::1`）

---

## 不闪首页是怎么做到的

原来的症状：从快捷指令用 `husk://open?id=…` 打开，总能看见约 0.3 秒首页再进网页；
已经在站 A 时跳站 B，还会先退回首页再盖上去。三个原因叠在一起：

1. `BrowserScreen` 是 `.fullScreenCover` 呈现的——模态本身就意味着"先有个底下的东西，再上滑盖住"，换站还得先 dismiss 再 present；
2. 冷启动留了 140ms 挡板等 `onOpenURL`；
3. 首页有 0.2s 淡入。

现在三条都没了：

**浏览界面改成根视图级的一层**（`Sources/App/HuskApp.swift` 的 `RootView`）。
首页和浏览界面在同一个 `ZStack` 里，浏览界面直接盖在首页上；换站就是换一个 `id`，
中间没有任何一帧属于别人。首页**留在层级里**而不是被 `if/else` 换掉，
这样从站点退回来时 tab 选中项和滚动位置都还在。

从首页点进去仍然有过渡动画（`withAnimation`）；deep link 和快捷指令那两条路
走 `Transaction.disablesAnimations`，直接换。

**冷启动的 URL 提前到第一帧之前拿**（`Sources/App/AppDelegate.swift`）：
`application(_:configurationForConnecting:options:)` 比 `onOpenURL` 早得多——
scene 都还没连上，`UIScene.ConnectionOptions.urlContexts` 里已经有这次启动带来的 URL 了。
在那儿写进 `Router.shared`，`WindowGroup` 第一次求值时就已经是"正在浏览"的状态。
140ms 挡板和首页淡入一起删掉了。

因为这个，`Router` / `SiteStore` / `IconStore` 都改成了进程级单例：
AppDelegate 和 App Intents 都够不着 SwiftUI 的 `@State`。

**SwiftUI 之后还会把同一个 URL 再送一次给 `onOpenURL`**，两条路径都存在、
谁先谁后不保证，所以 `Router` 记下冷启动那一条做去重。

**快捷指令走的是 iOS 26 的 scene 派发**：`OpenSiteIntent` 带上
`TargetContentProvidingIntent` 之后，系统会在把 app 端到前台**之前**先把 intent
送给场景（`RootView` 的 `.onAppIntentExecution`），给我们一次在第一帧之前
把根视图摆好的机会。这条路要求 Info.plist 里声明
`UIApplicationSceneManifest.UIApplicationSupportsMultipleScenes = YES`，
哪怕实际上只有一个窗口——Apple 文档明写了这一条。
`perform()` 里还留了一次兜底调用：万一派发没发生，站点照样能打开，
而重复调用本来就是空操作。

### 打开的就是当前站点时，什么都不动

三个入口（URL scheme、快捷指令、首页点击）最后都汇到 `Router.open`，
它开头就一句 `guard !isShowing(...)`：目标就是当前显示的那个站点时**直接返回**——
不重建会话、不重载、不回站点首页、不换 `id`。

判断粒度：

- **列表里的站点**按 `id` 判。地址、缩放、UA 之后改了都还是同一个站。
- **临时站点**（`husk://open?url=`）按**去掉 fragment 的完整 URL** 判。
  没有 id 可依；只按 host 又太粗——同一个站的两篇文章会被当成同一个目标，
  表现就是"打开另一篇却什么都不发生"。fragment 不算，因为 `#anchor` 的差别
  是页内跳转，为它重建整个会话没有道理。

（顺带：原来 `ActiveSite` 的注释写着"临时站点每次都换 id，这样连着开两次同一个地址也会重建会话"——
那条行为现在被明确推翻了。）

---

## 外链判断

严格程度三档，只在外链策略是「按域名判断」时起作用：

| 档位 | 含义 |
|---|---|
| 仅本主机 | 只有 `example.com` 自己算站内（`www.` 视为同一个） |
| 本主机及子域 | 加上 `a.example.com`、`a.b.example.com` |
| **同一可注册域**（默认） | 两边都归约到 eTLD+1 再比，`m.youtube.com` ↔ `www.youtube.com` 算同一站 |

每个站点还有两份手动例外名单，**优先于档位**：

- **也算站内** —— 自家短链、CDN、登录中心（`b23.tv`、`youtu.be`、`*.ytimg.com`）
- **强制 Safari** —— 优先级最高，压得过一切，包括「站内加载」策略和登录流放行

写法两种，含义**刻意不同**：`example.com` 只匹配这一个主机（`www.` 归一），
`*.example.com` 连同它的任意层级子域一起。不把裸域名也当成"连子域一起"，
是为了让通配符这个写法有意义。

### Public Suffix List

「同一可注册域」这一档以前靠一张手写的常见多段后缀表（`co.uk`、`com.cn` 之类），
漏掉了 `github.io`、`vercel.app` 这种"托管型"公共后缀——`a.github.io` 和
`b.github.io` 会被算成同一站。现在**打包了完整的 PSL**：

- `Resources/public_suffix_list.dat`，官方列表去掉注释和空行（约 10000 条 / 145KB）
- **ICANN 段和 PRIVATE 段都留着**：`github.io` 正在 PRIVATE 段里，丢掉它就白换了
- 解析按 publicsuffix.org 的算法：例外规则（`!`）最优先，然后通配（`*.`），再取最长匹配
- 惰性解析（`static let`），只在第一次判外链时发生

数据文件带 VERSION 注释，更新时直接从 <https://publicsuffix.org/list/public_suffix_list.dat>
重新拉一份、去掉注释行即可。

---

## 缩放：10%–200%

下限从 50% 拉到 10%。**`WKWebView.pageZoom` 自己不做任何钳位**——
setter 一路直通 `WebPageProxy::setPageZoomFactor` → `LocalFrame::setPageAndTextZoomFactors`，
中间没有 clamp（对着 WebKit 源码确认过）。所以范围完全由 app 说了算；
下限留着是因为 0 会把缩放换算里的除法搞炸。

线性滑块在这个范围里不好使：10%–100% 要占掉滑轨的 47%，而日常真正会调的
90%–125% 挤在中间几个像素里，想停在 100% 基本靠运气。所以**滑块绑的是一张档位表的下标**
（`Sources/Models/ZoomScale.swift`）：

```
10 15 20 25 33 40 50 60 67 75 80 90 │ 100 │ 110 125 140 150 175 200  (%)
```

低段跨度大、常用段跨度小，每一格都是个能说出口的数，而且一定停得到 100%。
旁边还有个「重置」直接回 100%。表外的老配置值（比如 0.85）会落到最近的一格上。

---

## 代码结构

```
Sources/
  App/          入口、根视图、AppDelegate（冷启动 URL）、路由、husk:// 解析
  Models/       Site / AppSettings / UA 预设 / 外链档位 / PSL / 缩放档位表
  Storage/      JSON 持久化、WKWebsiteDataStore 多 profile 管理、代理密码的 Keychain
  Icons/        图标抓取、ICO 拆包、首字母占位图、主屏图标导出、存相册
  Intents/      AppEntity、「打开站点」intent、AppShortcutsProvider
  WebKitLayer/  WKWebView 装配、导航策略、弹窗、手势
  Browser/      浏览界面、进度条 / 灵动岛进度环、工具箱 sheet
  Home/         TabView、站点网格、"继续上次"
  SettingsUI/   站点设置、共用的本站设置分区、全局设置、存储管理、代理设置
  Island/       灵动岛几何：`_exclusionArea` 安全读取、实测公式、进度环判定（浏览页和实验室共用）
  Proxy/        按 profile 的 HTTPS 代理：本地中继、上游 TLS 与证书指纹、泄露加固、ProxyManager
  Lab/          实验室：灵动岛诊断页、描边叠加窗口、代理诊断
  Util/         主题、玻璃提示条、分享面板
Resources/
  public_suffix_list.dat
```

单文件都在 300 行以内。所有踩过的坑在代码里都有注释写明原因，别顺手"优化"掉。

### 持久化为什么选 Codable + JSON 而不是 SwiftData

1. **导入导出是核心功能**，JSON 本来就是交换格式，用同一套 `Codable` 省掉一层模型转换
2. 数据量是十几条站点配置，用数据库属于杀鸡用牛刀，还要背上 schema 迁移的包袱
3. SwiftData 的 `@Model` 是引用类型且带 actor 隔离，在 Swift 6 严格并发下跨 View 传递很别扭；`Site` 是纯值类型 `Sendable`，随便传

存在 `Application Support/Husk/library.json`，原子写。解码对每个字段都做了缺省兜底，旧版本导出的文件不会因为多了个新字段就整份失败。

---

## 已查证的 WebKit 坑

这几条都在代码里有对应注释，这里是索引：

| 坑 | 位置 |
|---|---|
| `WKWebsiteDataStore(forIdentifier:)` 收 `UUID` 不是字符串；用 SHA256 前 16 字节做稳定映射 | `Storage/WebsiteDataStoreManager.swift` |
| **每次调用返回全新对象**，同一 UUID 拿到两个实例会静默失去进程共享 → 必须做实例缓存 | 同上 |
| `WKProcessPool` 已废弃、不再影响进程共享，没有使用 | — |
| `remove(forIdentifier:)` 有引用存活时抛 `Data store is in use`，先断引用再重试 5×250ms | 同上 |
| 默认 store 删不掉，只能 `removeData(ofTypes:modifiedSince:)`，"清除全部"两条路都走 | 同上 |
| `fetchAllDataStoreIdentifiers` 查存在性做孤儿清理，不能拿 `init(forIdentifier:)` 试探 | 同上 |
| `createWebViewWith` 必须用 WebKit 递来的 configuration，否则 `window.opener` 变 null | `WebKitLayer/WebCoordinator+UI.swift` |
| 那个 configuration 没走初始化路径，user script / message handler 要重挂 | `WebKitLayer/WebViewFactory.swift` |
| `pageZoom` 要在 `didFinish` 之后设，太早会被导航重置 | 同上 |
| `customUserAgent` 改完要 `reload()` 才对当前页生效 | `WebKitLayer/BrowserWebView.swift` |
| 深色白闪：`isOpaque = false` + 深色 `backgroundColor` | `WebKitLayer/WebViewFactory.swift` |
| **`pageZoom` 的 setter 一路不做钳位**，直通 `WebPageProxy::setPageZoomFactor` → `LocalFrame::setPageAndTextZoomFactors`，范围由 app 自己定 | `Models/Site.swift` |
| **delegate 要用 async 变体**：iOS 18 起 WebKit 给 completion handler 加了 `@MainActor`，旧签名只"近似匹配"，编译器仅给 warning 而运行时**根本不调用** | `WebKitLayer/WebCoordinator.swift` |

另外补了几个文档里不显眼的：

- **`UIImage` 在 iOS 上不解码 `.ico`**，直接给 nil。`Icons/ICOUnpacker.swift` 从 `favicon.ico` 里把内嵌的 PNG 子图拆出来（现代站点基本都是 PNG-in-ICO）。
- **首字母占位图的颜色不能用 `hashValue` 派生**，Swift 的字符串哈希每次启动换 seed，同一个站点每次启动都会换颜色。改用自己写的稳定累加。
- **`tabViewBottomAccessory` 的内容不能在"有"和"没有"之间跳**——切个 tab 回来就撞
  `_bottomAccessory.displayStyle` 的断言崩溃（FB18479195）。没有"上次记录"时
  **连 modifier 一起不加**，见 `Home/HomeTabs.swift`。分支之间换内容（`.expanded` ↔ `.inline`
  两种摆法）是安全的，空 ↔ 非空不是。
- **App Intents 要派发给场景，得声明 `UIApplicationSupportsMultipleScenes = YES`**，
  哪怕 app 只有一个窗口。Apple 文档里这条写在正文的 Important 框里，很容易漏。

---

## 相对于需求描述，我改了/补了这些

1. **「回首页」拆成两个按钮** —— 原描述里这个词有歧义：是回站点的首页，还是回 Husk 的站点列表？工具箱里两个都给了，叫「站点首页」和「返回列表」。

2. **底边上滑没用 `UIScreenEdgePanGestureRecognizer(.bottom)`** —— 屏幕底边被系统的主屏指示器占着，边缘 pan 要靠 `preferredScreenEdgesDeferringSystemGestures` 去抢，体验是"得划两次"。改成 `UISwipeGestureRecognizer(.up)` + 起手位置限定在底部 32pt，判定快、失败也快，不会把页面滚动卡住。

3. **加了个逃生按钮** —— 四个手势全关掉的话就没法唤出工具箱，等于被困在站点里出不去了。这种情况下浏览页右下角会出现一个不起眼的小圆点。

4. **实现了 JS 的 `alert` / `confirm` / `prompt`** —— 不实现这三个 `WKUIDelegate` 方法的话，这些调用在 WKWebView 里是"什么都不发生"，而且 `confirm` 永远返回 false。对一个当 app 用的容器来说这是明显的功能缺失。

5. **注入了一个极小的 user script** —— 把页面根元素的背景色报回来，用它刷 WebView 的 `backgroundColor`，这样过度滚动露出来的那条边和页面同色。顺带它也是"弹窗要重挂 configuration 层面的东西"这件事的具体例子，不然那段注释是空的。

6. **Google favicon 回退做成了开关** —— 它会把你的域名告诉 Google。默认开着（抓取成功率明显更高），设置里能关。

7. **删除站点时分两个选项** —— 「删除站点」只从列表移除，「删除并清除存储」连 cookie 一起清。分开是因为误删之后重新加回来还能保住登录状态。留下来的数据之后能在存储管理里当孤儿清掉。

8. **导入冲突给了三个选择** —— 覆盖 / 都留着（新建副本）/ 跳过。建副本时会把 profile 也跟着换成新 id，否则副本和原站会共享存储，属于没人想要的结果。

9. **整个 app 锁深色** —— 首页本来就是深色设计，锁死顺带让 WKWebView 的 `prefers-color-scheme` 跟着走深色。不想要的话删掉 `Info.plist` 里的 `UIUserInterfaceStyle` 和 `HuskApp.swift` 里的 `.preferredColorScheme(.dark)`。

10. **ATS 只放开了 WebView 内的明文 HTTP** —— `NSAllowsArbitraryLoadsInWebContent`。这样 `http://` 的站点能正常打开，而 app 自己发起的请求（图标抓取）仍然强制 HTTPS。

11. **没做拖拽排序** —— LazyVGrid 里的拖拽重排要手写命中测试和插入指示，在这个没有编译器验证的环境里做完全靠脑补，风险和收益不成比例。用长按菜单里的「移到最前」代替了。

### 第二轮：代码评审揪出的三个问题

初版合进去之后又过了一遍代码，这三处是真 bug，都已修掉：

**a. 登录弹窗被自己甩进了 Safari。** `createWebViewWith` 里原本一上来就套用外链策略——
而默认策略是"按域名判断"，登录弹窗十有八九开在 `accounts.google.com` 这类外域上。
结果就是每个弹窗式 OAuth 都被丢进 Safari，`window.opener` 压根不存在了，用户在 Safari 里
授权完，Husk 这边干等。等于把那段精心保住 opener 的代码整个废掉了，相当讽刺。

现在：**弹窗一律留在站内的模态里，不套用外链策略。** 定性上也说得通——外链策略管的是
"从这个站导航走"，而 `window.open` 开出来的是站点自己流程的一部分（授权、支付、打印预览），
它和 opener 是绑定的。

同一个问题的另一半：点"用 Google 登录"如果是普通链接（`.linkActivated`），照样会被甩出去。
所以 `.sameDomain` 现在会识别登录流（专用登录域名、`/oauth` `/authorize` `/login` 之类的路径、
`client_id` + `redirect_uri` 的参数组合）并放行。判断刻意放宽：最多是某个外站的登录页留在了
站内（用户还能从工具箱丢去 Safari），判窄了就是登不上。`.safari` 策略不受影响——用户既然
选了"全都甩出去"，就不替他耍小聪明。

**b. 底边上滑几乎触发不了，而且和回桌面打架。** 起手位置判断用的是
`gestureRecognizer.location(in:)`，但 UIKit 调到 `gestureRecognizerShouldBegin` 时 swipe
**已经判定成立**了——手指早滑出去几十点，必然落在底部判定区之外。这个手势基本是死的。
现在用 `BottomEdgeSwipeGestureRecognizer` 子类在 `touchesBegan` 里记下起手点。

顺带把判定区从"底部 32pt"挪到了"底部安全区上方 48pt"：原来那一条和主屏指示器重叠，
从那儿上滑会被系统当成回桌面。要抢过来得 `preferredScreenEdgesDeferringSystemGestures`，
代价是用户真想回桌面得划两次——不如直接躲开。

**c. `weixin://` 这类跳转点了没反应，以及广告 iframe 能把人弹去 App Store。**
原本用 `canOpenURL` 做前置判断，而 iOS 9 起它对没写进 `LSApplicationQueriesSchemes` 的
scheme 一律返回 false，那张表上限 50 条还得预先知道要查哪些——对一个开放的浏览容器
根本没法穷举。`open` 本身不受这张表限制，现在直接调，打不开就在回调里提示一句。

另外加了 `sourceFrame.isMainFrame` 判断：原来任何一个 iframe 往 `itms-apps://` 一跳就能
把人弹去 App Store，这种劫持在广告里相当常见，现在来自子框架的非 web scheme 一律吞掉。

**d（CI 跑出来的，比上面三条更凶险）**：四个 `WKNavigationDelegate` / `WKUIDelegate`
方法写成了 completion handler 形式，编译只给一句 "nearly matches optional requirement"
警告——但运行时**这些方法根本不会被调用**。也就是说外链拦截、scheme 跳转、JS 对话框
会全部静默失效，而从现象几乎不可能反推到签名不匹配。原因是 iOS 18 起 WebKit 给这些
回调加了 `@MainActor`。现在统一改用 async 变体（`decidePolicyFor` 直接返回
`WKNavigationActionPolicy`，三个对话框内部用 `withCheckedContinuation` 包
`UIAlertController`）——签名里没有闭包，就不存在追 SDK 标注的问题。

这条特别值得记一笔：它是**只有真编译一次才会暴露**的问题，而且症状是"功能静默消失"
而不是崩溃。也正因为这个，CI 这一步不是可有可无的。

**顺带**：`isSameSite` 从纯后缀匹配换成了 eTLD+1 近似。原来站点地址填 `m.youtube.com` 时，
点到 `youtube.com` 会被判成外站——只要站点配的是某个子域，它自己的主域和兄弟子域就全成了外链。

### 关于 UA 预设的版本号

预设串是 **2026-09** 查证的真实值，不是编的。两件事值得知道：

- **iOS 26 起 Safari 把系统版本号冻结在 `18_7`**（隐私措施），真实版本只体现在 `Version/26.5` 这个 token 上。所以 iPhone / iPad 的串里出现 `CPU iPhone OS 18_7` 是**对的**，别"修正"成 `26_x`。
- **Chrome 从 153 开始改成两周一个大版本**，跑得很快，预设里的 `152.0.0.0` 早晚过时。过时了在站点设置里手填一个就行——UA 预设本来就只是省打字。

---

### 第三轮：iOS 26 改版里我自己拿的主意

需求给的是方向，这些是落地时的判断，挑不显而易见的记一下。

**a. 自绘按钮只剩一处。** 「凡是自己画的面板、按钮、卡片，能用系统组件就换系统组件」
这条执行下来，`Color.white.opacity(0.08)` 那套毛玻璃全没了：
面板换成 `Form`/`Section`，按钮换成 `.buttonStyle(.glass)` / `.glassProminent`，
提示条换成 `glassEffect(.regular, in: .capsule)`，空状态换成 `ContentUnavailableView`，
工具箱那排圆形按钮装进 `GlassEffectContainer`（玻璃不该去采样玻璃）。
`Theme` 从一整套颜色缩到三个。

唯一留下来的是**站点图标的按压回弹**（`Home/SiteTile.swift`）：
图标是一张铺满的图片，系统按钮样式都会在它周围画自己的背景，
看着就不是"主屏图标"了。这一处保留，代码里也写了原因。

**b. 工具箱 sheet 里没有 `NavigationStack`。** 半屏档要的是 iOS 26 那张悬浮玻璃卡片，
套一层导航栈会多出自己的背景和标题栏，把卡片的观感冲掉。
站点名和域名直接做成第一个 section 的内容。

**c. 「本站设置」抽成了共用分区**（`SettingsUI/SiteSettingsSections.swift`）。
工具箱大档位和站点编辑页要显示同一批设置，各写一份的话加个字段就得改两处。
两边的写盘时机不同，所以约定成：改 `site` 是即时的（当前页面立刻跟着变），
写盘统一走 `commit` 回调——编辑页传空操作（保存时才落盘），工具箱传 `store.update`。
缩放滑块拖动时只写 `site`，松手才 `commit`。

顺带一个 SwiftUI 的坑：`.onChange` 挂在 `Group` 上会分发给**每个**子视图，
一次改动会 commit 五遍。所以它只挂在其中一个 section 上。

**d. `+` 从网格里挪走了，`AddSiteTile` 删掉。** 需求说 `+` 放右上角导航栏，
那网格末尾那块虚线框就重复了。空状态里还留了一个「添加第一个站点」。

**e. 手动例外的通配语义是我定的。** `example.com` 只匹配这一个主机，
`*.example.com` 才连子域一起——如果裸域名也默认带子域，那通配符这个写法就没意义了。
用户手误写成 `.example.com` 的按通配处理。

**f. 缩放没用对数滑块，用了档位表。** 对数映射确实能解决低段过密，
但滑块会停在 37%、113% 这种数上，反而更难用。档位表每格都是个能说出口的数，
而且一定停得到 100%。

**g. 存相册的图标在源图小于 128px 时重画，而且顺手修了图标缓存的两个坑。**
写完导出那段才发现缓存一直是**固定** 180×180——32 像素的 favicon 也会被放大成 180，
于是"源图有多清楚"这个信息在缓存里根本不存在，门槛判了也是白判，
结果会是**每一个站点都导出成字母块**。所以 `IconFetcher.targetSize`
从"固定 180"改成"上限 512、只缩不放"。门槛按最终显示尺寸（约 540 像素）算，定在 128。

同一处的第二个坑：导出**不能**走 `IconStore.image(for:)`。那个方法抓不到图标时会
返回一张 180 像素的占位图，而占位图和真图标在返回值上分不出来——导出那边会把它
当成"一张 180 的源图"放大到 1024，结果是个糊掉的字母。改成只认磁盘上真存在的
抓取缓存 / 自选图片，没有就传 nil，让导出那边按占位图风格**重画**一张干净的。

**h. 域名例外的输入框逐字写盘。** 库文件只有几 KB、原子写，
和原来那个全局默认缩放滑块（每一步都落盘）是一个量级，没为它单独做防抖。

**i. 临时站点的比对粒度选了"去掉 fragment 的完整 URL"**，理由写在上面
「打开的就是当前站点时」那一节。

**j. `UIApplicationSupportsMultipleScenes` 是被迫开的**，副作用是 iPad 上能多开窗口。
所有窗口共用同一个 `Router`，内容是一样的。不想要这个副作用的话，
去掉 Info.plist 里的 `UIApplicationSceneManifest` 和 `OpenSiteIntent` 的
`TargetContentProvidingIntent` 即可——代价是快捷指令冷启动会闪一下首页，
`perform()` 那条兜底路径照样能把站点打开。

---

## 已知限制

- **PSL 是打包的快照，不会自己更新。** 新注册的公共后缀要等下一次更新数据文件。判错的那个域名，用站点设置里的手动例外名单直接压过去就行。
- **PSL 里的国际化域名是 Unicode 形式，而 `URL.host()` 给的是 Punycode**，两边对不上时那个 IDN 站点会退回"最后一段是公共后缀"。中文域名之类的站点如果判得不对，同样用手动例外压。
- **`.ico` 里只装老式 BMP 子图的站点抓不到图标**，会往下退到 Google 服务或首字母图。写个 BMP 解码器不值当。
- **`http://` 站点的图标抓不到** —— ATS 只对 WebView 内容放开了明文，app 侧的 URLSession 还是强制 HTTPS。这是有意的取舍。
- **`pageZoom` 是整页缩放**，等价于 CSS `zoom`。用固定像素布局的站点放大后可能出横向滚动条，这是这个 API 的性质，不是 bug。
- **存储占用只报"有几个域名留了数据"，不报字节数** —— `WKWebsiteDataRecord` 根本不提供大小。
- **临时站点（`husk://open?url=`）共用一个 profile**，彼此之间不隔离。
- **iPad 上现在能开多个窗口了**，但那不是设计意图：`UIApplicationSupportsMultipleScenes` 是 App Intents 的 scene 派发要求的（见上文）。所有窗口共用同一个 `Router`，所以多开出来的窗口内容是一样的。
- **`ScrollView` 里的空状态不是垂直居中的**，`ContentUnavailableView` 顶着上边留了一段内边距。
- **外链判断不是安全边界**，只决定"这个链接在哪儿打开"。
- **灵动岛进度环不跟着实时活动变形。** 别的 app 的实时活动把岛撑宽时，环还绕着原来那颗胶囊，会被盖住一部分。app 拿不到岛的当前形态，见[进度环](#进度环环绕灵动岛)。
- **开了代理的 profile：app 在后台时本地中继不工作、WebRTC 和通行密钥不可用、改代理配置会重建已打开的页面。** 详见[按 profile 配 HTTPS 代理](#按-profile-配-https-代理)的「已知限制」和「需要真机验证的」。
- **灵动岛进度环横屏下退回细条**，横屏的坐标系还没在真机上验证。几何公式（外扩 1pt、重新居中）也只在 iPhone 16 Pro / iOS 26.6.2 上实测过。

## 明确不做

多标签、书签、历史记录、广告拦截、下载管理、阅读模式。

想要这些的话，Safari 就在旁边。

---

## License

MIT，见 [LICENSE](LICENSE)。
