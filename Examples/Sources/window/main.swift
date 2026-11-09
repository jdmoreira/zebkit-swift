// A window with a page in it, and a function of the application's that the
// page may call.
//
//     swift run window [url]

import Foundation
import Zebkit

let page = """
    data:text/html,<title>Zebkit</title>
    <body style="font: 16px system-ui; margin: 3em">
    <h1>Hello from Chromium</h1>
    <button onclick="zebkit.app.greet('Swift').then(answer => out.textContent = answer)">Call the application</button>
    <p id="out"></p>
    """

let url = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }

exit(Engine.run {
    let view = try WebView(url: url ?? page, width: 1024, height: 768)
    // The page gets `zebkit.app` and nothing else of `zebkit.*`; only the
    // application's own page gets that much.
    if url == nil { view.grant(.app, to: "*") }
    view.bind("greet", answering: { call in
        "hello, \(try call.arguments(as: [String].self)[0]), from \(Engine.engineVersion)"
    })
    view.onTitle = { title in print("title: \(title)") }
    // The loop does not end with the last window: that is the application's to say.
    view.onClose = { Engine.quit() }
})
