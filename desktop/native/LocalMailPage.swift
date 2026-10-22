import Foundation

@MainActor final class LocalMailPage {
    private let server = SubscriptionServer(port: 0)
    private var token = ""
    private var expiresAt = Date.distantPast
    private var pageURL: URL?
    private var expiryTask: Task<Void, Never>?
    private static var allowed: Set<URL> = []
    static func permits(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return allowed.contains(url)
    }
    func stop() {
        expiryTask?.cancel(); expiryTask = nil
        if let pageURL { Self.allowed.remove(pageURL) }
        pageURL = nil; token = ""; server.localPage = nil; server.stop()
    }
    func open(model: MailAssistantModel, email: String) async throws -> URL {
        stop()
        let email = try AccountPoolStore.email(email)
        token = try SubscriptionCore.token(32)
        let current = token
        expiresAt = Date().addingTimeInterval(600)
        server.localPage = { [weak self, weak model] path in
            guard let self, let model, self.token == current, Date() < self.expiresAt else { return nil }
            let root = "/mail/\(current)"
            let headers = [
                "Referrer-Policy": "no-referrer",
                "X-Frame-Options": "DENY",
                "Content-Security-Policy": "default-src 'none'; script-src 'nonce-\(current)'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
            ]
            if path == root { return (Self.html(nonce: current), "text/html; charset=utf-8", headers) }
            if path == root + "/state" {
                var result: [String: Any] = ["email": email, "status": model.status, "waiting": model.waiting]
                if let code = model.code { result["code"] = code }
                if let link = model.loginURL, let valid = ClaudeMailLink.validated(link.absoluteString, email: email) { result["loginURL"] = valid.absoluteString }
                guard let data = try? JSONSerialization.data(withJSONObject: result), let body = String(data: data, encoding: .utf8) else { return nil }
                return (body, "application/json; charset=utf-8", headers)
            }
            return nil
        }
        server.start()
        for _ in 0..<50 {
            guard token == current, !Task.isCancelled else { throw CancellationError() }
            if server.ready {
                guard let url = URL(string: "http://127.0.0.1:\(server.port)/mail/\(current)") else { throw SubscriptionFailure("无法创建本地邮件页。") }
                pageURL = url; Self.allowed.insert(url)
                expiryTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 600_000_000_000) } catch { return }
                    guard self?.token == current else { return }; self?.stop()
                }
                return url
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        stop(); throw SubscriptionFailure("本地邮件页面启动失败，请重试。")
    }
    private static func html(nonce: String) -> String {
        """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>登录邮件 · cc助手</title>
        <style>
        :root{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#282724;background:#faf9f6;color-scheme:light dark}*{box-sizing:border-box}body{margin:0;padding:8vh 24px}main{max-width:650px;margin:auto}small{color:#9b4934;font-weight:600}h1{font-size:34px;letter-spacing:-1px;margin:18px 0 12px}p{line-height:1.65;color:#72716b}section{background:#fff;border:1px solid #e8e5df;border-radius:20px;padding:28px;margin:28px 0}#email{font-size:19px;font-weight:600;overflow-wrap:anywhere}#status{min-height:52px}.actions{display:flex;gap:12px;align-items:center;flex-wrap:wrap}a,button{border:0;border-radius:10px;padding:13px 20px;background:#ab4229;color:white;font:inherit;text-decoration:none;cursor:pointer}button{background:#f3e9e5;color:#9b4934}#code{font:600 32px ui-monospace,monospace;letter-spacing:4px;margin:18px 0}[hidden]{display:none!important}footer{font-size:12px;color:#85847e}@media(prefers-color-scheme:dark){:root{background:#20201e;color:#ece9e2}section{background:#292926;border-color:#42413b}p,footer{color:#b9b6af}button{background:#49352f;color:#efb29e}}
        </style><main><small>CC助手 · 本地邮件辅助</small><h1>在这里继续登录。</h1><p>在官网发送登录邮件后，这里会自动更新。</p><section><div id="email">正在连接…</div><p id="status" role="status" aria-live="polite">读取当前账号的邮件状态。</p><div id="code" hidden></div><div class="actions"><a id="login" hidden rel="noreferrer">继续登录 Claude ↗</a><button id="copy" hidden>复制验证码</button><button id="refresh">刷新状态</button></div></section><footer>只显示当前邮箱 · 最长等待 10 分钟 · 原邮件仍转发到 iCloud<br>登录链接在当前浏览器打开。关闭 cc助手的注册窗口后，本页停止提供邮件内容。</footer></main>
        <script nonce="\(nonce)">
        const email=document.getElementById('email'),status=document.getElementById('status'),code=document.getElementById('code'),login=document.getElementById('login'),copy=document.getElementById('copy');let busy=false,ended=false;
        async function update(){if(busy||ended)return;busy=true;try{const r=await fetch(location.pathname+'/state',{cache:'no-store',credentials:'omit',redirect:'error'});if(!r.ok)throw new Error('closed');const d=await r.json();email.textContent=d.email;status.textContent=d.status;code.textContent=d.code||'';code.hidden=!d.code;copy.hidden=!d.code;login.hidden=true;login.removeAttribute('href');if(d.loginURL){const u=new URL(d.loginURL);if(u.origin==='https://claude.ai'&&u.pathname==='/magic-link'&&!u.username&&!u.password&&!u.search&&u.hash){login.href=u.href;login.hidden=false}}}catch{ended=true;code.textContent='';code.hidden=true;copy.hidden=true;login.hidden=true;login.removeAttribute('href');status.textContent='本次邮件页已关闭或过期，请返回 cc助手重新打开。'}finally{busy=false}}
        copy.addEventListener('click',async()=>{try{await navigator.clipboard.writeText(code.textContent);copy.textContent='已复制'}catch{status.textContent='无法自动复制，请选中验证码手动复制。'}});document.getElementById('refresh').addEventListener('click',()=>{ended=false;update()});update();setInterval(update,2000);
        </script></html>
        """
    }
}
