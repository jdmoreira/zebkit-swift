// Prints a page's title, and saves a picture of it: a program that is one
// asynchronous function. No window is needed for either.
//
//     swift run title https://example.com/ [picture.png]

import Foundation
import Zebkit

let arguments = CommandLine.arguments.filter { !$0.hasPrefix("--") }
guard arguments.count >= 2 else {
    print("usage: title <url> [picture.png] [Chromium's switches, as --no-sandbox]")
    exit(2)
}

// Chromium's switches among the program's arguments are the engine's.
exit(Engine.run(arguments: CommandLine.arguments + ["--headless"], until: {
    let view = try WebView(url: arguments[1], width: 1280, height: 800)
    try await view.loadFinished()
    print(try await view.evaluate("document.title", as: String.self))
    if arguments.count > 2 {
        try await view.capture().write(to: URL(fileURLWithPath: arguments[2]))
    }
}))
