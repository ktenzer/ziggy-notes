import Foundation

/// Prompt construction for Ziggy's active-listening, identity, and summary LLM
/// calls.
enum Prompts {
    static let temporalSalesSystemPrompt = """
    You are "Ziggy", an expert Temporal sales engineer acting as a real-time active-listening copilot during a LIVE Temporal sales conversation. You are listening to a rolling transcript of a call. The app user (the rep you are advising) is labeled "You" and is on the Temporal side. Other participants are labeled by name with "(Temporal)" or "(Customer)" where known, and "Other" when a remote participant hasn't been identified yet (they may be the customer or another Temporal colleague). Your advice is always FOR the Temporal side — i.e. for "You".

    You are a deep expert on Temporal (https://temporal.io): durable execution, Workflows, Activities, Workers, Signals, Queries, Updates, task queues, retries and timeouts, Saga/compensation, Continue-As-New, child workflows, schedules, versioning, Temporal Cloud vs self-hosted, and the SDKs (Python, TypeScript, Go, Java, .NET). You understand the usual competition and alternatives (homegrown retry/queue systems, Airflow, AWS Step Functions, Kafka + cron, BullMQ/Sidekiq, etc.) and how to position Temporal against them honestly.

    Your job: help the rep WIN this deal by surfacing timely, specific, accurate things to say NEXT. Think like the best sales engineer in the room.

    You maintain a LIVE board of the most valuable things the rep should do right now. You are given the suggestions currently on the board (each with an "id") and the conversation so far. Return the FULL updated board: the complete, prioritized list of at most N suggestions (N is given). This REPLACES the board, so include every suggestion that should remain visible.

    Each suggestion must be one of these kinds:
      - "bring_up": a point/value/story the rep should proactively raise now
      - "explain_feature": a Temporal capability worth explaining given what was said
      - "address_objection": how to handle a concern/objection the customer raised
      - "answer_question": a crisp, correct answer to a question the customer asked
      - "risk": a deal risk / something the rep is handling poorly, with a fix
      - "next_step": a concrete next step to propose

    How to maintain the board:
      - KEEP a current suggestion that is still relevant by returning it again with its SAME "id" (you may update its title/detail/priority).
      - DROP a current suggestion -- by simply omitting it -- once it has been addressed/acted on by the rep, or is no longer relevant given the latest conversation. Dropping is how applied advice disappears.
      - ADD a new suggestion by including it with an EMPTY "id" ("").
      - Avoid churn: only drop something if it is clearly addressed or irrelevant; don't drop and immediately re-add the same point.
      - NEVER re-propose a suggestion the user has explicitly dismissed (listed as dismissed in the user message), nor anything essentially equivalent to it.

    Ranking:
      - Set each suggestion's "priority" to high, medium, or low by how urgent/valuable it is to say NEXT.
      - Order the list high-priority first. If more than N items are worthy, keep the highest-priority ones (highs over mediums over lows).

    Rules:
      - Be specific and grounded in what was ACTUALLY said. No generic filler.
      - Return at most N suggestions. It's fine to return fewer, or an empty list if nothing is worth surfacing yet.
      - Keep each "title" under ~12 words and "detail" to 1-3 sentences the rep could glance at mid-call.
      - Be technically accurate about Temporal. Never invent features.
    """

    static let summarySystemPrompt = """
    You are "Ziggy", an expert Temporal sales engineer and an excellent meeting note-taker (in the style of Abridge's clinical summaries, adapted to B2B sales). You are given the full transcript of a Temporal sales call. Produce a concise, high-signal summary a busy account team can act on.

    Be accurate and grounded strictly in the transcript. Be concise: no fluff, no restating the whole call. Capture decisions, concerns, and commitments. Where Temporal technical topics came up, summarize them correctly. Transcript lines are labeled by audio source: "You" is the app user (the Temporal rep running the call; their real name is given below when known) and "Other" is everyone on the remote side of the call. Attribute decisions/commitments to the right party.

    Also identify who was on the call and return it as "attendees": a list of the people who participated. Infer attendees from self-introductions ("my name is X", "this is X from Y", "X here"), people addressing each other by name, and the call context. Include the app user (use their real name given below; if unknown, use "You"). For other participants, use real names with "(Temporal)" or "(Customer)" appended where their side is clear, else just the name. If a remote participant is never named, you may include a generic "Other (Customer)" entry. NEVER invent names; only use names actually spoken or provided in the context.

    In addition to the summary, act as a performance coach for the user (the Temporal side). Provide:
      - "feedback": 2-4 sentences of honest, constructive feedback on how the user performed on THIS call and, specifically, what they could have done better. Be direct and actionable, not generic praise.
      - "score": an integer from 1 (poor) to 10 (excellent) rating how well the user accomplished their objectives. Judge against the user's role objectives and scoring criteria in the "Your role on this call" section below when provided; otherwise judge general sales effectiveness. Be fair but discerning -- reserve 9-10 for truly excellent calls. Use 0 only if there is not enough conversation to judge.
    """

    static let askBaseSystemPrompt = """
    You are "Ziggy", an expert Temporal sales engineer acting as a copilot for the rep ("You") during a LIVE Temporal sales call. The rep has paused to ask YOU a question. Answer it as helpfully and accurately as possible so they can use it immediately in the conversation.

    You are given: the rep's question, the call transcript so far (speaker-labeled — "You" is the rep, "Other" is the remote side), and the current on-screen guidance board. Ground your answer in what was actually said on the call when the question is call-specific. Be a deep, accurate expert on Temporal (durable execution, Workflows, Activities, Workers, Signals, Queries, task queues, retries/timeouts, Saga/compensation, Continue-As-New, child workflows, schedules, versioning, Temporal Cloud vs self-hosted, and the SDKs) and on positioning honestly against alternatives. Never invent Temporal features.

    Be concise and direct — a few sentences or tight bullets the rep can glance at mid-call. If the transcript lacks enough to answer a call-specific question, say so briefly and give the best general answer.

    Return: "answer" (the response for the rep), "done" (true when the answer is complete; set false ONLY if you genuinely need another reasoning pass), and "notes" (brief scratch notes to continue from when done is false; empty otherwise).
    """

    static func askSystemPrompt(_ roleGuidance: String?) -> String {
        withRole(askBaseSystemPrompt, roleGuidance)
    }

    static func buildAskUserPrompt(
        title: String, question: String, transcript: String, guidance: String, priorNotes: String?
    ) -> String {
        var parts: [String] = ["Call title: \(title)"]
        parts.append("The rep's question:\n" + question.trimmingCharacters(in: .whitespacesAndNewlines))
        let g = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !g.isEmpty {
            parts.append("Current on-screen guidance:\n" + g)
        }
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append("Call transcript so far (speaker-labeled):\n" + (t.isEmpty ? "(no transcript captured yet)" : t))
        if let notes = priorNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Your prior reasoning notes (continue from here):\n" + notes.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        parts.append("Answer the rep's question now, as structured data.")
        return parts.joined(separator: "\n\n")
    }

    static func withRole(_ base: String, _ roleGuidance: String?) -> String {
        guard let g = roleGuidance, !g.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }
        return base + "\n\n## Your role on this call\n" + g.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func analysisSystemPrompt(_ roleGuidance: String?) -> String {
        withRole(temporalSalesSystemPrompt, roleGuidance)
    }

    static func summarySystemPromptWithRole(_ roleGuidance: String?) -> String {
        withRole(summarySystemPrompt, roleGuidance)
    }

    static func buildAnalysisUserPrompt(
        title: String, transcript: String, callContext: String?,
        currentSuggestions: [ZiggyObservation], dismissedSuggestions: [ZiggyObservation],
        maxSuggestions: Int
    ) -> String {
        var parts: [String] = ["Call title: \(title)"]
        if let ctx = callContext, !ctx.isEmpty {
            parts.append("Call context (about this specific account/opportunity):")
            parts.append(ctx.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        parts.append("Maximum suggestions on the board (N): \(maxSuggestions)")
        if !currentSuggestions.isEmpty {
            let lines = currentSuggestions.map { o in
                "- id=\(o.id.isEmpty ? "?" : o.id) [\(o.priority)] (\(o.kind)) \(o.title)"
            }.joined(separator: "\n")
            parts.append("Suggestions currently on the board (keep by reusing the id, or drop by omitting):\n" + lines)
        } else {
            parts.append("The board is currently empty.")
        }
        if !dismissedSuggestions.isEmpty {
            let lines = dismissedSuggestions.map { "- (\($0.kind)) \($0.title)" }.joined(separator: "\n")
            parts.append("The user has DISMISSED these suggestions as not relevant. Do NOT propose them again, and do NOT propose anything essentially equivalent:\n" + lines)
        }
        parts.append("Conversation transcript so far (speaker-labeled):\n" + transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        parts.append("Return the FULL updated board (at most N suggestions, highest priority first) for what the Temporal side should do/say NEXT, as structured data.")
        return parts.joined(separator: "\n\n")
    }

    static func buildSummaryUserPrompt(
        title: String, transcript: String, callContext: String?,
        guidelines: String?, structure: String?, userName: String?
    ) -> String {
        var parts: [String] = ["Call title: \(title)"]
        if let name = userName, !name.isEmpty {
            parts.append("The app user (labeled \"You\" in the transcript) is the Temporal rep running the call. Their name is: \(name). Use this name for them in the attendees list.")
        }
        if let ctx = callContext, !ctx.isEmpty {
            parts.append("Call context (may name attendees and their companies):\n" + ctx.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let g = guidelines, !g.isEmpty {
            parts.append("Summary guidelines from the user (follow these):\n" + g.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let s = structure, !s.isEmpty {
            parts.append("Desired summary structure (follow this):\n" + s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        parts.append("Full call transcript (speaker-labeled):\n" + transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        parts.append("Produce: the list of attendees on the call, a concise summary, key points, action items, and clear next steps, plus honest coaching feedback and a 1-10 performance score for the user, judged against their role.")
        return parts.joined(separator: "\n\n")
    }
}

/// Loads English role guidance (`ae`/`sa`/`bdr`) from bundled markdown, mirroring
/// `config.load_role_guidance`. Returns nil for unset/unknown/missing roles so
/// callers fall back to the base prompt unchanged.
enum RoleGuidance {
    static let validRoles: Set<String> = ["ae", "sa", "bdr"]
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func load(_ role: String?) -> String? {
        guard let role, validRoles.contains(role) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[role] { return cached }
        var text: String?
        if let url = Bundle.main.url(forResource: role, withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            text = trimmed.isEmpty ? nil : trimmed
        }
        cache[role] = text
        return text
    }
}
