import UIKit

struct ContinuousEPUBStyle {
    let backgroundColor: UIColor
    let css: String

    init(settings: ReaderSettings, dark: Bool, fontsURL: URL) {
        let level = dark ? 23 : 255
        backgroundColor = UIColor(white: CGFloat(level) / 255, alpha: 1)
        let background = "rgb(\(level),\(level),\(level))"
        let foreground = dark ? "#e8e8e8" : "#202020"
        let fonts = fontsURL.absoluteString
        css = """
        @font-face {font-family:'Source Serif 4';src:url('\(fonts)SourceSerif4-Regular.ttf')}
        @font-face {font-family:'Source Serif 4';src:url('\(fonts)SourceSerif4-It.ttf');font-style:italic}
        @font-face {font-family:'Source Serif 4';src:url('\(fonts)SourceSerif4-Bold.ttf');font-weight:bold}
        @font-face {font-family:'Source Serif 4';src:url('\(fonts)SourceSerif4-BoldIt.ttf');font-style:italic;font-weight:bold}
        @font-face {font-family:'LXGW WenKai';src:url('\(fonts)LXGWWenKai-Regular.ttf')}
        html {height:auto!important;min-height:0!important;overflow:hidden!important;column-count:auto!important;column-width:auto!important;writing-mode:horizontal-tb!important;background:\(background)!important;color:\(foreground)!important;font-size:\(settings.fontSize)%!important;-webkit-text-size-adjust:100%}
        body {height:auto!important;min-height:0!important;overflow:visible!important;margin:0!important;padding:16px \(24 * settings.pageMargins)px!important;box-sizing:border-box!important;font-family:\(settings.font.cssStack)!important;line-height:\(settings.lineHeight)!important;writing-mode:horizontal-tb!important;color:inherit!important;background:transparent!important}
        body * {font-family:inherit!important;line-height:inherit!important}
        body pre,body code,body kbd,body samp {font-family:monospace!important}
        img,svg,video,object {max-width:100%!important;height:auto;box-sizing:border-box}
        table,pre {max-width:100%;overflow-wrap:anywhere} pre {white-space:pre-wrap}
        """
    }
}
