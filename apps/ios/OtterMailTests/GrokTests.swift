import Foundation
import Testing
@testable import Otter_Mail

/** Give to Grok's pure parts: which settings are usable, what's shown of them, and how a job's status moves. */
struct GrokTests {
    private func config(webhook: String = "https://bot.example/hook/s3cret?key=k", backend: String = "https://jobs.example") -> GrokConfig {
        GrokConfig(webhookURL: webhook, senderKey: "Bearer key", backendURL: backend, appToken: "token")
    }

    private func job(_ status: GrokJob.Status, delivered: Bool = true) -> GrokJob {
        GrokJob(
            id: UUID(), sourceKey: "task:1", type: "task", title: "T", instruction: "Do it",
            created: .distantPast, updated: .distantPast, status: status, jobId: "j1", delivered: delivered
        )
    }

    @Test func takesHttpsOrTheLoopbackOnly() {
        #expect(config().problem == nil)
        #expect(config(webhook: "http://127.0.0.1:8790/").problem == nil)
        #expect(config(webhook: "http://bot.example/hook").problem != nil)
        #expect(config(backend: "http://my-mac.local:8789").problem == nil)
        #expect(config(backend: "https://jobs.example?x=1").problem != nil)
        var header = config()
        header.senderHeader = "X Bad"
        #expect(header.problem != nil)
    }

    @Test func showsOnlyTheHostOfAnAddress() {
        #expect(GrokConfig.display("https://user:pw@bot.example:8443/hook/s3cret?key=k") == "https://bot.example:8443")
        #expect(!GrokConfig.display(config().webhookURL).contains("s3cret"))
    }

    @Test func movesForwardOnlyAndKeepsAFinishedJob() {
        let running = job(.sent).advanced(by: GrokRemoteJob(id: "j1", status: "running"))
        #expect(running.status == .running)
        #expect(running.advanced(by: GrokRemoteJob(id: "j1", status: "registered")).status == .running)
        let done = running.advanced(by: GrokRemoteJob(id: "j1", status: "done", result: "Answer"))
        #expect(done.status == .done)
        #expect(done.result == "Answer")
        #expect(done.advanced(by: GrokRemoteJob(id: "j1", status: "error", error: "late")).status == .done)
        // Nothing moves before the webhook has the job.
        #expect(job(.sending, delivered: false).advanced(by: GrokRemoteJob(id: "j1", status: "done")).status == .sending)
    }

    @Test func offersRetryForAJobTheAppClosedOnWhileSending() {
        let folder = URL.temporaryDirectory.appending(path: "grok-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = GrokJobFiles(folder: folder)
        let sending = job(.sending, delivered: false)
        let sent = job(.sent)
        files.save([sending, sent], scope: "demo")

        let jobs = GrokJobs(files: files, transport: DemoGrokTransport())
        jobs.open("demo", demo: true)

        #expect(jobs.job(sending.id)?.canRetry == true)
        #expect(jobs.job(sending.id)?.status == .sending)
        #expect(jobs.job(sent.id) == sent)
        // Kept so, for the next time the app opens.
        #expect(files.load("demo").first { $0.id == sending.id }?.canRetry == true)
    }

    /** Closed before the service's first answer arrived: the replay has no token, so Retry registers under a key of its own and hands that on. */
    @Test func registersAgainWhenTheFirstAnswerNeverArrived() async {
        let folder = URL.temporaryDirectory.appending(path: "grok-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = GrokJobFiles(folder: folder)
        var sending = job(.sending, delivered: false)
        sending.jobId = nil
        sending.context = GrokContext.of(.task(MailTask(content: "Reply")))
        files.save([sending], scope: "demo")
        let service = LostAnswer(known: sending.id.uuidString.lowercased())

        let jobs = GrokJobs(files: files, transport: service)
        jobs.open("demo", demo: true)
        await jobs.retry(jobs.job(sending.id)!)

        let sent = jobs.job(sending.id)
        #expect(sent?.delivered == true)
        #expect(sent?.problem == nil)
        #expect(sent?.jobId == "new")
        #expect(await service.delivered == ["new"])
        #expect(await service.keys.count == 2)
        // The token stays until the job finishes, then goes.
        #expect(Keychain.get(GrokJobs.tokenKey(sending.id)) != nil)
        await jobs.check(sent!)
        #expect(jobs.job(sending.id)?.status == .done)
        #expect(Keychain.get(GrokJobs.tokenKey(sending.id)) == nil)
    }

    /** An earlier build dropped the token as the webhook took the job, then closed before it noted so: the job is fetched, not stuck. */
    @Test func fetchesAJobDeliveredJustBeforeTheAppClosed() async {
        let folder = URL.temporaryDirectory.appending(path: "grok-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = GrokJobFiles(folder: folder)
        var sending = job(.sending, delivered: false)
        sending.context = GrokContext.of(.task(MailTask(content: "Reply")))
        files.save([sending], scope: "demo")
        let service = LostAnswer(known: "")

        let jobs = GrokJobs(files: files, transport: service)
        jobs.open("demo", demo: true)
        await jobs.retry(jobs.job(sending.id)!)

        let fetched = jobs.job(sending.id)
        #expect(fetched?.delivered == true)
        #expect(fetched?.status == .done)
        #expect(fetched?.result == "Answer")
        #expect(await service.keys.isEmpty)
        #expect(await service.delivered.isEmpty)
    }

    /** Registered, its token gone and the service still saying registered: the bot may have it, so it's neither counted as delivered nor sent again. */
    @Test func neverSendsAgainAJobThatMayAlreadyBeWithTheBot() async {
        let folder = URL.temporaryDirectory.appending(path: "grok-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = GrokJobFiles(folder: folder)
        var sending = job(.sending, delivered: false)
        sending.context = GrokContext.of(.task(MailTask(content: "Reply")))
        files.save([sending], scope: "demo")
        let service = LostAnswer(known: "", reported: "registered")

        let jobs = GrokJobs(files: files, transport: service)
        jobs.open("demo", demo: true)
        await jobs.retry(jobs.job(sending.id)!)

        let waiting = jobs.job(sending.id)
        #expect(waiting?.delivered == false)
        #expect(waiting?.jobId == "j1")
        #expect(waiting?.canRetry == true)
        await jobs.retry(waiting!)
        #expect(await service.keys.isEmpty)
        #expect(await service.delivered.isEmpty)
    }

    /** A job given from the primary calendar before it was `primary` keeps its key, and is still found from the event. */
    @Test func findsAJobKeyedByThePrimaryCalendarsAddress() {
        let folder = URL.temporaryDirectory.appending(path: "grok-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = GrokJobFiles(folder: folder)
        var old = job(.sent)
        old.sourceKey = "event:google|robin@otter.example|Robin@otter.example|standup"
        var other = job(.sent)
        other.sourceKey = "event:google|robin@otter.example|team@group.calendar.google.com|standup"
        files.save([old, other], scope: "demo")

        let jobs = GrokJobs(files: files, transport: DemoGrokTransport())
        jobs.open("demo", demo: true)

        let calendar = EventCalendar(id: "primary", name: "Robin", primary: true, account: "robin@otter.example")
        let standup = CalendarEvent(eventId: "standup", calendar: calendar, title: "Standup", start: .now, end: .now.addingTimeInterval(900))
        let key = GrokSource.event(standup).key
        #expect(key == "event:google|robin@otter.example|primary|standup")
        #expect(jobs.jobs(for: key).map(\.id) == [old.id])
        #expect(jobs.hasJobs(for: key))
        #expect(jobs.job(old.id)?.sourceKey == old.sourceKey, "the job service knows it by the key it was given")
    }

    @Test func acceptsOnlyPathSafeJobIds() {
        #expect(GrokJob.isJobId("0b5c3f1e-4a2d-4c7e-9a10-6f1d2e3c4b5a"))
        #expect(!GrokJob.isJobId("../etc"))
        #expect(!GrokJob.isJobId(""))
    }

    @Test func sendsATasksLinksWithIt() {
        let task = MailTask(
            content: "Reply", email: TaskEmail(mailbox: "robin@otter.example", thread: "t1", subject: "Dinner?")
        )
        let context = GrokContext.of(.task(task))
        #expect(context.task?.content == "Reply")
        #expect(context.task?.emails.map(\.thread) == ["t1"])
        #expect(context.task?.list == "Inbox")
        #expect(context.preview().contains("\"thread\" : \"t1\""))
    }
}

/** A job service that already has `known` (its answer, and the token, lost on the way): that key replays without one. */
private actor LostAnswer: GrokTransport {
    let known: String
    /** What the service says of a job it has registered: `done`, or still `registered` if the webhook never had it. */
    let reported: String
    private(set) var keys: [String] = []
    private(set) var delivered: [String] = []

    init(known: String, reported: String = "done") {
        self.known = known
        self.reported = reported
    }

    func register(_ registration: GrokRegistration) async throws -> GrokRegistered {
        keys.append(registration.idempotencyKey)
        if registration.idempotencyKey == known {
            return GrokRegistered(job: GrokRemoteJob(id: "old", status: "registered"), callback: nil, replayed: true)
        }
        return GrokRegistered(
            job: GrokRemoteJob(id: "new", status: "registered"),
            callback: .init(url: "http://127.0.0.1:8789/jobs/new/result", token: "token"),
            replayed: false
        )
    }

    func deliver(_ payload: GrokWebhookPayload) async throws { delivered.append(payload.jobId) }

    func status(_ jobId: String) async throws -> GrokRemoteJob {
        reported == "done" ? GrokRemoteJob(id: jobId, status: "done", result: "Answer") : GrokRemoteJob(id: jobId, status: reported)
    }
}
