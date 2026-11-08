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
