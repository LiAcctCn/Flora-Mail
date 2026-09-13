import Foundation

/// Provider-independent mail operations. A future remote adapter must preserve
/// the executor's permission boundary before performing any external writes.
@MainActor
public protocol MailProvider {
    var name: String { get }
    func fetchAccounts() async throws -> [MailAccount]
    func fetchFolders() async throws -> [MailFolder]
    func fetchMessages(folder: MailFolder?) async throws -> [MailMessage]
    func fetchThread(id: UUID) async throws -> MailThread
    @discardableResult func perform(_ proposal: ProposedAction, confirmed: Bool) async throws -> ExecutedAction
}

/// Runs against the exact same committed state as the UI. No credentials,
/// network requests, or separate in-memory mailbox are involved.
@MainActor
public final class DemoMailProvider: MailProvider {
    public let name = "Demo Mail · Local only"
    private let executor: ActionExecutor
    public init(executor: ActionExecutor) { self.executor = executor }
    public func fetchAccounts() async throws -> [MailAccount] { executor.state.accounts.filter { !$0.isRemote } }
    public func fetchFolders() async throws -> [MailFolder] { MailFolder.allCases }
    public func fetchMessages(folder: MailFolder? = nil) async throws -> [MailMessage] {
        let demoAccountIDs = Set(executor.state.accounts.filter { !$0.isRemote }.map(\.id))
        return executor.state.messages.filter { demoAccountIDs.contains($0.accountID) && (folder == nil || $0.folder == folder) }.sorted { $0.date > $1.date }
    }
    public func fetchThread(id: UUID) async throws -> MailThread {
        let demoAccountIDs = Set(executor.state.accounts.filter { !$0.isRemote }.map(\.id))
        let messages = executor.state.messages.filter { demoAccountIDs.contains($0.accountID) && $0.threadID == id }.sorted { $0.date < $1.date }
        guard !messages.isEmpty else { throw MailActionError.messageNotFound }
        return MailThread(id: id, messages: messages)
    }
    @discardableResult
    public func perform(_ proposal: ProposedAction, confirmed: Bool = false) async throws -> ExecutedAction {
        try executor.execute(proposal, confirmed: confirmed)
    }
}
