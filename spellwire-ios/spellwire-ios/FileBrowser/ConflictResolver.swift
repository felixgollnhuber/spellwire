import Foundation

actor ConflictResolver {
    func hasConflict(expected: RemoteRevision?, current: RemoteRevision?) -> Bool {
        switch (expected, current) {
        case (nil, nil):
            return false
        case let (lhs?, rhs?):
            return lhs != rhs
        default:
            return true
        }
    }
}
