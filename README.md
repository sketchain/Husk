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

### CI（GitHub Actions）

`.github/workflows/build.yml`：push 到 `main` 或 `claude/**` 分支、以及手动触发时跑。

- runner `macos-26`（Apple Silicon，2026-02 起 GA），默认 Xcode 26.6，自带 iOS 26.x SDK
- `brew install xcodegen` → `xcodegen generate` → `xcodebuild build`
- **只编译不签名**（`CODE_SIGNING_ALLOWED=NO`），CI 上没有证书
- 产物是未签名的 `Husk-unsigned.ipa`（就是个 zip，里面 `Payload/Husk.app`），留存 30 天

下载下来之后用你自己的证书签：

```bash
unzip -q Husk-unsigned.ipa
codesign -f -s "Apple Development: 你的名字 (XXXXXXXXXX)" \
  --entitlements your.entitlements Payload/Husk.app
zip -qry Husk-signed.ipa Payload
```

或者直接把 `Payload/Husk.app` 丢给 Xcode / 你惯用的侧载工具。

### 发版

打个 `v` 开头的 tag 推上去就行，剩下的 `.github/workflows/release.yml` 全包了：

```bash
git tag v1.2.0
git push origin v1.2.0
```

没有本地仓库、或者推 tag 的权限受限时，也可以在 Actions 页面手动跑
**Release** 这个 workflow，填上版本号（`v1.2.0`）——tag 不存在的话由 CI
建在触发时所在的提交上，结果和上面完全一样。

它会：

1. 复用 `build.yml` 的编译步骤（`workflow_call`，不是复制一份）
2. 把版本号从 tag 推出来注入编译：`v1.2.0` → `MARKETING_VERSION=1.2.0`，
   `CURRENT_PROJECT_VERSION` 用 workflow 的运行序号；打包前会 `PlistBuddy` 读一遍确认写进去了
3. 建一个 GitHub Release，标题 `Husk v1.2.0`，更新说明由 GitHub 按提交自动生成
4. 把 `Husk-1.2.0-unsigned.ipa` 作为 **Release 附件**上传（不是 artifact，不会过期）

tag 里带连字符的（`v1.2.0-beta1`）按 semver 惯例自动标成预发布。

版本号只在发版时由 tag 决定，日常 push 到 `main` 走的还是 `project.yml` 里写死的值。

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

**浏览界面** — 全屏 WebView，除页面外没有任何常驻 UI。顶部一条 2pt 进度条，加载完淡出。支持边缘滑动前进后退。设置里可以开「浏览时隐藏状态栏」，把时间电池那条一起藏掉。

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

**站点配置** — 图标（自动抓取 / 相册选图 / 首字母渐变）、缩放 10%–200%、UA（6 个预设 + 自填）、外链行为与档位、手动例外名单、存储 profile。

**全局设置** — 浏览时隐藏状态栏、手势开关、新建站点默认值、图标（Google 回退开关 / 批量存图标）、配置导入导出（JSON）、存储管理（按站点清 / 全部清 / 孤儿清理）。

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
  Storage/      JSON 持久化、WKWebsiteDataStore 多 profile 管理
  Icons/        图标抓取、ICO 拆包、首字母占位图、主屏图标导出、存相册
  Intents/      AppEntity、「打开站点」intent、AppShortcutsProvider
  WebKitLayer/  WKWebView 装配、导航策略、弹窗、手势
  Browser/      浏览界面、进度条、工具箱 sheet
  Home/         TabView、站点网格、"继续上次"
  SettingsUI/   站点设置、共用的本站设置分区、全局设置、存储管理
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

**g. 存相册的图标在源图小于 128px 时重画，而且顺手把图标缓存改成了"只缩不放"。**
写完导出那段才发现缓存一直是**固定** 180×180——32 像素的 favicon 也会被放大成 180，
于是"源图有多清楚"这个信息在缓存里根本不存在，门槛判了也是白判，
结果会是**每一个站点都导出成字母块**。所以 `IconFetcher.targetSize`
从"固定 180"改成"上限 512、只缩不放"。门槛按最终显示尺寸（约 540 像素）算，定在 128。

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

## 明确不做

多标签、书签、历史记录、广告拦截、下载管理、阅读模式。

想要这些的话，Safari 就在旁边。

---

## License

MIT，见 [LICENSE](LICENSE)。
