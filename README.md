# Husk

把网站当成独立 app 用的 iOS 容器。每个站点有自己的图标、缩放、User-Agent、外链规则和**独立存储**，互相看不见对方的登录状态。

解决的是 Safari「添加到主屏幕」那套 PWA 的老问题：缩放改不了、UA 锁死、点个外链就被甩出 app、图标丑、所有站共用一份 cookie。

- SwiftUI + `WKWebView`，最低 **iOS 18.0**
- 无第三方依赖，Swift 6 语言模式
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
3. Bundle ID 换了之后，顺手把 `Sources/WebClip/WebClipBuilder.swift` 里 payload 标识的 `org.example.husk.*` 前缀也换掉——这些字符串决定描述文件在系统里的身份，和 app 对上更干净。
4. URL scheme `husk` 写在 `Support/Info.plist` 的 `CFBundleURLTypes` 里。想换名字的话，`Sources/App/DeepLink.swift` 里的 `DeepLink.scheme` 要同步改。

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

冷启动不会先闪一下首页：`Sources/App/Router.swift` 里留了一小段挡板期，先铺一张和启动屏同色的底，等 deep link 落定（或者 140ms 内没有）再放首页出来。

---

## Web Clip（主屏图标）

站点设置 → 「导出 Web Clip」，或者全局设置 → 「导出全部站点的 Web Clip」，拿到 `.mobileconfig`。

**安装步骤：**

1. 通过分享面板把文件存到「文件」，或者 AirDrop 到自己设备
2. **用 Safari 打开这个文件**（这条最关键，从别的 app 打开经常没反应）
3. 提示「此网站正尝试下载配置描述文件」→ 允许
4. 设置 → 通用 → **VPN 与设备管理** → 已下载的描述文件 → 安装
5. 会有一屏红字写着「未签名」「描述文件未签名」——**这是正常的**，我们没有 Apple 的企业签名证书，自己生成的描述文件都长这样
6. 装完主屏上出现图标，点开直接进 Husk 的对应站点

删除：设置 → 通用 → VPN 与设备管理 → 选中 → 移除描述文件。

> ⚠️ **一个必须知道的限制**：Apple 的官方文档明确写着 Web Clip 的 `URL` 字段**必须以 `http` 或 `https` 开头**。我们填的是 `husk://open?id=…`，属于文档不支持的用法。实测在不少 iOS 版本上能装能跳，但这是没有保证的行为。
>
> 万一你的系统版本拒绝安装，`Sources/WebClip/WebClipBuilder.swift` 里的 `LinkTarget` 留了第二个选项 `.siteURL`，改成它就是规范内的写法——代价是点图标会进 Safari 而不是 Husk，等于退回 PWA。

---

## 功能一览

**首页** — 深色底、大圆角图标网格、按压回弹、滚动时大标题收成窄栏、下拉唤出搜索（不常驻）。长按出菜单：编辑 / 移到最前 / 删除 / 复制 `husk://` 链接 / 导出 Web Clip。

**浏览界面** — 全屏 WebView，除页面外没有任何常驻 UI。顶部一条 2pt 进度条，加载完淡出。支持边缘滑动前进后退。

**手势工具箱** — 四种唤出手势可逐个开关（默认开前两个）：

| 手势 | 默认 |
|---|---|
| 双指下滑 | 开 |
| 底边上滑 | 开 |
| 三指点按 | 关 |
| 双指长按 | 关 |

刻意避开单指边缘滑（撞前进后退）和单指长按（撞选中文字、链接预览）。工具箱内容：缩放滑块（50%–200%，拖动实时生效、松手写回配置）、刷新 / 站点首页 / 分享 / 在 Safari 打开、当前 URL（点一下复制）、本站设置、返回列表。

**站点配置** — 图标（自动抓取 / 相册选图 / 首字母渐变）、缩放、UA（6 个预设 + 自填）、外链行为（站内 / Safari / 按域名，默认第三种）、存储 profile。

**全局设置** — 手势开关、新建站点默认值、配置导入导出（JSON）、存储管理（按站点清 / 全部清 / 孤儿清理）。

---

## 代码结构

```
Sources/
  App/          入口、路由、husk:// 解析
  Models/       Site / AppSettings / UA 预设（纯值类型，Sendable）
  Storage/      JSON 持久化、WKWebsiteDataStore 多 profile 管理
  Icons/        图标抓取、ICO 拆包、首字母占位图
  WebKitLayer/  WKWebView 装配、导航策略、弹窗、手势
  Browser/      浏览界面、进度条、工具箱
  Home/         首页网格
  SettingsUI/   站点设置、全局设置、存储管理
  WebClip/      .mobileconfig 生成
  Util/         主题、分享面板
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
| `customUserAgent` 改完要 `reload()` 才对当前页生效 | `WebKitLayer/WebSession.swift` |
| 深色白闪：`isOpaque = false` + 深色 `backgroundColor` | 同上 |
| **delegate 要用 async 变体**：iOS 18 起 WebKit 给 completion handler 加了 `@MainActor`，旧签名只"近似匹配"，编译器仅给 warning 而运行时**根本不调用** | `WebKitLayer/WebCoordinator.swift` |

另外补了两个文档里不显眼的：

- **`UIImage` 在 iOS 上不解码 `.ico`**，直接给 nil。`Icons/ICOUnpacker.swift` 从 `favicon.ico` 里把内嵌的 PNG 子图拆出来（现代站点基本都是 PNG-in-ICO）。
- **首字母占位图的颜色不能用 `hashValue` 派生**，Swift 的字符串哈希每次启动换 seed，同一个站点每次启动都会换颜色。改用自己写的稳定累加。

---

## 相对于需求描述，我改了/补了这些

1. **Web Clip 的 `husk://` 是文档外用法** —— 见上面那段警告，留了 `.siteURL` 兜底选项。这是整个项目里唯一一处"照做但不保证"的地方，所以单独拎出来说。

2. **「回首页」拆成两个按钮** —— 原描述里这个词有歧义：是回站点的首页，还是回 Husk 的站点列表？工具箱里两个都给了，叫「站点首页」和「返回列表」。

3. **底边上滑没用 `UIScreenEdgePanGestureRecognizer(.bottom)`** —— 屏幕底边被系统的主屏指示器占着，边缘 pan 要靠 `preferredScreenEdgesDeferringSystemGestures` 去抢，体验是"得划两次"。改成 `UISwipeGestureRecognizer(.up)` + 起手位置限定在底部 32pt，判定快、失败也快，不会把页面滚动卡住。

4. **加了个逃生按钮** —— 四个手势全关掉的话就没法唤出工具箱，等于被困在站点里出不去了。这种情况下浏览页右下角会出现一个不起眼的小圆点。

5. **实现了 JS 的 `alert` / `confirm` / `prompt`** —— 不实现这三个 `WKUIDelegate` 方法的话，这些调用在 WKWebView 里是"什么都不发生"，而且 `confirm` 永远返回 false。对一个当 app 用的容器来说这是明显的功能缺失。

6. **注入了一个极小的 user script** —— 把页面根元素的背景色报回来，用它刷 WebView 的 `backgroundColor`，这样过度滚动露出来的那条边和页面同色。顺带它也是"弹窗要重挂 configuration 层面的东西"这件事的具体例子，不然那段注释是空的。

7. **Google favicon 回退做成了开关** —— 它会把你的域名告诉 Google。默认开着（抓取成功率明显更高），设置里能关。

8. **删除站点时分两个选项** —— 「删除站点」只从列表移除，「删除并清除存储」连 cookie 一起清。分开是因为误删之后重新加回来还能保住登录状态。留下来的数据之后能在存储管理里当孤儿清掉。

9. **导入冲突给了三个选择** —— 覆盖 / 都留着（新建副本）/ 跳过。建副本时会把 profile 也跟着换成新 id，否则副本和原站会共享存储，属于没人想要的结果。

10. **整个 app 锁深色** —— 首页本来就是深色设计，锁死顺带让 WKWebView 的 `prefers-color-scheme` 跟着走深色。不想要的话删掉 `Info.plist` 里的 `UIUserInterfaceStyle` 和 `HuskApp.swift` 里的 `.preferredColorScheme(.dark)`。

11. **ATS 只放开了 WebView 内的明文 HTTP** —— `NSAllowsArbitraryLoadsInWebContent`。这样 `http://` 的站点能正常打开，而 app 自己发起的请求（图标抓取）仍然强制 HTTPS。

12. **没做拖拽排序** —— LazyVGrid 里的拖拽重排要手写命中测试和插入指示，在这个没有编译器验证的环境里做完全靠脑补，风险和收益不成比例。用长按菜单里的「移到最前」代替了。

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

## 已知限制

- **`.sameDomain` 的域名判断是 eTLD+1 近似，没接 Public Suffix List。** 内置了一张常见多段后缀表（`co.uk`、`com.cn` 之类），但像 `github.io` 这种"托管型"公共后缀没覆盖，`a.github.io` 和 `b.github.io` 会被算成同一站。对"链接在哪儿打开"这件事无所谓，别当安全边界用。
- **`.ico` 里只装老式 BMP 子图的站点抓不到图标**，会往下退到 Google 服务或首字母图。写个 BMP 解码器不值当。
- **`http://` 站点的图标抓不到** —— ATS 只对 WebView 内容放开了明文，app 侧的 URLSession 还是强制 HTTPS。这是有意的取舍。
- **`pageZoom` 是整页缩放**，等价于 CSS `zoom`。用固定像素布局的站点放大后可能出横向滚动条，这是这个 API 的性质，不是 bug。
- **存储占用只报"有几个域名留了数据"，不报字节数** —— `WKWebsiteDataRecord` 根本不提供大小。
- **临时站点（`husk://open?url=`）共用一个 profile**，彼此之间不隔离。
- **描述文件未签名**，安装时必然有红字警告。
- **没做 iPad 多窗口**（Scene 多实例）。

## 明确不做

多标签、书签、历史记录、广告拦截、下载管理、阅读模式。

想要这些的话，Safari 就在旁边。

---

## License

MIT，见 [LICENSE](LICENSE)。
