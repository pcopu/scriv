import UIKit

#if SCRIV_CLI_AUTOMATION
import Darwin
do { try prepareScrivCLIEnvironment() }
catch {
    fputs("SCRIV_CLI isolated setup failed\n", stderr)
    exit(EXIT_FAILURE)
}
#endif

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, NSStringFromClass(ScrivUIKitApplication.self), NSStringFromClass(ScrivUIKitAppDelegate.self))
