import WebKit

/// 缩放的真正实现：改 viewport，而不是 `WKWebView.pageZoom`。
///
/// **为什么不用 pageZoom 了**：iOS 上的 pageZoom 只是把排好的版面按比例画小 / 画大，
/// 布局宽度仍然是原来那 390 个 CSS 像素。于是
/// - 缩小时整页挤在屏幕左边一小块，右边一大片空着（GitHub 50% 时只占左半屏）；
/// - 放大时版面比屏幕宽，横向滚动条就出来了；
/// - 缩小后 iOS 的文字自动放大（text autosizing）会把字号往上提，但站点写死的行高不跟着变，
///   上下两行字就叠在一起。
///
/// 现在的做法和 iOS 渲染"桌面版网页"是同一条路：把布局宽度设成 `屏宽 ÷ 缩放`，
/// 再用 `initial-scale = 屏宽 ÷ 布局宽度` 塞回一屏宽。版面会按新宽度重排，所以永远铺满屏幕。
/// 缩小时再用 `-webkit-text-size-adjust: 100%` 关掉文字自动放大。
///
/// 细节：
/// - 页面自己的 viewport 被**原地改写**（MutationObserver 盯着），页面之后再改它，
///   以页面的新值为准重新换算。缩放回到 100% 时原样还原，不留痕迹。
/// - 页面写了固定宽度（`width=1024`）就按那个宽度换算；没写 viewport 按 iOS 默认的 980。
/// - 保留页面的 `user-scalable=no` 和 `viewport-fit`。
/// - 脚本在 documentStart 注入，每次导航都带着当时的缩放值；拖滑块时由 Swift 调
///   `__huskSetZoom` 实时改，同时重装脚本让之后的导航用上新值。
@MainActor
enum ZoomScript {
    static func userScript(zoom: Double) -> WKUserScript {
        WKUserScript(source: source(zoom: zoom), injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static func liveUpdate(zoom: Double) -> String {
        "window.__huskSetZoom && window.__huskSetZoom(\(literal(zoom)));"
    }

    private static func literal(_ zoom: Double) -> String {
        String(format: "%.4f", zoom.clamped(to: Site.zoomRange))
    }

    private static func source(zoom: Double) -> String {
        "(" + body + ")(\(literal(zoom)));"
    }

    private static let body = """
    function (initial) {
      if (window.__huskSetZoom) { window.__huskSetZoom(initial); return; }
      var zoom = initial;
      var original = null;   // 页面自己写的 viewport content；null = 页面没写
      var written = null;    // 我们最后一次写进去的 content，用来区分"是不是页面自己改的"
      var ours = null;       // 页面没有 viewport 时我们自己插的那个 meta

      function deviceWidth() {
        var narrow = Math.min(screen.width, screen.height);
        var wide = Math.max(screen.width, screen.height);
        var landscape = (screen.orientation && screen.orientation.type)
          ? screen.orientation.type.indexOf('landscape') === 0
          : Math.abs(window.orientation || 0) === 90;
        return landscape ? wide : narrow;
      }

      function parse(content) {
        var args = {};
        (content || '').split(/[,;]/).forEach(function (part) {
          var kv = part.split('=');
          if (kv.length === 2) args[kv[0].trim().toLowerCase()] = kv[1].trim().toLowerCase();
        });
        return args;
      }

      function pageMeta() {
        var list = document.querySelectorAll('meta[name="viewport" i]');
        for (var i = list.length - 1; i >= 0; i--) {
          if (list[i] !== ours) return list[i];
        }
        return null;
      }

      function compute(content) {
        var args = parse(content);
        var dw = deviceWidth();
        var base = 980;
        if (args.width === 'device-width') base = dw;
        else if (parseFloat(args.width) > 0) base = parseFloat(args.width);
        else if (parseFloat(args['initial-scale']) > 0) base = dw / parseFloat(args['initial-scale']);
        // WebKit 的 viewport 缩放下限是 0.1，布局宽度再宽就塞不回一屏了
        var width = Math.max(1, Math.round(Math.min(base / zoom, dw * 10)));
        var scale = Math.round(dw / width * 10000) / 10000;
        var out = ['width=' + width, 'initial-scale=' + scale, 'minimum-scale=' + scale];
        if (args['user-scalable'] === 'no' || args['user-scalable'] === '0') {
          out.push('maximum-scale=' + scale, 'user-scalable=no');
        }
        if (args['viewport-fit']) out.push('viewport-fit=' + args['viewport-fit']);
        return out.join(', ');
      }

      function textAdjust() {
        var el = document.getElementById('husk-zoom-style');
        if (zoom < 0.999) {
          if (el || !document.head) return;
          el = document.createElement('style');
          el.id = 'husk-zoom-style';
          el.textContent = 'html{-webkit-text-size-adjust:100%!important;text-size-adjust:100%!important}';
          document.head.appendChild(el);
        } else if (el) {
          el.remove();
        }
      }

      function apply() {
        var identity = Math.abs(zoom - 1) < 0.001;
        var meta = pageMeta();
        if (meta) {
          if (ours) { ours.remove(); ours = null; }
          var current = meta.getAttribute('content');
          if (current !== written) original = current;
          var next = identity ? original : compute(original);
          written = next;
          if (current !== next) {
            if (next === null) meta.removeAttribute('content');
            else meta.setAttribute('content', next);
          }
        } else {
          original = null;
          if (identity) {
            if (ours) { ours.remove(); ours = null; }
          } else if (document.readyState !== 'loading' && document.head) {
            // 页面真没写 viewport（等解析完再下结论，不然会抢在页面自己的 meta 前面）
            if (!ours) {
              ours = document.createElement('meta');
              ours.name = 'viewport';
              document.head.appendChild(ours);
            }
            written = compute(null);
            if (ours.getAttribute('content') !== written) ours.setAttribute('content', written);
          }
        }
        textAdjust();
      }

      function touchesViewport(records) {
        for (var i = 0; i < records.length; i++) {
          var r = records[i];
          if (r.type === 'attributes') {
            if (r.target.nodeName === 'META') return true;
            continue;
          }
          var lists = [r.addedNodes, r.removedNodes];
          for (var j = 0; j < 2; j++) {
            for (var k = 0; k < lists[j].length; k++) {
              var name = lists[j][k].nodeName;
              if (name === 'META' || name === 'HEAD') return true;
            }
          }
        }
        return false;
      }

      new MutationObserver(function (records) {
        if (touchesViewport(records)) apply();
      }).observe(document.documentElement || document, {
        childList: true, subtree: true, attributes: true, attributeFilter: ['content', 'name']
      });

      document.addEventListener('DOMContentLoaded', apply);
      window.addEventListener('orientationchange', apply);
      if (screen.orientation && screen.orientation.addEventListener) {
        screen.orientation.addEventListener('change', apply);
      }

      window.__huskSetZoom = function (z) {
        if (typeof z !== 'number' || !(z > 0)) return;
        zoom = z;
        apply();
      };
      apply();
    }
    """
}
