import Foundation

public struct MailAddress: Codable, Hashable, Sendable {
    public var name: String
    public var email: String
    public init(name: String, email: String) { self.name = name; self.email = email }
}

public struct MailAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var address: MailAddress
    public var provider: String
    public var providerType: MailProviderType
    public var providerAccountID: String?
    public var oauthClientID: String?
    public var credentialReference: MailCredentialReference?
    public var status: MailAccountStatus
    public var syncState: MailSyncState
    public init(id: UUID = UUID(), name: String, address: MailAddress, provider: String = "Demo", providerType: MailProviderType = .demo, providerAccountID: String? = nil, credentialReference: MailCredentialReference? = nil, status: MailAccountStatus = .connected, syncState: MailSyncState = MailSyncState(), oauthClientID: String? = nil) {
        self.id = id; self.name = name; self.address = address; self.provider = provider
        self.providerType = providerType; self.providerAccountID = providerAccountID; self.credentialReference = credentialReference
        self.status = status; self.syncState = syncState
        self.oauthClientID = oauthClientID
    }
    public var isReadOnly: Bool { providerType != .demo }
    private enum CodingKeys: String, CodingKey { case id, name, address, provider, providerType, providerAccountID, credentialReference, status, syncState, oauthClientID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
        address = try values.decode(MailAddress.self, forKey: .address); provider = try values.decode(String.self, forKey: .provider)
        providerType = try values.decodeIfPresent(MailProviderType.self, forKey: .providerType) ?? .demo
        providerAccountID = try values.decodeIfPresent(String.self, forKey: .providerAccountID)
        oauthClientID = try values.decodeIfPresent(String.self, forKey: .oauthClientID)
        credentialReference = try values.decodeIfPresent(MailCredentialReference.self, forKey: .credentialReference)
        status = try values.decodeIfPresent(MailAccountStatus.self, forKey: .status) ?? .connected
        syncState = try values.decodeIfPresent(MailSyncState.self, forKey: .syncState) ?? MailSyncState()
    }
}

public enum MailFolder: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox, sent, drafts, archive, trash
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct MailAttachment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var size: Int
    public var providerID: String?
    public var mimeType: String
    public var isInline: Bool
    public var contentID: String?
    public var downloadState: AttachmentDownloadState
    public var localRelativePath: String?
    public init(id: UUID = UUID(), name: String, size: Int, providerID: String? = nil, mimeType: String = "application/octet-stream", isInline: Bool = false, contentID: String? = nil, downloadState: AttachmentDownloadState = .notDownloaded, localRelativePath: String? = nil) {
        self.id = id; self.name = name; self.size = size; self.providerID = providerID; self.mimeType = mimeType
        self.isInline = isInline; self.contentID = contentID; self.downloadState = downloadState; self.localRelativePath = localRelativePath
    }
    private enum CodingKeys: String, CodingKey { case id, name, size, providerID, mimeType, isInline, contentID, downloadState, localRelativePath }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name); size = try values.decode(Int.self, forKey: .size)
        providerID = try values.decodeIfPresent(String.self, forKey: .providerID)
        mimeType = try values.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        isInline = try values.decodeIfPresent(Bool.self, forKey: .isInline) ?? false
        contentID = try values.decodeIfPresent(String.self, forKey: .contentID)
        downloadState = try values.decodeIfPresent(AttachmentDownloadState.self, forKey: .downloadState) ?? .notDownloaded
        localRelativePath = try values.decodeIfPresent(String.self, forKey: .localRelativePath)
    }
}

public struct MailMessage: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var providerID: String
    public var accountID: UUID
    public var threadID: UUID
    public var from: MailAddress
    public var to: [MailAddress]
    public var subject: String
    public var body: String
    public var date: Date
    public var folder: MailFolder
    public var isRead: Bool
    public var isFlagged: Bool
    public var categoryID: UUID?
    public var attachments: [MailAttachment]
    public var providerThreadID: String?
    public var providerFolderIDs: [String]
    public var htmlBody: String?
    public var cc: [MailAddress]
    public var isImportant: Bool
    public var contentWarnings: [String]
    public init(id: UUID = UUID(), providerID: String = "", accountID: UUID, threadID: UUID = UUID(), from: MailAddress, to: [MailAddress], subject: String, body: String, date: Date = Date(), folder: MailFolder = .inbox, isRead: Bool = false, isFlagged: Bool = false, categoryID: UUID? = nil, attachments: [MailAttachment] = [], providerThreadID: String? = nil, providerFolderIDs: [String] = [], htmlBody: String? = nil, cc: [MailAddress] = [], isImportant: Bool = false, contentWarnings: [String] = []) {
        self.id = id; self.providerID = providerID.isEmpty ? id.uuidString : providerID; self.accountID = accountID
        self.threadID = threadID; self.from = from; self.to = to; self.subject = subject; self.body = body
        self.date = date; self.folder = folder; self.isRead = isRead; self.isFlagged = isFlagged
        self.categoryID = categoryID; self.attachments = attachments
        self.providerThreadID = providerThreadID; self.providerFolderIDs = providerFolderIDs; self.htmlBody = htmlBody; self.cc = cc
        self.isImportant = isImportant
        self.contentWarnings = contentWarnings
    }
    private enum CodingKeys: String, CodingKey { case id, providerID, accountID, threadID, from, to, subject, body, date, folder, isRead, isFlagged, categoryID, attachments, providerThreadID, providerFolderIDs, htmlBody, cc, isImportant, contentWarnings }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); providerID = try values.decode(String.self, forKey: .providerID)
        accountID = try values.decode(UUID.self, forKey: .accountID); threadID = try values.decode(UUID.self, forKey: .threadID)
        from = try values.decode(MailAddress.self, forKey: .from); to = try values.decode([MailAddress].self, forKey: .to)
        subject = try values.decode(String.self, forKey: .subject); body = try values.decode(String.self, forKey: .body)
        date = try values.decode(Date.self, forKey: .date); folder = try values.decode(MailFolder.self, forKey: .folder)
        isRead = try values.decode(Bool.self, forKey: .isRead); isFlagged = try values.decode(Bool.self, forKey: .isFlagged)
        categoryID = try values.decodeIfPresent(UUID.self, forKey: .categoryID); attachments = try values.decode([MailAttachment].self, forKey: .attachments)
        providerThreadID = try values.decodeIfPresent(String.self, forKey: .providerThreadID)
        providerFolderIDs = try values.decodeIfPresent([String].self, forKey: .providerFolderIDs) ?? []
        htmlBody = try values.decodeIfPresent(String.self, forKey: .htmlBody); cc = try values.decodeIfPresent([MailAddress].self, forKey: .cc) ?? []
        isImportant = try values.decodeIfPresent(Bool.self, forKey: .isImportant) ?? false
        contentWarnings = try values.decodeIfPresent([String].self, forKey: .contentWarnings) ?? []
    }
    public var preview: String { body.replacingOccurrences(of: "\n", with: " ") }
}

public struct MailThread: Identifiable, Sendable {
    public var id: UUID
    public var messages: [MailMessage]
    public init(id: UUID, messages: [MailMessage]) { self.id = id; self.messages = messages }
}

public struct MailCategory: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var color: String
    public init(id: UUID = UUID(), name: String, color: String = "sage") { self.id = id; self.name = name; self.color = color }
}

public struct ExtractedFact: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var sourceMessageID: UUID
    public var sourceQuote: String
    public init(id: UUID = UUID(), text: String, sourceMessageID: UUID, sourceQuote: String) {
        self.id = id; self.text = text; self.sourceMessageID = sourceMessageID; self.sourceQuote = sourceQuote
    }
}

public struct MessageSummary: Codable, Equatable, Sendable {
    public var messageID: UUID
    public var headline: String
    public var facts: [ExtractedFact]
    public var generatedAt: Date
    public var provider: String
    public init(messageID: UUID, headline: String, facts: [ExtractedFact], generatedAt: Date = Date(), provider: String = "Mock AI") {
        self.messageID = messageID; self.headline = headline; self.facts = facts; self.generatedAt = generatedAt; self.provider = provider
    }
}

public struct ClassificationSuggestion: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var messageID: UUID
    public var categoryID: UUID
    public var explanation: String
    public var confidence: Double
    public init(id: UUID = UUID(), messageID: UUID, categoryID: UUID, explanation: String, confidence: Double = 0.85) {
        self.id = id; self.messageID = messageID; self.categoryID = categoryID; self.explanation = explanation; self.confidence = confidence
    }
}

public struct ActionItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var messageID: UUID
    public var title: String
    public var sourceQuote: String
    public init(id: UUID = UUID(), messageID: UUID, title: String, sourceQuote: String) { self.id = id; self.messageID = messageID; self.title = title; self.sourceQuote = sourceQuote }
}

public struct SuggestedReply: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public init(id: UUID = UUID(), text: String) { self.id = id; self.text = text }
}

public struct Draft: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var to: String
    public var subject: String
    public var body: String
    public var replyToMessageID: UUID?
    public var updatedAt: Date
    public var accountID: UUID?
    public init(id: UUID = UUID(), to: String = "", subject: String = "", body: String = "", replyToMessageID: UUID? = nil, updatedAt: Date = Date(), accountID: UUID? = nil) {
        self.id = id; self.to = to; self.subject = subject; self.body = body; self.replyToMessageID = replyToMessageID; self.updatedAt = updatedAt
        self.accountID = accountID
    }
}

public enum WritingTool: String, CaseIterable, Identifiable, Sendable {
    case proofread = "Proofread", professional = "Professional", friendly = "Friendly", concise = "Concise", rewrite = "Rewrite"
    public var id: String { rawValue }
}

public enum ActionRisk: String, Codable, Sendable { case informational, reversible, externalEffect, destructive }
public enum ActionOrigin: String, Codable, Sendable { case user, ai, automation }
public enum ActionType: Codable, Equatable, Sendable {
    case archive(messageIDs: [UUID])
    case move(messageIDs: [UUID], folder: MailFolder)
    case markRead(messageIDs: [UUID], isRead: Bool)
    case flag(messageIDs: [UUID], isFlagged: Bool)
    case classify(messageID: UUID, categoryID: UUID?)
    case createCategory(MailCategory)
    case renameCategory(id: UUID, name: String)
    case deleteCategory(id: UUID)
    case saveDraft(Draft)
    case deleteDraft(id: UUID)
    case sendDraft(id: UUID)
}

public struct ProposedAction: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var type: ActionType
    public var explanation: String
    public var origin: ActionOrigin
    public init(id: UUID = UUID(), type: ActionType, explanation: String, origin: ActionOrigin = .user) {
        self.id = id; self.type = type; self.explanation = explanation; self.origin = origin
    }
    public var risk: ActionRisk {
        switch type { case .sendDraft: .externalEffect; default: .reversible }
    }
    public var requiresConfirmation: Bool { origin != .user || risk == .externalEffect || risk == .destructive }
}

public struct AutomationRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var senderEmail: String
    public var olderThanDays: Int
    public var enabled: Bool
    public var authorizedAt: Date?
    public init(id: UUID = UUID(), name: String, senderEmail: String, olderThanDays: Int, enabled: Bool = false, authorizedAt: Date? = nil) {
        self.id = id; self.name = name; self.senderEmail = senderEmail; self.olderThanDays = olderThanDays; self.enabled = enabled; self.authorizedAt = authorizedAt
    }
}

public struct ExecutedAction: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var proposal: ProposedAction
    public var date: Date
    public var undone: Bool
    public var canUndo: Bool
    public init(id: UUID = UUID(), proposal: ProposedAction, date: Date = Date(), undone: Bool = false, canUndo: Bool = true) {
        self.id = id; self.proposal = proposal; self.date = date; self.undone = undone; self.canUndo = canUndo
    }
}

public enum AIMode: String, Codable, CaseIterable, Sendable { case mock = "Demo AI", local = "Local AI", off = "Off" }
public struct UserPreferences: Codable, Equatable, Sendable {
    public var aiMode: AIMode
    public var localAI: AIModelConfiguration
    public var showDemoAccounts: Bool
    public var mailSyncSettings: MailSyncSettings
    public init(aiMode: AIMode = .mock, localAI: AIModelConfiguration = AIModelConfiguration(), showDemoAccounts: Bool = true, mailSyncSettings: MailSyncSettings = MailSyncSettings()) {
        self.aiMode = aiMode; self.localAI = localAI
        self.showDemoAccounts = showDemoAccounts
        self.mailSyncSettings = mailSyncSettings
    }
    private enum CodingKeys: String, CodingKey { case aiMode, localAI, showDemoAccounts, mailSyncSettings }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        aiMode = try values.decode(AIMode.self, forKey: .aiMode)
        localAI = try values.decodeIfPresent(AIModelConfiguration.self, forKey: .localAI) ?? AIModelConfiguration()
        showDemoAccounts = try values.decodeIfPresent(Bool.self, forKey: .showDemoAccounts) ?? true
        mailSyncSettings = try values.decodeIfPresent(MailSyncSettings.self, forKey: .mailSyncSettings) ?? MailSyncSettings()
    }
}

public struct AppSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var accounts: [MailAccount]
    public var remoteFolders: [MailFolderDescriptor]
    public var messages: [MailMessage]
    public var categories: [MailCategory]
    public var drafts: [Draft]
    public var summaries: [MessageSummary]
    public var classifications: [ClassificationSuggestion]
    public var rules: [AutomationRule]
    public var history: [ExecutedAction]
    public var preferences: UserPreferences
    public init(accounts: [MailAccount] = [], messages: [MailMessage] = [], categories: [MailCategory] = [], drafts: [Draft] = [], summaries: [MessageSummary] = [], classifications: [ClassificationSuggestion] = [], rules: [AutomationRule] = [], history: [ExecutedAction] = [], preferences: UserPreferences = UserPreferences(), remoteFolders: [MailFolderDescriptor] = []) {
        schemaVersion = 1; self.accounts = accounts; self.messages = messages; self.categories = categories; self.drafts = drafts
        self.summaries = summaries; self.classifications = classifications; self.rules = rules; self.history = history; self.preferences = preferences
        self.remoteFolders = remoteFolders
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, accounts, messages, categories, drafts, summaries, classifications, rules, history, preferences, remoteFolders }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        accounts = try values.decode([MailAccount].self, forKey: .accounts); messages = try values.decode([MailMessage].self, forKey: .messages)
        categories = try values.decode([MailCategory].self, forKey: .categories); drafts = try values.decode([Draft].self, forKey: .drafts)
        summaries = try values.decode([MessageSummary].self, forKey: .summaries); classifications = try values.decode([ClassificationSuggestion].self, forKey: .classifications)
        rules = try values.decode([AutomationRule].self, forKey: .rules); history = try values.decode([ExecutedAction].self, forKey: .history)
        preferences = try values.decode(UserPreferences.self, forKey: .preferences)
        remoteFolders = try values.decodeIfPresent([MailFolderDescriptor].self, forKey: .remoteFolders) ?? []
    }
}
