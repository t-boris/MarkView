import Foundation

// The tab checks open no archive: this stands in for `Archive` (MarkView/Models/Shared/ArchiveSupport.swift), which `TabsController` asks
// whether a file is one. The file operations check compiles the real `Archive` instead, as it unpacks and zips for real.
enum Archive { static func isArchive(_ url: URL) -> Bool { false } }
