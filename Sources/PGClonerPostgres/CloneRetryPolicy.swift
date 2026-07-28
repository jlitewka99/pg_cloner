import Foundation
import PGClonerCore
import PostgresNIO

enum CloneRetryPolicy {
  static let retryableSQLStates: Set<String> = ["40001", "40P01", "55P03", "57014"]

  static func isRetryable(_ error: Error) -> Bool {
    if error is CancellationError || Task.isCancelled {
      return false
    }
    if let postgresError = error as? PSQLError {
      if let sqlState = postgresError.serverInfo?[.sqlState],
        isRetryableSQLState(sqlState)
      {
        return true
      }
      return isDisconnect(postgresError)
    }
    if let postgresError = error as? PostgresError,
      case .server(let serverError) = postgresError,
      let sqlState = serverError.fields[.sqlState]
    {
      return isRetryableSQLState(sqlState)
    }
    return false
  }

  static func isRetryableSQLState(_ sqlState: String) -> Bool {
    retryableSQLStates.contains(sqlState)
  }

  static func isDisconnect(_ error: Error) -> Bool {
    guard let postgresError = error as? PSQLError else { return false }
    return postgresError.code == .clientClosedConnection
      || postgresError.code == .serverClosedConnection
      || postgresError.code == .connectionError
      || postgresError.code == .uncleanShutdown
  }

  static func delay(forRetry retry: Int) -> Duration {
    switch retry {
    case 1: .seconds(1)
    default: .seconds(3)
    }
  }
}

enum CloneTableFailure: Error {
  case source(Error)
  case target(Error)

  var underlying: Error {
    switch self {
    case .source(let error), .target(let error): error
    }
  }
}

struct SourceTableRetryRequired: Error {
  let table: TableReference
  let underlying: Error
}
