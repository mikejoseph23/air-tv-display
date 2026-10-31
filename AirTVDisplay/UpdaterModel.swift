// SPDX-License-Identifier: MIT
import AppKit
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// Sparkle runs the whole update flow (appcast fetch, EdDSA check, download, install on quit) from
/// the `SU*` keys in `Info.plist` (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`,
/// `SUScheduledCheckInterval`). This owns the controller and exposes what the menus and the
/// Settings window need. Sparkle persists the automatic-check preference in its own defaults.
final class UpdaterModel {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    /// False while a check is already running, so menus can disable the item.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// Shows Sparkle's standard "Check for Updates" UI.
    func checkForUpdates() { controller.checkForUpdates(nil) }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

/// The standard About panel, with credits naming the license and linking the source.
enum AboutPanel {
    static let sourceURL = URL(string: "https://github.com/mikejoseph23/air-tv-display")!

    static func show() {
        let credits = NSMutableAttributedString(
            string: "Free software under the GNU General Public License v3. It includes UxPlay (GPLv3), "
                + "Sparkle (MIT), OpenSSL (Apache-2.0), libplist (LGPL-2.1) and llhttp (MIT); "
                + "see LICENSE and LICENSES.md in the app's Resources.\n\nSource: ",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: sourceURL.absoluteString,
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .link: sourceURL]))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        credits.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        // Above the fullscreen receiver window (.mainMenu + 1), like the Settings window.
        for w in NSApp.windows where w is NSPanel && w.isVisible { w.level = .mainMenu + 2 }
    }
}
