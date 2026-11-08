import Foundation
import Observation

/**
 * Giving a task, a conversation or an event to a Grok bot, from this iPhone
 * only. The flow (tools/grok-jobs/README.md has the exact API):
 *
 * 1. Send, tapped in `GrokDelegateView` after the full context was shown,
 *    registers the job with the user's own job service (`POST /jobs`, the app's
 *    bearer). It answers with the job's id and a callback token made for this
 *    job alone, which it keeps only as a hash.
 * 2. The app posts the webhook payload (job id, type, instruction, context,
 *    callback URL and token) to the bot's webhook, with the sender header the
 *    user set. The routine's own authentication contract isn't known yet, so
 *    the header's name and value are both the user's to set.
 * 3. The bot reports running, done or error to the callback; the app polls
 *    `GET /jobs/:id` while a card for the job is on screen.
 *
 * What comes back is text from outside, shown as plain text and never acted
 * on. Nothing here syncs: the settings are in the Keychain (this device only),
 * the jobs in a file per account, like the tasks.
 */
nonisolated struct GrokConfig: Codable, Equatable, Sendable {
    var webhookURL: String
    /** The header the webhook authenticates the sender by, as the routine will say; `Authorization` until then. */
    var senderHeader: String = "Authorization"
    var senderKey: String
    /** The job service (tools/grok-jobs) the app registers each job with. */
    var backendURL: String
    /** The app's bearer for the job service (its `GROK_JOBS_APP_TOKEN`). */
    var appToken: String

    static let keychainKey = "grok-delegation"

    static func load() -> GrokConfig? {
        guard let text = Keychain.get(keychainKey), let config = try? JSONDecoder().decode(GrokConfig.self, from: Data(text.utf8)) else {
            return nil
        }
        return config.problem == nil ? config : nil
    }

    @discardableResult
    func save() -> Bool {
        guard problem == nil, let data = try? JSONEncoder().encode(self) else { return false }
        return Keychain.set(Self.keychainKey, String(decoding: data, as: UTF8.self), thisDeviceOnly: true)
    }

    static func remove() { Keychain.set(keychainKey, nil) }

    /** Why these settings can't be used, in the words Settings shows; nil when they can. */
    var problem: String? {
        if Self.webhook(webhookURL) == nil { return "The webhook URL must be an https address." }
        if Self.backend(backendURL) == nil {
            return "The job service must be an https address, or http on this device's own network (127.0.0.1, localhost, .local)."
        }
        if !Self.isHeaderName(senderHeader) { return "The sender header is a header name, such as Authorization." }
        if senderKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the sender key." }
        if appToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the job service's app token." }
        if senderKey.contains(where: \.isNewline) || appToken.contains(where: \.isNewline) { return "A key can't span lines." }
        return nil
    }

    /** https, or http on the device's own loopback for the localhost mock bot. */
    static func webhook(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host(), !host.isEmpty else {
            return nil
        }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http": return isLoopback(host) ? url : nil
        default: return nil
        }
    }

    static func backend(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host(), !host.isEmpty,
              url.query() == nil, url.fragment() == nil else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http": return isLoopback(host) || host.lowercased().hasSuffix(".local") ? url : nil
        default: return nil
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    /** RFC 9110's token: what a header's name may be made of. */
    static func isHeaderName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /**
     * What Settings and the preview say of an address: its scheme, host and
     * port, never what's in the user part, the path or the query, where a
     * webhook's credential often is.
     */
    static func display(_ text: String) -> String {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host() else { return "—" }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme?.lowercased() ?? "https")://\(host)\(port)"
    }
}

/** What's given to Grok: a task, a conversation (in the mailbox it's shown in), or an event. */
nonisolated enum GrokSource: Identifiable, Hashable {
    case task(MailTask)
    case thread(MailThread, mailbox: String)
    case event(CalendarEvent)

    var id: String { key }

    /** The job service's `sourceKey`, which the cards find their jobs by. */
    var key: String {
        switch self {
        case .task(let task): "task:\(task.id.uuidString.lowercased())"
        case .thread(let thread, let mailbox): "mail:\(mailbox.lowercased())|\(thread.id)"
        case .event(let event): "event:\(TaskEvent(event, scope: .occurrence).key)"
        }
    }

    var type: String {
        switch self {
        case .task: "task"
        case .thread: "mail"
        case .event: "event"
        }
    }

    var title: String {
        switch self {
        case .task(let task): task.content
        case .thread(let thread, _): thread.subject.isEmpty ? "(no subject)" : thread.subject
        case .event(let event): event.title
        }
    }
}

/**
 * The context sent with an instruction, in full, which `GrokDelegateView`
 * shows before Send: what the user sees is what's encoded. Long mail is cut to
 * fit the job service's limit (`limit`), and says so.
 */
nonisolated struct GrokContext: Codable, Equatable, Sendable {
    struct TaskPart: Codable, Equatable, Sendable {
        struct Email: Codable, Equatable, Sendable {
            var mailbox: String
            var thread: String
            var subject: String
        }

        struct Event: Codable, Equatable, Sendable {
            var provider: String
            var account: String
            var calendarId: String
            var eventId: String
            var seriesId: String?
            var scope: String
            var title: String
            var start: Date
            var end: Date?
            var allDay: Bool
        }

        var content: String
        var notes: String
        var due: Date?
        var hasTime: Bool
        var done: Bool
        var list: String
        var emails: [Email]
        var events: [Event]
    }

    struct Mail: Codable, Equatable, Sendable {
        struct Message: Codable, Equatable, Sendable {
            var from: String
            var to: [String]
            var cc: [String]
            var date: Date
            var text: String
            var truncated: Bool
        }

        var mailbox: String
        var thread: String
        var subject: String
        var messages: [Message]
        /** The earliest messages left out to stay under the limit. */
        var omittedMessages: Int
    }

    struct Event: Codable, Equatable, Sendable {
        struct Guest: Codable, Equatable, Sendable {
            var email: String
            var name: String?
            var response: String
        }

        var provider: String
        var account: String
        var calendarId: String
        var calendar: String
        var eventId: String
        var seriesId: String?
        var originalStart: Date?
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var timeZone: String?
        var status: String
        var location: String?
        var description: String?
        var organizer: String?
        var guests: [Guest]
        var meetingLink: String?
    }

    var task: TaskPart?
    var mail: Mail?
    var event: Event?

    /** Under the job service's 128 KB for a context, with room for the rest of the request. */
    static let limit = 120_000
    static let messageLimit = 20_000
    static let instructionLimit = 4000

    static func of(_ source: GrokSource, lists: [TaskProject] = []) -> GrokContext {
        switch source {
        case .task(let task):
            return GrokContext(task: TaskPart(
                content: task.content, notes: task.notes, due: task.due, hasTime: task.hasTime, done: task.done,
                list: lists.first { $0.id == (task.projectId ?? TaskProject.inbox.id) }?.name ?? TaskProject.inbox.name,
                emails: task.emails.map { TaskPart.Email(mailbox: $0.mailbox, thread: $0.thread, subject: $0.subject) },
                events: task.events.map {
                    TaskPart.Event(
                        provider: $0.provider, account: $0.account, calendarId: $0.calendarId, eventId: $0.eventId,
                        seriesId: $0.seriesId, scope: $0.scope.rawValue, title: $0.title, start: $0.start, end: $0.end,
                        allDay: $0.allDay
                    )
                }
            ))
        case .thread(let thread, let mailbox):
            let label = { (person: Person) in person.name.isEmpty ? person.email : "\(person.name) <\(person.email)>" }
            var messages = thread.sent.map { message in
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return Mail.Message(
                    from: label(message.from), to: message.to.map(label), cc: message.cc.map(label), date: message.date,
                    text: String(text.prefix(messageLimit)), truncated: text.count > messageLimit
                )
            }
            var mail = Mail(mailbox: mailbox, thread: thread.id, subject: thread.subject, messages: messages, omittedMessages: 0)
            // The newest are kept: the oldest go first until it fits.
            while messages.count > 1, (try? encoded(GrokContext(mail: mail)).count) ?? 0 > limit {
                messages.removeFirst()
                mail.messages = messages
                mail.omittedMessages += 1
            }
            return GrokContext(mail: mail)
        case .event(let event):
            let details = event.details.map(EventDescription.plain).flatMap { $0.isEmpty ? nil : String($0.prefix(messageLimit)) }
            return GrokContext(event: Event(
                provider: "google", account: event.calendar.account.lowercased(), calendarId: event.calendar.id,
                calendar: event.calendar.name, eventId: event.eventId, seriesId: event.seriesId, originalStart: event.originalStart,
                title: event.title, start: event.start, end: event.end, allDay: event.allDay, timeZone: event.timeZone,
                status: event.status.rawValue, location: event.location, description: details,
                organizer: event.organizer?.email,
                guests: event.attendees.filter { !$0.room }.map {
                    Event.Guest(email: $0.person.email, name: $0.person.name.isEmpty ? nil : $0.person.name, response: $0.response.rawValue)
                },
                meetingLink: event.meetingLink
            ))
        }
    }

    /** One encoding for the preview and the request, so what's shown is what's sent. */
    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func encoded(_ context: GrokContext) throws -> Data { try encoder().encode(context) }

    func preview() -> String {
        (try? Self.encoder(pretty: true).encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/** What the job service is asked to register (`POST /jobs`). */
nonisolated struct GrokRegistration: Codable, Equatable, Sendable {
    var idempotencyKey: String
    var type: String
    var sourceKey: String
    var instruction: String
    var context: GrokContext
}

/** The service's answer: the job, and its callback only the first time (a replay of the same key has none). */
nonisolated struct GrokRegistered: Codable, Equatable, Sendable {
    struct Callback: Codable, Equatable, Sendable {
        var url: String
        var token: String
    }

    var job: GrokRemoteJob
    var callback: Callback?
    var replayed: Bool?
}

/** A job as the service tells it (`GET /jobs/:id`): never a token. */
nonisolated struct GrokRemoteJob: Codable, Equatable, Sendable {
    var id: String
    var status: String
    var result: String?
    var error: String?
}

/** What the webhook receives. */
nonisolated struct GrokWebhookPayload: Codable, Equatable, Sendable {
    struct Callback: Codable, Equatable, Sendable {
        var url: String
        var token: String
        var statuses = ["running", "done", "error"]
    }

    var version = 1
    var jobId: String
    var type: String
    var instruction: String
    var context: GrokContext
    var callback: Callback
}

/** A delegation as this iPhone keeps it. No secrets: a callback token waits in the Keychain until the webhook has it. */
nonisolated struct GrokJob: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case sending, sent, running, done, error

        /** How far along it is: a status the service reports never takes a job back. */
        var rank: Int {
            switch self {
            case .sending: 0
            case .sent: 1
            case .running: 2
            case .done, .error: 3
            }
        }

        var isFinished: Bool { self == .done || self == .error }

        init?(remote: String) {
            switch remote {
            case "registered": self = .sent
            case "running": self = .running
            case "done": self = .done
            case "error": self = .error
            default: return nil
            }
        }
    }

    /** Made when the sheet opens: the idempotency key, so a second tap or a retry is the same job. */
    var id: UUID
    var sourceKey: String
    var type: String
    var title: String
    var instruction: String
    var created: Date
    var updated: Date
    var status: Status = .sending
    /** The service's id, once it has registered the job. */
    var jobId: String? = nil
    /** The webhook has accepted it. */
    var delivered = false
    /** Why sending stopped, ours to retry; the context waits for it, and goes once delivered. */
    var problem: String? = nil
    var context: GrokContext? = nil
    /** The bot's answer, text from outside: shown as plain text, never acted on. */
    var result: String? = nil
    /** The bot's own report of what went wrong. */
    var botError: String? = nil

    /** What the service says, applied without going back: a finished job stays as it finished. */
    func advanced(by remote: GrokRemoteJob, now: Date = .now) -> GrokJob {
        guard let next = Status(remote: remote.status), !status.isFinished, next.rank >= status.rank, delivered else { return self }
        var job = self
        job.status = next
        job.updated = now
        if next == .done { job.result = remote.result.map { String($0.prefix(GrokJobs.resultLimit)) } }
        if next == .error { job.botError = remote.error.map { String($0.prefix(2000)) } ?? "The bot reported an error." }
        return job
    }

    var isPending: Bool { delivered && (status == .sent || status == .running) }

    /** The service's ids are path-safe: letters, digits, `-` and `_`. */
    static func isJobId(_ id: String) -> Bool {
        (1...100).contains(id.count) && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }
    var canRetry: Bool { problem != nil && !delivered }
}

/** The way out to the job service and the webhook: the live one, or the demo's stand-in, which reaches nothing. */
nonisolated protocol GrokTransport: Sendable {
    func register(_ registration: GrokRegistration) async throws -> GrokRegistered
    func deliver(_ payload: GrokWebhookPayload) async throws
    func status(_ jobId: String) async throws -> GrokRemoteJob
}

nonisolated struct GrokFailure: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/**
 * The live transport: an ephemeral session (no cookies, no cache), the app's
 * bearer only to the job service, the sender header only to the webhook, and
 * neither ever in a message: a failure says which step and the HTTP status,
 * never what came back.
 */
nonisolated struct LiveGrokTransport: GrokTransport {
    let config: GrokConfig

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func register(_ registration: GrokRegistration) async throws -> GrokRegistered {
        guard let base = GrokConfig.backend(config.backendURL) else { throw GrokFailure(message: "The job service's address isn't valid.") }
        var request = URLRequest(url: base.appending(path: "jobs"))
        request.httpMethod = "POST"
        request.httpBody = try GrokContext.encoder().encode(registration)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.appToken)", forHTTPHeaderField: "Authorization")
        let data = try await send(request, step: "The job service")
        do { return try JSONDecoder().decode(GrokRegistered.self, from: data) } catch {
            throw GrokFailure(message: "The job service answered with something Otter Mail couldn't read.")
        }
    }

    func deliver(_ payload: GrokWebhookPayload) async throws {
        guard let url = GrokConfig.webhook(config.webhookURL) else { throw GrokFailure(message: "The webhook URL isn't valid.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try GrokContext.encoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(payload.jobId, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(config.senderKey, forHTTPHeaderField: config.senderHeader)
        _ = try await send(request, step: "The webhook")
    }

    func status(_ jobId: String) async throws -> GrokRemoteJob {
        guard let base = GrokConfig.backend(config.backendURL) else { throw GrokFailure(message: "The job service's address isn't valid.") }
        var request = URLRequest(url: base.appending(path: "jobs").appending(path: jobId))
        request.setValue("Bearer \(config.appToken)", forHTTPHeaderField: "Authorization")
        let data = try await send(request, step: "The job service")
        do { return try JSONDecoder().decode(GrokRemoteJob.self, from: data) } catch {
            throw GrokFailure(message: "The job service answered with something Otter Mail couldn't read.")
        }
    }

    private func send(_ request: URLRequest, step: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw GrokFailure(message: "\(step) couldn't be reached.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let why = status == 401 || status == 403 ? " Check its key in Settings." : ""
            throw GrokFailure(message: "\(step) answered \(status).\(why)")
        }
        return data
    }
}

/**
 * The demo's stand-in for the job service and the bot: nothing leaves the
 * phone. A job runs a moment after it's sent and finishes with a made-up answer.
 */
actor DemoGrokTransport: GrokTransport {
    private var jobs: [String: (key: String, registered: Date, instruction: String)] = [:]
    private let pace: TimeInterval

    init(pace: TimeInterval = 1.5) { self.pace = pace }

    func register(_ registration: GrokRegistration) async throws -> GrokRegistered {
        if let known = jobs.first(where: { $0.value.key == registration.idempotencyKey }) {
            return GrokRegistered(job: GrokRemoteJob(id: known.key, status: "registered"), callback: nil, replayed: true)
        }
        let id = "demo-\(UUID().uuidString.lowercased())"
        jobs[id] = (registration.idempotencyKey, .now, registration.instruction)
        return GrokRegistered(
            job: GrokRemoteJob(id: id, status: "registered"),
            callback: .init(url: "http://127.0.0.1:8789/jobs/\(id)/result", token: "demo-token"),
            replayed: false
        )
    }

    func deliver(_ payload: GrokWebhookPayload) async throws {}

    func status(_ jobId: String) async throws -> GrokRemoteJob {
        guard let job = jobs[jobId] else { throw GrokFailure(message: "The demo has no such job.") }
        let elapsed = Date.now.timeIntervalSince(job.registered)
        if elapsed < pace { return GrokRemoteJob(id: jobId, status: "registered") }
        if elapsed < pace * 2 { return GrokRemoteJob(id: jobId, status: "running") }
        return GrokRemoteJob(
            id: jobId, status: "done",
            result: "Demo answer for “\(job.instruction.prefix(80))”. In the real app this is the bot's reply, shown as text. Nothing was sent anywhere."
        )
    }
}

/** The jobs on disk: a file a scope, beside the tasks', written atomically. */
nonisolated final class GrokJobFiles: Sendable {
    static let live = GrokJobFiles(folder: URL.applicationSupportDirectory.appending(path: "grok", directoryHint: .isDirectory))

    private let folder: URL
    private let queue = DispatchQueue(label: "app.otter.mail.grok", qos: .utility)

    init(folder: URL) { self.folder = folder }

    private func file(_ scope: String) -> URL { folder.appending(path: "\(scope).json") }

    func load(_ scope: String) -> [GrokJob] {
        queue.sync {
            guard let data = try? Data(contentsOf: file(scope)),
                  let jobs = try? JSONDecoder().decode([Lossy<GrokJob>].self, from: data) else { return [] }
            return jobs.compactMap(\.value)
        }
    }

    func save(_ jobs: [GrokJob], scope: String) {
        let folder = folder
        let file = file(scope)
        queue.async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONEncoder().encode(jobs).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                ErrorReports.capture(error, scope: "grok")
            }
        }
    }
}

/**
 * The delegations made on this iPhone, for the cards on the task, conversation
 * or event each came from. Sending is one job per sheet (`GrokJob.id`, the
 * idempotency key): tapping again, or Retry, carries on where it stopped,
 * never a second job. Polling is for the cards on screen, and stops.
 */
@Observable
final class GrokJobs {
    /** The bot's answer is cut here, as the job service cuts it. */
    nonisolated static let resultLimit = 32_000
    /** A card asks this many times a visit, then waits for Check again. */
    static let pollLimit = 90

    private(set) var jobs: [GrokJob] = []
    /** Settings has a complete setup (the demo has its stand-in). */
    private(set) var isConfigured = false
    private(set) var scope: String?
    private(set) var demo = false

    @ObservationIgnored private let files: GrokJobFiles
    @ObservationIgnored private var demoTransport = DemoGrokTransport()
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private let transportOverride: (any GrokTransport)?

    init(files: GrokJobFiles = .live, transport: (any GrokTransport)? = nil) {
        self.files = files
        transportOverride = transport
    }

    var isAvailable: Bool { scope != nil && (demo || isConfigured) }

    func open(_ scope: String, demo: Bool) {
        self.scope = scope
        self.demo = demo
        jobs = files.load(scope)
        reloadConfig()
    }

    func close() {
        scope = nil
        jobs = []
        inFlight = []
    }

    func reloadConfig() {
        isConfigured = GrokConfig.load() != nil
    }

    private var transport: (any GrokTransport)? {
        if let transportOverride { return transportOverride }
        if demo { return demoTransport }
        return GrokConfig.load().map(LiveGrokTransport.init(config:))
    }

    func jobs(for sourceKey: String) -> [GrokJob] {
        jobs.filter { $0.sourceKey == sourceKey }.sorted { $0.created > $1.created }
    }

    func hasJobs(for sourceKey: String) -> Bool { jobs.contains { $0.sourceKey == sourceKey } }

    func job(_ id: UUID) -> GrokJob? { jobs.first { $0.id == id } }

    /**
     * Send, from the sheet: the job is kept first (as sending), then registered
     * and delivered. Called again with the same id it doesn't start over: a job
     * already on its way is left alone, one that stopped carries on.
     */
    func send(id: UUID, source: GrokSource, instruction: String, context: GrokContext) async {
        let instruction = String(instruction.trimmingCharacters(in: .whitespacesAndNewlines).prefix(GrokContext.instructionLimit))
        guard scope != nil, !instruction.isEmpty else { return }
        if job(id) == nil {
            let now = Date.now
            put(GrokJob(
                id: id, sourceKey: source.key, type: source.type, title: source.title, instruction: instruction,
                created: now, updated: now, context: context
            ))
        }
        await resume(id)
    }

    func retry(_ job: GrokJob) async {
        guard job.canRetry else { return }
        await resume(job.id)
    }

    /** Takes a job away from this iPhone (and its waiting token); what the service and the bot have stays with them. */
    func delete(_ job: GrokJob) {
        jobs.removeAll { $0.id == job.id }
        Keychain.set(Self.tokenKey(job.id), nil)
        persist()
    }

    nonisolated static func tokenKey(_ id: UUID) -> String { "grok-callback:\(id.uuidString.lowercased())" }

    private func resume(_ id: UUID) async {
        guard !inFlight.contains(id), var job = job(id), !job.delivered, let transport else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        job.problem = nil
        put(job)
        guard let context = job.context else {
            fail(id, "This job's context is no longer on this iPhone. Delete it and give it to Grok again.")
            return
        }
        do {
            if job.jobId == nil {
                let registered = try await transport.register(GrokRegistration(
                    idempotencyKey: id.uuidString.lowercased(), type: job.type, sourceKey: job.sourceKey,
                    instruction: job.instruction, context: context
                ))
                if let callback = registered.callback {
                    Keychain.set(Self.tokenKey(id), "\(callback.url)\n\(callback.token)", thisDeviceOnly: true)
                }
                guard GrokJob.isJobId(registered.job.id) else {
                    throw GrokFailure(message: "The job service answered with an id Otter Mail doesn't accept.")
                }
                guard var current = self.job(id) else { return }
                current.jobId = registered.job.id
                put(current)
                job = current
            }
            guard let jobId = job.jobId else { return }
            guard let kept = Keychain.get(Self.tokenKey(id)), let newline = kept.firstIndex(of: "\n") else {
                fail(id, "The job service has this job, but its callback token isn't on this iPhone any more. Delete it and give it to Grok again.")
                return
            }
            let callback = GrokWebhookPayload.Callback(url: String(kept[..<newline]), token: String(kept[kept.index(after: newline)...]))
            try await transport.deliver(GrokWebhookPayload(
                jobId: jobId, type: job.type, instruction: job.instruction, context: context, callback: callback
            ))
            Keychain.set(Self.tokenKey(id), nil)
            guard var current = self.job(id) else { return }
            current.delivered = true
            current.status = .sent
            current.context = nil
            current.updated = .now
            put(current)
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    /**
     * Asks after the pending jobs of one card while it's on screen: every few
     * seconds, at most `pollLimit` times, until they finish. Errors leave the
     * job as it was; the card offers Check again.
     */
    func poll(_ sourceKey: String) async {
        let pause: Duration = demo ? .milliseconds(700) : .seconds(4)
        for _ in 0..<Self.pollLimit {
            let pending = jobs(for: sourceKey).filter(\.isPending)
            guard !pending.isEmpty, let transport else { return }
            for job in pending {
                await check(job, with: transport)
            }
            do { try await Task.sleep(for: pause) } catch { return }
        }
    }

    func check(_ job: GrokJob) async {
        guard let transport else { return }
        await check(job, with: transport)
    }

    private func check(_ job: GrokJob, with transport: any GrokTransport) async {
        guard let jobId = job.jobId, let remote = try? await transport.status(jobId), remote.id == jobId,
              let current = self.job(job.id) else { return }
        let next = current.advanced(by: remote)
        if next != current { put(next) }
    }

    private func fail(_ id: UUID, _ problem: String) {
        guard var job = job(id) else { return }
        job.problem = problem
        job.updated = .now
        put(job)
    }

    private func put(_ job: GrokJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        persist()
    }

    private func persist() {
        guard let scope else { return }
        files.save(jobs, scope: scope)
    }
}
