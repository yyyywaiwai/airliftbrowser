enum AppFinderExportEvent: Sendable {
    case started(String)
    case progress(AppResponse)
    case finished(String, failure: String?)
}
