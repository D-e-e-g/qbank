#if DEBUG
import Foundation

/// Invented questions for the fake server, one in each of the eight formats, written for UI tests
/// and simulator review. None of it comes from a real course.
nonisolated enum FakePracticeQuestions {
    /// The eight question templates in practice order: single, priority (with a table), select all,
    /// highlight, ordering, matching, matrix, drop-down. A longer set repeats them.
    static var templates: [[String: Any]] {
        [single, priority, selectAll, highlight, ordering, matching, matrix, dropDown]
    }

    /// The one-question set the `matrix-multi` scenario puts in Weeks 1-3. It is not one of `templates`,
    /// so the mixed set stays the eight formats.
    static let findingsSetID = "findings-v1"

    /// The question at `index` of a set, with the id the set listing gives it.
    static func question(setID: String, index: Int) -> [String: Any] {
        var question = setID == findingsSetID ? matrixMulti : templates[index % templates.count]
        question["id"] = "\(setID)-q\(index)"
        question["publicId"] = "Q\(index + 1)"
        question["position"] = index + 1
        return question
    }

    /// The template behind a question id such as `mixed-v1-q3`.
    static func template(forQuestionID id: String) -> [String: Any]? {
        if id.hasPrefix("\(findingsSetID)-") { return matrixMulti }
        guard let suffix = id.split(separator: "-").last, suffix.hasPrefix("q"), let index = Int(suffix.dropFirst()) else { return nil }
        return templates[index % templates.count]
    }

    private static var single: [String: Any] { [
        "type": "single",
        "topic": "Refusing a medication",
        "cj": "Take action",
        "stem": "A voluntarily admitted adult client with major depression refuses the evening dose of an antidepressant, saying, “It makes me feel foggy, and I don't want it tonight.” The client is calm, oriented, and has no plan to harm anyone.",
        "ask": "Which response by the nurse is most appropriate?",
        "rationale": "A competent adult may refuse any medication. The nurse respects the refusal, explores the reason, reports it to the provider, and documents it. Pressuring, deceiving, or threatening the client violates autonomy.",
        "takeaway": "A competent client may refuse: explore why, report it, and chart it.",
        "body": [
            "options": [
                ["t": "“Tell me more about the foggy feeling. I'll let your provider know you are declining tonight's dose.”", "ok": true,
                 "why": "Respects autonomy, gathers information, and keeps the provider informed."],
                ["t": "“Your provider ordered it, so you need to take it now.”",
                 "why": "Pressures a competent client who has the right to refuse."],
                ["t": "“If you skip it, you may have to stay in the hospital longer.”",
                 "why": "A veiled threat is coercive and undermines trust."],
                ["t": "“I'll mix it into your juice so it tastes better.”",
                 "why": "Hiding medication in food without consent is deceptive."],
            ],
            "images": [
                ["at": "rationale", "alt": "Three boxes in a row: Explore, Report, Document.", "caption": "After a refusal",
                 "svg": """
                 <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 90" width="320" height="90">\
                 <rect width="320" height="90" fill="#ffffff"/>\
                 <g font-family="Helvetica, Arial, sans-serif" font-size="15" text-anchor="middle">\
                 <rect x="10" y="25" width="90" height="40" rx="8" fill="#e8eef6" stroke="#5b7aa6"/>\
                 <text x="55" y="50" fill="#26364d">Explore</text>\
                 <rect x="115" y="25" width="90" height="40" rx="8" fill="#e8eef6" stroke="#5b7aa6"/>\
                 <text x="160" y="50" fill="#26364d">Report</text>\
                 <rect x="220" y="25" width="90" height="40" rx="8" fill="#e8eef6" stroke="#5b7aa6"/>\
                 <text x="265" y="50" fill="#26364d">Document</text>\
                 <path d="M100 45 L113 45 M205 45 L218 45" stroke="#5b7aa6" stroke-width="2"/>\
                 </g></svg>
                 """],
            ],
        ],
        "terms": [
            ["key": "autonomy", "term": "Autonomy", "meaning": "The client's right to make decisions about their own care."],
        ],
    ] }

    private static var priority: [String: Any] { [
        "type": "priority",
        "topic": "Falling oxygen saturation",
        "cj": "Prioritize hypotheses",
        "stem": "A client who returned from surgery two hours ago is receiving oxygen by nasal cannula at 2 L/min. The client is now restless and pulling at the blankets. The nurse reviews the last three sets of readings.",
        "ask": "Which action should the nurse take first?",
        "rationale": "The trend shows falling saturation with rising respiratory and heart rates, and new restlessness can be an early sign of hypoxia. Assessing the airway and breathing and raising the head of the bed come before anything else.",
        "takeaway": "A worsening trend with new restlessness means check airway and breathing first.",
        "body": [
            "table": [
                "caption": "Readings since arrival",
                "head": ["Time", "SpO₂", "RR", "HR"],
                "rows": [["1300", "98%", "16/min", "82/min"], ["1315", "96%", "20/min", "88/min"], ["1330", "93%", "24/min", "97/min"]],
            ],
            "options": [
                ["t": "Assess the airway and breathing, and raise the head of the bed", "ok": true,
                 "why": "Airway and breathing come first when oxygenation is falling."],
                ["t": "Document the readings, since each one is within an acceptable range",
                 "why": "The trend matters more than any single value."],
                ["t": "Move the probe to another finger and recheck the reading",
                 "why": "Rising respiratory and heart rates confirm the change is real."],
                ["t": "Ask the provider for a sedative for the restlessness",
                 "why": "Sedating a hypoxic client can stop their breathing."],
            ],
        ],
        "terms": [
            ["key": "hypoxia", "term": "Hypoxia", "meaning": "Too little oxygen reaching the tissues."],
        ],
    ] }

    private static var selectAll: [String: Any] { [
        "type": "sata",
        "topic": "Preventing falls",
        "cj": "Generate solutions",
        "stem": "An older adult client admitted with pneumonia is unsteady when walking and needs to use the bathroom often during the night.",
        "ask": "Which actions by the nurse help prevent a fall? Select all that apply.",
        "rationale": "Keeping the bed low, the call light in reach, a lit path, and regular toileting rounds all lower the risk of a fall. Restraints and sedatives raise it.",
        "takeaway": "Lower the bed, light the way, offer the bathroom, and keep the call light in reach.",
        "body": [
            "options": [
                ["t": "Keep the bed in its lowest position with the wheels locked", "ok": true, "why": "A low, locked bed shortens any fall."],
                ["t": "Place the call light within the client's reach", "ok": true, "why": "The client can ask for help instead of getting up alone."],
                ["t": "Offer the bathroom on a regular schedule through the night", "ok": true, "why": "Planned toileting prevents rushed trips."],
                ["t": "Raise all four side rails while the client sleeps", "why": "Four raised rails count as a restraint and lead to climbing over them."],
                ["t": "Ask the provider for a sleeping pill", "why": "Sedation adds confusion and unsteadiness."],
            ],
        ],
        "terms": [],
    ] }

    private static var highlight: [String: Any] { [
        "type": "highlight",
        "topic": "Charting objectively",
        "cj": "Recognize cues",
        "stem": "A student nurse drafted this note about a client who became upset during visiting hours. The charge nurse reviews it before it is saved.",
        "ask": "Tap each entry that is written objectively. Select all that apply.",
        "rationale": "Objective entries record what was seen or heard: times, exact words, and measurable findings. Labels such as “rude” or “seemed fine” are opinions.",
        "takeaway": "Chart what you saw and heard, not your opinion of it.",
        "body": [
            "segments": [
                ["t": "1405: Client said, “Leave me alone, I'm done talking.”", "ok": true, "why": "Quotes the client's exact words with a time."],
                ["t": "1406: Client was rude to the visitor.", "why": "“Rude” is an opinion, not an observation."],
                ["t": "1410: Pacing the hallway; fists clenched; voice raised.", "ok": true, "why": "Describes what the nurse observed."],
                ["t": "1420: Client seemed fine after the visit.", "why": "“Seemed fine” does not say what was observed."],
                ["t": "1425: Heart rate 104/min, respirations 22/min.", "ok": true, "why": "Measured findings are objective."],
            ],
        ],
        "terms": [],
    ] }

    private static var ordering: [String: Any] { [
        "type": "order",
        "topic": "Least restrictive steps",
        "cj": "Take action",
        "stem": "A client paces the day room, shouts at staff, and kicks a chair. The client has an order for an oral as-needed medication and no restraint order.",
        "ask": "Place the nurse's actions in the order they should occur, from first to last.",
        "rationale": "Care moves from the least to the most restrictive: approach calmly and talk, offer choices and coping, offer the oral medication, and only then consider restraint with a provider's order.",
        "takeaway": "Talk first, then choices, then medication, and restraint only as a last resort.",
        "body": [
            "items": [
                ["t": "Approach calmly, use the client's name, and ask what happened", "why": "Talking is the least restrictive step."],
                ["t": "Offer a quiet space and coach slow breathing", "why": "Choices and coping come next."],
                ["t": "Offer the ordered oral as-needed medication", "why": "Medication follows when talking and coping are not enough."],
                ["t": "Apply restraint with the team and call the provider for an order", "why": "Restraint is the last resort and needs an order."],
            ],
        ],
        "terms": [],
    ] }

    private static var matching: [String: Any] { [
        "type": "match",
        "topic": "Ethical principles",
        "cj": "Analyze cues",
        "stem": "A nurse manager collects examples of ethical practice on the unit for a staff meeting.",
        "ask": "Match each example with the ethical principle it shows best. One principle is not used.",
        "rationale": "Keeping a promise is fidelity, telling the truth is veracity, fair treatment is justice, and acting for the client's good is beneficence.",
        "takeaway": "Fidelity keeps promises; veracity tells the truth; justice is fair; beneficence does good.",
        "body": [
            "pairs": [
                ["l": "A nurse stays past the shift as promised until a client's family arrives", "r": "Fidelity", "why": "Keeping a promise shows fidelity."],
                ["l": "A nurse tells a client honestly that a test result is delayed", "r": "Veracity", "why": "Telling the truth shows veracity."],
                ["l": "Every client on the unit gets pain checked on the same schedule", "r": "Justice", "why": "Fair, equal treatment shows justice."],
                ["l": "A nurse brings a warm blanket to a shivering client before being asked", "r": "Beneficence", "why": "Acting for the client's good shows beneficence."],
            ],
            "extra": [["r": "Nonmaleficence", "why": "Avoiding harm is not the best fit for any example here."]],
        ],
        "terms": [
            ["key": "fidelity", "term": "Fidelity", "meaning": "Keeping promises and commitments to the client."],
            ["key": "veracity", "term": "Veracity", "meaning": "Being truthful with the client."],
        ],
    ] }

    private static var matrix: [String: Any] { [
        "type": "matrix",
        "topic": "Phases of the relationship",
        "cj": "Evaluate outcomes",
        "stem": "A nurse reviews notes from a therapeutic relationship with a client over a two-week stay.",
        "ask": "For each note, select the phase of the nurse-client relationship it shows best.",
        "rationale": "Orientation sets roles and limits; the working phase is where problems are explored and new skills practiced; termination reviews progress and handles feelings about ending.",
        "takeaway": "Orientation sets the frame, working does the work, termination closes it.",
        "body": [
            "columns": ["Orientation", "Working", "Termination"],
            "rows": [
                ["t": "The nurse explains when they will meet and what stays confidential", "ans": "Orientation", "why": "Setting roles and limits begins the relationship."],
                ["t": "The client names a problem and practices a new coping skill", "ans": "Working", "why": "Exploring problems and practicing skills is the working phase."],
                ["t": "The client asks to stay longer because the nurse is the only one who understands", "ans": "Termination", "why": "Feelings about ending belong to termination."],
            ],
        ],
        "terms": [],
    ] }

    /// A table where a finding can fit more than one column. Four boxes are right.
    private static var matrixMulti: [String: Any] { [
        "type": "matrixmulti",
        "topic": "Fluid volume findings",
        "cj": "Analyze cues",
        "stem": "A nurse is comparing a client's findings with two fluid-volume problems. Some findings fit one problem, and some fit both.",
        "ask": "For each finding, check every disorder it fits. A finding may fit more than one column.",
        "rationale": "Dry mouth, poor turgor, and a weak pulse fit too little fluid. Crackles, standing neck veins, and swollen ankles fit too much. A sudden weight change can go either way.",
        "takeaway": "Match each finding to every fluid problem it fits, and remember that weight can move both ways.",
        "body": [
            "columns": ["Hypovolemia", "Hypervolemia", "Both volume problems written out so the header wraps"],
            "rows": [
                ["t": "Dry mouth, poor skin turgor, and a weak pulse", "ans": ["Hypovolemia"],
                 "why": "These fit too little fluid."],
                ["t": "Crackles in the lungs, standing neck veins, and swollen ankles", "ans": ["Hypervolemia"],
                 "why": "These fit too much fluid."],
                ["t": "A sudden change in weight compared with yesterday", "ans": ["Hypovolemia", "Hypervolemia"],
                 "why": "Weight can move either way."],
            ],
        ],
        "terms": [],
    ] }

    private static var dropDown: [String: Any] { [
        "type": "cloze",
        "topic": "Restraint, seclusion, or a hold",
        "cj": "Generate solutions",
        "stem": "Two clients on the unit become unsafe within minutes of each other. Staff have already tried talking, coping skills, and oral medication with both.",
        "ask": "Complete the charge nurse's plan by choosing the best option for each blank.",
        "rationale": "A client hurting themselves needs mechanical restraint to stop the injury, a client throwing objects at others can be safely separated in seclusion, and briefly holding a client still for an injection is a physical hold.",
        "takeaway": "Match the measure to the danger, and use the least restrictive one that is safe.",
        "body": [
            "cloze": [
                "text": "Client A keeps striking their head on the wall. Best measure now: {0}.\nClient B is throwing chairs toward other clients. Best measure now: {1}.\nStaff hold Client B still for an injection. This is a {2}.",
                "blanks": [
                    ["opts": ["mechanical restraint", "seclusion", "one-to-one observation"], "ans": 0,
                     "why": "Restraint stops the self-injury; seclusion would not."],
                    ["opts": ["seclusion", "mechanical restraint", "a quiet talk"], "ans": 0,
                     "why": "Separating the client protects the others with less restriction."],
                    ["opts": ["physical hold", "chemical restraint", "seclusion"], "ans": 0,
                     "why": "Brief hands-on holding is a physical hold."],
                ],
            ],
        ],
        "terms": [],
    ] }
}
#endif
