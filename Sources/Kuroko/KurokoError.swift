enum KurokoError: Error, CustomStringConvertible {
    case virtualDisplay(String)
    case capture(String)

    var description: String {
        switch self {
        case .virtualDisplay(let message): "Virtual display: \(message)"
        case .capture(let message): "Capture: \(message)"
        }
    }
}
