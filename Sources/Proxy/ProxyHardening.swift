import Foundation
import WebKit

/// 开了代理的 profile 要额外关掉的东西：这几条路**不走** `proxyConfigurations`，会把真实 IP 带出去。
///
/// | 泄露 | 为什么绕开代理 | 这里怎么堵 |
/// |---|---|---|
/// | WebRTC | ICE 用 UDP 问 STUN，HTTP CONNECT 代理只转 TCP（Apple 文档原话） | 私有偏好 `_peerConnectionEnabled` = NO，外加脚本删构造器 |
/// | WebTransport（iOS 26.4 起） | WebKit 自己拼 QUIC 连接，不带会话的代理设置（Mysk 2026-08 报告） | `_WKFeature` 里的 `WebTransportEnabled` 关掉，外加脚本删构造器 |
/// | `<link rel=dns-prefetch>`（iOS 26.0 起） | 网络进程直接调系统解析，不经代理 | 内容规则拦 `ping` 类型：WebKit 在 `prefetchDNSIfNeeded` 里按 ping 过内容规则 |
/// | 通行密钥的 Related Origin 校验 | 系统凭据服务自己去取 `/.well-known/webauthn`，不在 WebKit 的会话里 | 只能脚本层面把 `navigator.credentials.get/create` 拒掉（尽力而为） |
///
/// 私有 API 的用法和实验室里读灵动岛那套一样：每一步先 `responds(to:)`，不在就原地放弃，
/// 结果写进 `Report`，实验室页能看到到底关没关上。
@MainActor
enum ProxyHardening {
    struct Report: Sendable, Equatable {
        /// nil = 这个系统上没有那个私有开关
        var peerConnectionDisabled: Bool?
        var webTransportDisabled: Bool?
        var dnsPrefetchRuleInstalled: Bool
    }

    static let ruleListIdentifier = "husk.proxy.block-dns-prefetch.v1"

    /// `resource-type: ping` 同时会拦掉 `navigator.sendBeacon` 和 `<a ping>`——
    /// 这两个本来就会走代理，拦掉只是顺带的副作用（统计打点发不出去），不影响页面功能。
    static let ruleListSource = #"[{"trigger":{"url-filter":".*","resource-type":["ping"]},"action":{"type":"block"}}]"#

    /// 给开了代理的 profile 的 configuration 加固：私有偏好 + 内容规则。没开代理的 profile **一样都不碰**。
    ///
    /// 脚本不在这里挂，由 `WebViewFactory.applyConfigurationExtras` 统一挂——
    /// 那边会先 `removeAllUserScripts()`，在这里挂了也会被它清掉。
    @discardableResult
    static func apply(to configuration: WKWebViewConfiguration, ruleList: WKContentRuleList?) -> Report {
        let preferences = configuration.preferences
        let report = Report(
            peerConnectionDisabled: disablePeerConnection(preferences),
            webTransportDisabled: disableFeature("WebTransportEnabled", in: preferences),
            dnsPrefetchRuleInstalled: ruleList != nil
        )
        if let ruleList {
            configuration.userContentController.add(ruleList)
        }
        return report
    }

    /// 兜底脚本
    static func addScript(to controller: WKUserContentController) {
        controller.addUserScript(guardScript)
    }

    // MARK: - 私有偏好

    /// `-[WKPreferences _setPeerConnectionEnabled:]`（WKPreferencesPrivate.h，iOS 11.3 起）。
    /// KVC 按 `set<Key>:` → `_set<Key>:` 的顺序找 setter，所以 key 写不带下划线的 `peerConnectionEnabled`。
    private static func disablePeerConnection(_ preferences: WKPreferences) -> Bool? {
        guard preferences.responds(to: NSSelectorFromString("_setPeerConnectionEnabled:")),
              preferences.responds(to: NSSelectorFromString("_peerConnectionEnabled"))
        else { return nil }
        preferences.setValue(false, forKey: "peerConnectionEnabled")
        return (preferences.value(forKey: "peerConnectionEnabled") as? Bool) == false
    }

    /// `+[WKPreferences _features]` 里按 key 找到那一项，`-_setEnabled:forFeature:` 关掉。
    /// 带 BOOL 参数的方法没法用 `perform`，只能取 IMP 按 C 函数调。
    private static func disableFeature(_ key: String, in preferences: WKPreferences) -> Bool? {
        let featuresSelector = NSSelectorFromString("_features")
        let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        let getSelector = NSSelectorFromString("_isEnabledForFeature:")
        guard let featuresMethod = class_getClassMethod(WKPreferences.self, featuresSelector),
              preferences.responds(to: setSelector),
              preferences.responds(to: getSelector)
        else { return nil }

        // 类方法同样按 C 函数调，不走 AnyObject 的动态查找（那条路的返回类型每个 SDK 推断得不一样）
        typealias GetFeatures = @convention(c) (AnyClass, Selector) -> NSArray?
        let getFeatures = unsafeBitCast(method_getImplementation(featuresMethod), to: GetFeatures.self)
        guard let features = getFeatures(WKPreferences.self, featuresSelector) as? [NSObject],
              let feature = features.first(where: { candidate in
                  candidate.responds(to: NSSelectorFromString("key"))
                      && (candidate.value(forKey: "key") as? String) == key
              })
        else { return nil }

        typealias SetFeature = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        typealias GetFeature = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let set = unsafeBitCast(preferences.method(for: setSelector), to: SetFeature.self)
        let get = unsafeBitCast(preferences.method(for: getSelector), to: GetFeature.self)
        set(preferences, setSelector, false, feature)
        return !get(preferences, getSelector, feature)
    }

    // MARK: - 脚本

    /// 第二道：私有开关哪天没了，页面里至少拿不到构造器。
    ///
    /// **这一层挡不住刻意绕的页面**（比如新开一个 about:blank iframe 去拿干净的原型），
    /// 所以它只是兜底，主力是上面的私有开关。通行密钥那条没有私有开关可用，只有这一层，
    /// README 里写成"尽力而为"。
    private static let guardScript = WKUserScript(
        source: """
        (function () {
          var w = window;
          ['RTCPeerConnection', 'webkitRTCPeerConnection', 'WebTransport'].forEach(function (name) {
            try { delete w[name]; } catch (e) {}
            try { Object.defineProperty(w, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
          });
          try {
            if (w.CredentialsContainer) {
              var deny = function () {
                return Promise.reject(new DOMException('这个 profile 开了代理，Husk 停用了通行密钥（会绕过代理）', 'NotAllowedError'));
              };
              w.CredentialsContainer.prototype.get = deny;
              w.CredentialsContainer.prototype.create = deny;
            }
            delete w.PublicKeyCredential;
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    // MARK: - 内容规则

    /// 编译 DNS 预取拦截规则。回调直接写进 `ProxyManager`，不让 `WKContentRuleList`
    /// 跨 continuation 走（它不是 Sendable）。
    static func compileRuleList(_ done: @escaping @MainActor @Sendable (WKContentRuleList?, String?) -> Void) {
        // 显式标成可选：头文件里这个方法的可空性标注在不同 SDK 上不一样
        let store: WKContentRuleListStore? = WKContentRuleListStore.default()
        guard let store else {
            done(nil, "拿不到 WKContentRuleListStore")
            return
        }
        store.compileContentRuleList(forIdentifier: ruleListIdentifier, encodedContentRuleList: ruleListSource) { list, error in
            let message = error?.localizedDescription
            MainActor.assumeIsolated { done(list, message) }
        }
    }
}
