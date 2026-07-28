import PGClonerCore
import Testing

@testable import PGClonerPostgres

@Suite("Clone retry policy")
struct CloneRetryPolicyTests {
  @Test("Transient PostgreSQL SQLSTATE values are retryable")
  func transientSQLStates() {
    for state in ["40001", "40P01", "55P03", "57014"] {
      #expect(CloneRetryPolicy.isRetryableSQLState(state))
    }
  }

  @Test("Permanent PostgreSQL SQLSTATE values are not retryable")
  func permanentSQLStates() {
    for state in ["23505", "42501", "42601", "22P02"] {
      #expect(!CloneRetryPolicy.isRetryableSQLState(state))
    }
  }

  @Test("Cancellation is never retryable and delays follow the backoff schedule")
  func cancellationAndDelay() {
    #expect(!CloneRetryPolicy.isRetryable(CancellationError()))
    #expect(CloneRetryPolicy.delay(forRetry: 1) == .seconds(1))
    #expect(CloneRetryPolicy.delay(forRetry: 2) == .seconds(3))
    #expect(CloneRetryPolicy.delay(forRetry: 5) == .seconds(3))
  }
}
