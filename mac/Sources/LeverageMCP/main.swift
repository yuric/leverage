import Foundation

FileHandle.standardError.write(Data("not built\n".utf8))
exit(2)
