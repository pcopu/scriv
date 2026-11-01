import Foundation

struct ScrivUpdatePresentation {
    let title: String
    let detail: String
    let primary: String?
    let secondary: String?
    let symbol: String
    let showsProgress: Bool
    init(phase: String, version: String = "") {
        showsProgress = ["downloading", "verifying"].contains(phase)
        switch phase {
        case "available":
            title = "A fresh take."; detail = "Scriv \(version) is available. Downloading prepares this update for installation. If you quit Scriv after it is prepared, it may install on quit. Choose Later to cancel it."
            primary = "Download & Update"; secondary = "Not now"; symbol = "arrow.down.circle"
        case "downloading": title = "Getting ready."; detail = "Downloading the signed update…"; primary = nil; secondary = "Cancel"; symbol = "arrow.down.circle"
        case "verifying": title = "Checking every detail."; detail = "Verifying the signature and preparing the update…"; primary = nil; secondary = nil; symbol = "checkmark.shield"
        case "saving": title = "Saving your place."; detail = "Scriv is checking that your work is safely saved before continuing."; primary = nil; secondary = nil; symbol = "doc.badge.checkmark"
        case "ready": title = "Ready when you are."; detail = "Scriv will save your work, install the verified update, and reopen. Later cancels this prepared installation."; primary = "Update & Relaunch"; secondary = "Later"; symbol = "checkmark.circle"
        case "retryQuit", "waitingToQuit": title = "Waiting to close Scriv."; detail = "The verified update is prepared. Scriv must close before installation can finish. It may install when you quit."; primary = "Try Quit & Relaunch"; secondary = "Keep Working"; symbol = "arrow.triangle.2.circlepath"
        case "retryBlocked": title = "Your work comes first."; detail = "Scriv could not confirm that your latest changes were saved. The update is still prepared; save your work before quitting."; primary = "Close"; secondary = nil; symbol = "doc.badge.exclamationmark"
        case "installing": title = "See you in a moment."; detail = "Installing Scriv. Your projects and recovery drafts are kept."; primary = nil; secondary = nil; symbol = "arrow.triangle.2.circlepath"
        case "current": title = "You’re up to date."; detail = "You have the latest compatible release of Scriv."; primary = "Done"; secondary = nil; symbol = "checkmark.circle"
        case "complete": title = "A fresh start."; detail = "Scriv has been updated."; primary = "Done"; secondary = nil; symbol = "checkmark.circle"
        case "blocked": title = "Updates are on their way."; detail = "This development build is waiting for release signing."; primary = "Done"; secondary = nil; symbol = "lock.shield"
        case "error": title = "Let’s keep this version."; detail = "The update could not be completed. Your projects and recovery drafts were kept."; primary = "Close"; secondary = nil; symbol = "exclamationmark.shield"
        default: title = "Checking for a fresh take."; detail = "Looking for a signed Scriv release…"; primary = nil; secondary = "Cancel"; symbol = "arrow.clockwise"
        }
    }
}
