import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if args.contains("--windows") {
        SelfTest.windows()
        exit(0)
    }
    if args.contains("--experiment") {
        SelfTest.experiment()
        exit(0)
    }
    if args.contains("--evaluate") {
        SelfTest.evaluate()
        exit(0)
    }
    if args.contains("--panes") {
        SelfTest.panes()
        exit(0)
    }
    if args.contains("--focus-test") {
        SelfTest.focusTest()
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    if let i = args.firstIndex(of: "--render-ui"), i + 1 < args.count {
        SelfTest.renderUI(to: args[i + 1])
        exit(0)
    }

    if let i = args.firstIndex(of: "--diagnose") {
        let seconds = i + 1 < args.count ? Double(args[i + 1]) ?? 10 : 10
        SelfTest.diagnose(seconds: seconds)
        app.run()
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
