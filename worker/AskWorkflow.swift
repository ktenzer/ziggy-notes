import Foundation
import Temporal

/// One "ask anything" exchange for a meeting note, run as its own workflow so each
/// question is clearly visible in Temporal under `ziggy-ask-<meetingId>-<n>` (the
/// id ties every exchange back to its note).
///
/// Started via **signal-with-start**: the question plus a transcript + guidance
/// snapshot arrive through the `ask` signal. The workflow then runs a bounded
/// agent loop over the `answer_question` activity (letting the model iterate with
/// its own scratch notes until it is satisfied or the step cap is hit) and returns
/// the final answer. The app awaits that result before allowing the next question.
@Workflow(name: "AskMeetingWorkflow")
struct AskMeetingWorkflow {
    /// The pending question + context, delivered by the `ask` signal.
    var request: AskRequest?

    /// Receives the user's question and grounding context. Only the first signal is
    /// honored; this workflow handles exactly one question per execution.
    @WorkflowSignal(name: "ask")
    mutating func ask(input: AskRequest) {
        if request == nil { request = input }
    }

    mutating func run(context: WorkflowContext<Self>, input: AskInput) async throws -> AskResult {
        // Wait for the question (delivered atomically via signal-with-start).
        try await context.condition { $0.request != nil }
        guard let req = request else { return AskResult(answer: "") }

        let opts = ActivityOptions(
            startToCloseTimeout: .seconds(90),
            scheduleToCloseTimeout: .seconds(180),
            cancellationType: .tryCancel,
            retryPolicy: RetryPolicy(
                initialInterval: .seconds(1), backoffCoefficient: 2.0,
                maximumInterval: .seconds(10), maximumAttempts: 4
            )
        )

        // Bounded agent loop: keep reasoning (carrying scratch notes) until the
        // model marks the answer done or we reach the step cap.
        let maxSteps = 3
        var notes = ""
        var answer = ""
        for _ in 0..<maxSteps {
            let result = try await context.executeActivity(
                ZiggyActivities.Activities.AnswerQuestion.self,
                options: opts,
                input: AnswerInput(
                    title: input.title,
                    question: req.question,
                    transcript: req.transcript,
                    guidance: req.guidance,
                    priorNotes: notes.isEmpty ? nil : notes
                )
            )
            answer = result.answer
            if result.done { break }
            notes = result.notes
        }
        return AskResult(answer: answer)
    }
}
