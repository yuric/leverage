import LeverageKit
#if canImport(LeverageAppServices)
import LeverageAppServices
#endif

/// Builds the services the app runs with. Until WP18 it returns
/// `UnavailableRuntime` everywhere; in the `app` build lane, where
/// LeverageAppServices is not built, it always will.
enum Live {
    static func runtime() -> any AppRuntime {
        UnavailableRuntime()
    }
}
