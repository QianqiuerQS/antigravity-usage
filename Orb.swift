import Cocoa
import WebKit

private extension URL {
    var appendingRankFragment: URL { URL(string: "#rank", relativeTo: self)!.absoluteURL }
}

final class FirstMouseWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class RankingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        let point = event.locationInWindow
        // The trailing edge of the header contains the collapse button.
        if event.type == .leftMouseDown, point.y > frame.height - 58,
           point.x > 10, point.x < frame.width - 140 {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
}

class OrbPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        let point = event.locationInWindow
        let center = NSPoint(x: 66, y: frame.height - 66)
        guard event.type == .leftMouseDown,
              hypot(point.x - center.x, point.y - center.y) <= 61 else {
            super.sendEvent(event)
            return
        }
        let start = convertPoint(toScreen: point)
        let origin = frame.origin
        var dragging = false
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let cursor = convertPoint(toScreen: next.locationInWindow)
            let dx = cursor.x - start.x
            let dy = cursor.y - start.y
            if hypot(dx, dy) >= 4 { dragging = true }
            if dragging {
                setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
            }
            if next.type == .leftMouseUp {
                if !dragging {
                    (contentView as? WKWebView)?.evaluateJavaScript("document.getElementById('bubble')?.click()")
                }
                break
            }
        }
    }
}

class Orb: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    let window = OrbPanel(contentRect: NSRect(x: 0,y: 0,width: 132,height: 132),
                          styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
    let url = URL(string:"http://127.0.0.1:18742/")!
    var web: WKWebView!
    var rankPanel: NSPanel?
    var settingsOpen = false
    var backend: Process?
    func applicationDidFinishLaunching(_ note: Notification) {
        let task = Process()
        task.executableURL = Bundle.main.url(forAuxiliaryExecutable: "UsageBackend")
        task.arguments = ["--quiet"]
        do {
            try task.run()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法启动用量服务"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        backend = task
        let config = WKWebViewConfiguration()
        config.userContentController.add(self,name:"orb")
        web = FirstMouseWebView(frame:window.contentView!.bounds,configuration:config)
        web.setValue(false,forKey:"drawsBackground")
        web.navigationDelegate = self
        window.contentView = web
        window.title = "Antigravity 用量悬浮球"
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let screen = NSScreen.main!.visibleFrame
        window.setFrameTopLeftPoint(NSPoint(x:screen.maxX-148,y:screen.maxY-32))
        window.orderFrontRegardless()
        web.load(URLRequest(url:url))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.asyncAfter(deadline:.now()+1){ webView.load(URLRequest(url:webView === self.web ? self.url : self.url.appendingRankFragment)) }
    }
    func activateApp() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
    func openRankPanel() {
        if let panel = rankPanel {
            activateApp()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let bounds = (window.screen ?? NSScreen.main)!.visibleFrame
        let panel = RankingPanel(contentRect: NSRect(x:0, y:0, width:min(760,bounds.width), height:min(520,bounds.height-32)),
                            styleMask:[.borderless,.resizable], backing:.buffered, defer:false)
        panel.title = "Antigravity 用量排行"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width:560,height:340)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let left = window.frame.minX - panel.frame.width - 8
        let x = left >= bounds.minX ? left : window.frame.maxX + 8
        panel.setFrameTopLeftPoint(NSPoint(x:min(max(x,bounds.minX),bounds.maxX-panel.frame.width),
                                           y:min(bounds.maxY,max(window.frame.maxY,bounds.minY+panel.frame.height))))
        let config = WKWebViewConfiguration()
        config.userContentController.add(self,name:"orb")
        let view = FirstMouseWebView(frame:.zero,configuration:config)
        view.setValue(false, forKey:"drawsBackground")
        panel.contentView = view
        view.navigationDelegate = self
        rankPanel = panel
        activateApp()
        panel.makeKeyAndOrderFront(nil)
        view.load(URLRequest(url:url.appendingRankFragment))
    }

    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage){
        guard let action = message.body as? String else{return}
        if action == "quit" { NSApp.terminate(nil);return }
        if action == "closeRank" { rankPanel?.orderOut(nil);return }
        if action == "settings" {
            rankPanel?.orderOut(nil)
            self.web.evaluateJavaScript("expand(true)")
            return
        }
        var size = NSSize(width:132,height:132)
        if action == "expand" { settingsOpen = true; size = NSSize(width:320,height:378) }
        if action == "collapse" { settingsOpen = false }

        if let bounds = window.screen?.visibleFrame {
            size.width = min(size.width, bounds.width)
            size.height = min(size.height, bounds.height)
        }
        let prev = window.frame
        var x = prev.maxX-size.width
        var y = prev.maxY-size.height
        if let screen = window.screen?.visibleFrame {
            x = min(max(x,screen.minX),screen.maxX-size.width)
            y = min(max(y,screen.minY),screen.maxY-size.height)
        }
        window.setFrame(NSRect(origin:NSPoint(x:x,y:y),size:size),display:true)
        if action == "rank" { openRankPanel();return }
        if action != "collapse" { NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil) }
    }
    func applicationDidResignActive(_ notification: Notification) {
        guard settingsOpen else { return }
        self.web.evaluateJavaScript("expand(false)")
    }
    func applicationWillTerminate(_ notification: Notification) {
        if backend?.isRunning == true { backend?.terminate() }
    }
}
let app=NSApplication.shared
let delegate=Orb()
app.delegate=delegate
app.setActivationPolicy(.accessory)
app.run()
