/// How long each part of a stop is given, in one place, so the app, the
/// helper and the runner agree (CL-23, PK-8). When the app quits, it asks the
/// helper to stop and gives it `helperStopGrace`; the helper asks each runner
/// to stop and ends a runner's group after `runnerStopGrace`; a stopping
/// runner spends at most `runnerGiveBack` giving back what its seat holds,
/// after its tool was given its own 5 seconds. Each wait is longer than the
/// one inside it, so no part is ended while the part it waits on still has
/// time.
public enum StopTimings {
    /// How long a stopping runner waits to give back what its seat holds.
    public static let runnerGiveBack: Duration = .seconds(4)
    /// How long the helper gives a runner it asked to stop before it ends
    /// the runner's group.
    public static let runnerStopGrace: Duration = .seconds(10)
    /// How long the app gives the helper to stop before it is forced: the
    /// helper's grace for its runners, a runner's give-back, and two
    /// seconds for the helper's own last reports.
    public static let helperStopGrace: Duration = runnerStopGrace + runnerGiveBack + .seconds(2)
}
