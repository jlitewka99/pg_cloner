import Foundation
import PGClonerCore
import Testing

@Suite("Clone execution options")
struct CloneExecutionOptionsTests {
  @Test("Defaults provide a five-minute statement timeout and two retries")
  func defaults() {
    let options = CloneExecutionOptions()

    #expect(options.queryTimeoutSeconds == 300)
    #expect(options.retryAttempts == 2)
    #expect(throws: Never.self) {
      try options.validated()
    }
  }

  @Test("Zero query timeout disables statement timeout")
  func zeroTimeoutIsValid() {
    #expect(throws: Never.self) {
      try CloneExecutionOptions(queryTimeoutSeconds: 0, retryAttempts: 0).validated()
    }
  }

  @Test("Execution options reject values outside safe ranges")
  func validatesRanges() {
    #expect(throws: CloneEngineError.self) {
      try CloneExecutionOptions(queryTimeoutSeconds: -1).validated()
    }
    #expect(throws: CloneEngineError.self) {
      try CloneExecutionOptions(retryAttempts: 6).validated()
    }
  }

  @Test("Clone requests encode execution options")
  func cloneRequestCoding() throws {
    let request = CloneRequest(
      sourceProfileID: UUID(),
      targetProfileID: UUID(),
      selectedTables: [TableReference(name: "events")],
      options: CopyOptions(limit: 1),
      executionOptions: .init(queryTimeoutSeconds: 45, retryAttempts: 4)
    )

    let decoded = try JSONDecoder().decode(
      CloneRequest.self,
      from: JSONEncoder().encode(request)
    )
    #expect(decoded.executionOptions == request.executionOptions)
  }
}
