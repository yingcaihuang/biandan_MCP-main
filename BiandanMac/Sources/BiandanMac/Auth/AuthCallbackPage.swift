import Foundation

/// 本机授权回调（127.0.0.1:42681）返回给浏览器的页面。
/// 视觉沿用 docs/macos/ui-prototype.html 与 DESIGN.md：米色背景、白卡片、黄色强调、四象限色带。
/// 静态页不含脚本；登录进度页只带一段 nonce 内联脚本，轮询本机 /biandan/status 并用 textContent 更新。
enum AuthCallbackPage {
    enum Kind: CaseIterable {
        case success, denied, rejected, notFound
    }

    private struct Header {
        let tag: String
        let color: String
        let title: String
        let message: String
        let footer: String
    }

    private enum StepState: String {
        case done, now, todo = "", fail
    }

    // MARK: - 静态页

    static func html(_ kind: Kind) -> String {
        switch kind {
        case .success:
            return progressHTML(.initial, session: nil, nonce: nil)
        case .denied:
            return document(title: "华为没有授予授权", tag: "未授权", color: "var(--red)",
                            message: "你取消了授权，或者华为账号拒绝了这次请求。回到便单 App 重新点击「使用华为账号登录」即可再试一次。",
                            steps: "", footer: "可以关闭本页，回到便单 App", script: "")
        case .rejected:
            return document(title: "这个授权链接已失效", tag: "链接无效", color: "var(--q2)",
                            message: "它不属于当前这次登录，或者已经用过了。请回到便单 App 重新登录。",
                            steps: "", footer: "可以关闭本页，回到便单 App", script: "")
        case .notFound:
            return document(title: "页面不存在", tag: "404", color: "var(--sub)",
                            message: "这里是便单在本机接收华为授权的地址，只在登录时使用。",
                            steps: "", footer: "便单 for macOS", script: "")
        }
    }

    // MARK: - 登录进度页

    /// session、nonce 都给出时带轮询脚本；否则是不会自动更新的静态快照。
    static func progressHTML(_ s: LoginProgress.Snapshot, session: String?, nonce: String?) -> String {
        let head = header(s.phase)
        let (state3, state4, detail3, detail4) = stepInfo(s)
        let steps = "<ol class=\"steps\">"
            + step("s1", 1, "打开华为授权页", .done, "")
            + step("s2", 2, "收到授权回调", .done, "")
            + step("s3", 3, "换取令牌，保存到钥匙串", state3, detail3)
            + step("s4", 4, "首次同步分类、任务和专注记录", state4, detail4)
            + "</ol>"
        var script = ""
        if let session, let nonce {
            script = pollingScript(session: session, nonce: nonce, phase: s.phase)
        }
        let message = head.message.replacingOccurrences(of: "{summary}", with: summary(s.counts))
        return document(title: head.title, tag: head.tag, color: head.color, message: escape(message),
                        steps: steps, footer: head.footer, script: script)
    }

    static func summary(_ counts: LoginProgress.Counts?) -> String {
        guard let c = counts else { return "同步完成" }
        return "共 \(c.lists) 个分类、\(c.tasks) 个任务、\(c.occurrences) 个执行实例、\(c.focus) 条专注记录"
    }

    private static func header(_ phase: LoginProgress.Phase) -> Header {
        switch phase {
        case .exchanging, .syncing:
            return Header(tag: "授权成功", color: "var(--q4)", title: "已收到华为授权",
                          message: "便单 App 正在完成登录，本页会自动更新进度。",
                          footer: "保持本页打开可以看到进度，也可以直接关闭")
        case .done:
            return Header(tag: "登录完成", color: "var(--q4)", title: "登录完成，数据已同步",
                          message: "{summary}。可以回到便单 App 了。", footer: "全部完成，可以关闭本页")
        case .failed:
            return Header(tag: "登录未完成", color: "var(--red)", title: "登录没有完成",
                          message: "请回到便单 App 查看原因后重试。", footer: "可以关闭本页，回到便单 App")
        }
    }

    private static func stepInfo(_ s: LoginProgress.Snapshot) -> (StepState, StepState, String, String) {
        switch s.phase {
        case .exchanging: return (.now, .todo, s.detail, "")
        case .syncing: return (.done, .now, "", s.detail)
        case .done: return (.done, .done, "", summary(s.counts))
        case .failed:
            return s.failedStep == 3 ? (.fail, .todo, s.error ?? "", "") : (.done, .fail, "", s.error ?? "")
        }
    }

    private static func step(_ id: String, _ number: Int, _ text: String, _ state: StepState, _ detail: String) -> String {
        let badge = state == .done ? "✓" : (state == .fail ? "!" : "\(number)")
        let hidden = state == .now ? "" : " hidden"
        return "<li id=\"\(id)\" data-n=\"\(number)\" class=\"\(state.rawValue)\"><b>\(badge)</b>"
            + "<span class=\"t\">\(text)<small>\(escape(detail))</small></span>"
            + "<span class=\"wait\"\(hidden)>进行中</span></li>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - 轮询脚本

    private static func pollingScript(session: String, nonce: String, phase: LoginProgress.Phase) -> String {
        var heads: [String: [String: String]] = [:]
        for item in LoginProgress.Phase.allCases {
            let h = header(item)
            heads[item.rawValue] = ["tag": h.tag, "color": h.color, "title": h.title,
                                    "message": h.message, "footer": h.footer]
        }
        let data = (try? JSONSerialization.data(withJSONObject: heads, options: [.withoutEscapingSlashes, .sortedKeys]))
            ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
        return """
        <script nonce="\(nonce)">
        (function(){
        var S="\(session)",P="\(phase.rawValue)",H=\(json),fails=0;
        function q(id){return document.getElementById(id);}
        function sum(c){return c?('共 '+c.lists+' 个待办单、'+c.tasks+' 个任务、'+c.occurrences+' 个执行实例、'+c.focus+' 条专注记录'):'同步完成';}
        function mark(id,st,detail){var li=q(id);li.className=st;
          li.querySelector('b').textContent=st==='done'?'✓':(st==='fail'?'!':li.getAttribute('data-n'));
          li.querySelector('small').textContent=detail||'';li.querySelector('.wait').hidden=st!=='now';}
        function apply(s){
          var p=s.phase,f=p==='failed',f3=f&&s.failedStep===3;
          mark('s3',p==='exchanging'?'now':(f3?'fail':'done'),p==='exchanging'?s.detail:(f3?s.error:''));
          mark('s4',(p==='exchanging'||f3)?'':(p==='syncing'?'now':(p==='done'?'done':'fail')),
            p==='syncing'?s.detail:(p==='done'?sum(s.counts):((f&&!f3)?s.error:'')));
          var h=H[p];if(h){var t=q('tag');t.textContent=h.tag;t.style.background=h.color;
            q('title').textContent=h.title;q('msg').textContent=h.message.replace('{summary}',sum(s.counts));
            q('foot').textContent=h.footer;document.title='便单 · '+h.title;}
          if(p==='done'){q('card').className='card finished';}
          return p==='done'||f;
        }
        function tick(){
          fetch('/biandan/status?s='+S,{cache:'no-store'}).then(function(r){if(!r.ok)throw 0;return r.json();})
            .then(function(s){fails=0;if(!apply(s))setTimeout(tick,700);})
            .catch(function(){if(++fails>=8){q('msg').textContent='便单 App 已停止更新本页，请回到 App 查看登录结果。';return;}setTimeout(tick,1000);});
        }
        try{history.replaceState(null,'','/biandan/done');}catch(e){}
        if(P!=='done'&&P!=='failed'){tick();}
        })();
        </script>
        """
    }

    // MARK: - 页面骨架

    private static func document(title: String, tag: String, color: String, message: String,
                                 steps: String, footer: String, script: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light">
        <meta name="referrer" content="no-referrer">
        <title>便单 · \(title)</title>
        <style>
        :root{--bg:#F4EFE3;--panel:#FBF8F1;--card:#FFFDF8;--line:#E6DFCF;--text:#1F1D1A;--sub:#8A8273;
          --accent:#F5B800;--q1:#E5483A;--q2:#E9BC12;--q3:#4BA9E0;--q4:#5DB65A;--red:#D93025}
        *{box-sizing:border-box}
        [hidden]{display:none!important}
        html,body{margin:0}
        body{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:32px;
          background:var(--bg);color:var(--text);
          font:14px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif}
        .card{width:100%;max-width:440px;background:var(--card);border:1px solid var(--line);border-radius:14px;
          box-shadow:0 18px 50px rgba(60,48,20,.12);overflow:hidden;transition:box-shadow .4s}
        .card.finished{box-shadow:0 18px 50px rgba(93,182,90,.22)}
        .strip{display:grid;grid-template-columns:repeat(4,1fr);height:6px}
        .strip i:nth-child(1){background:var(--q1)}.strip i:nth-child(2){background:var(--q2)}
        .strip i:nth-child(3){background:var(--q3)}.strip i:nth-child(4){background:var(--q4)}
        .main{padding:34px 32px 26px;text-align:center}
        .logo{display:block;width:72px;height:72px;margin:0 auto 18px;border-radius:16px;
          box-shadow:0 6px 16px rgba(60,48,20,.18)}
        .tag{display:inline-block;padding:2px 10px;border-radius:999px;color:#fff;font-size:12px;font-weight:600;
          margin-bottom:10px;transition:background .3s}
        h1{margin:0 0 8px;font-size:24px;font-weight:800;letter-spacing:.5px}
        .msg{margin:0;color:var(--sub)}
        .steps{margin:22px 0 0;padding:4px 0;list-style:none;text-align:left;background:var(--panel);
          border:1px solid var(--line);border-radius:10px}
        .steps li{display:flex;align-items:center;gap:10px;padding:9px 14px;border-top:1px solid #F0EADD;
          color:var(--sub);font-size:13px}
        .steps li:first-child{border-top:none}
        .steps b{width:20px;height:20px;border-radius:50%;flex:none;display:flex;align-items:center;
          justify-content:center;font-size:11px;background:#EEE8DA;color:var(--sub);transition:background .3s}
        .t{display:flex;flex-direction:column;min-width:0}
        .t small{font-size:11.5px;font-weight:400;color:var(--sub);margin-top:1px}
        .t small:empty{display:none}
        .steps .done{color:var(--text)}
        .steps .done b{background:var(--q4);color:#fff}
        .steps .now{color:var(--text);font-weight:600}
        .steps .now b{background:var(--accent);color:#fff;animation:pulse 1.2s ease-in-out infinite}
        .steps .fail{color:var(--red);font-weight:600}
        .steps .fail b{background:var(--red);color:#fff}
        .steps .fail small{color:var(--red)}
        .wait{margin-left:auto;flex:none;font-size:11px;font-weight:600;color:#9A7400;background:#FFF1C2;
          border-radius:999px;padding:1px 8px}
        @keyframes pulse{50%{opacity:.45}}
        .foot{padding:14px 32px;border-top:1px solid var(--line);background:var(--panel);color:var(--sub);
          font-size:12px;text-align:center}
        kbd{font:11px ui-monospace,SFMono-Regular,Menlo,monospace;background:#EEE8DA;border-radius:4px;
          padding:1px 6px;color:#6B6457;margin-left:4px}
        </style>
        </head>
        <body>
        <main class="card" id="card">
        <div class="strip"><i></i><i></i><i></i><i></i></div>
        <div class="main">
        <img class="logo" src="\(BrandIcon.dataURI)" alt="便单" width="72" height="72">
        <span class="tag" id="tag" style="background:\(color)">\(tag)</span>
        <h1 id="title">\(title)</h1>
        <p class="msg" id="msg">\(message)</p>
        \(steps)
        </div>
        <div class="foot"><span id="foot">\(footer)</span><kbd>⌘W</kbd></div>
        </main>
        \(script)
        </body>
        </html>
        """
    }
}
