# TododdleSupport iOS example

`ExampleApp.swift` is a complete SwiftUI app in one file. It shows the report sheet, a headless
report and the offline queue.

To run it:

1. In Xcode, choose File > New > Project > iOS > App (SwiftUI, iOS 16 or later).
2. Choose File > Add Package Dependencies, then Add Local and pick the root of this repository
   (or use `https://github.com/krffl/tododdle-support`). Add the `TododdleSupport` library to the app.
3. Replace the generated `<Name>App.swift` and `ContentView.swift` with `ExampleApp.swift`.
4. Put your project's public SDK key in `ExampleApp.swift`. Use a test key (`tdsk_test_…`) while
   you try it, so its tickets are marked as test reports.
5. Run it on a simulator or device.

The photo picker needs no permission prompt. The "Add screenshot" button attaches the screen
the app captured just before it opened the sheet, and only when the person taps it.
