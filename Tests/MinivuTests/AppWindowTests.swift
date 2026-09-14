import Testing

/// Suites that open the app's windows and drive its shared services, run one
/// at a time. `ImageLoader.shared` keeps a single prefetch set for the whole
/// app, so a browser window closing in one test (which clears it) would
/// cancel the neighbours another test is waiting for; and there is only ever
/// one viewer.
@MainActor @Suite(.serialized) enum AppWindowTests {}
