// Sets a file's Finder icon (used for the .dmg). Usage: swift set-dmg-icon.swift <icns> <file>
import Cocoa
let a = CommandLine.arguments
guard a.count == 3, let img = NSImage(contentsOfFile: a[1]) else {
    FileHandle.standardError.write(Data("usage: set-dmg-icon.swift <icns> <file>\n".utf8)); exit(1)
}
exit(NSWorkspace.shared.setIcon(img, forFile: a[2], options: []) ? 0 : 1)
