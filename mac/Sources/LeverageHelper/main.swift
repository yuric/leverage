import Foundation

// The helper (plan §2.2): signs in with its token, does the server's
// requests, and stops its runs on a stop signal or when the app is gone.
// Exit codes are HelperExitCode's: 0 stopped, 2 no token, 3 token ended.

exit(await HelperMain.run())
