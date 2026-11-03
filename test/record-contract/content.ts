// Invented set files the scenarios import. Nothing in them is real course content.

import type { Json } from "./world";

/** A three-option single-answer question with every field the import checks. */
export function question(id: string, stem: string, extra: Record<string, Json> = {}): Record<string, Json> {
  return {
    id,
    type: "single",
    topic: "Perfusion",
    cj: "Analyze cues",
    need: "Physiological Adaptation",
    diff: 4,
    stem,
    ask: "Which action first?",
    options: [
      { t: "Sit the client up", ok: true, why: "Upright eases the work of breathing." },
      { t: "Offer a book", why: "Reading does not change oxygenation." },
      { t: "Dim the lights", why: "The lights are not the problem." },
    ],
    rationale: "Airway and breathing come before comfort measures.",
    takeaway: "Raise the head of the bed when breathing is hard.",
    terms: [],
    src: "Ch 26 slide 22",
    ...extra,
  };
}

const PIXEL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

/** One question of every format, with a table, both kinds of image, and a term: what the app draws. */
export function everyFormat(): Record<string, Json>[] {
  const base = (id: string, type: string, topic: string, stem: string, ask: string, rationale: string, takeaway: string) => ({
    id,
    type,
    topic,
    cj: "Analyze cues",
    stem,
    ask,
    rationale,
    takeaway,
    terms: [] as Json[],
  });
  return [
    {
      ...base("Q1", "single", "Invented single topic", "An invented client has an invented finding.", "Which action comes first?", "The useful action matches the finding.", "Match the action to the finding."),
      terms: ["tachy"],
      table: { head: ["Time", "HR"], rows: [["0900", 82], ["0915", "94", "extra"]], caption: "Invented readings" },
      options: [
        { t: "The useful action", ok: true, why: "It addresses the finding." },
        { t: "A distractor", why: "It does not change the finding." },
        { t: "Another distractor", why: "Neither does this." },
      ],
    },
    {
      ...base("Q2", "priority", "Invented priority topic", "Four invented clients.", "Whom does the nurse see first?", "Unstable before stable.", "Airway, breathing, circulation."),
      images: [
        { alt: "An invented one-pixel image", src: PIXEL, caption: "Invented caption" },
        { at: "rationale", alt: "An invented grey box", svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10"><rect width="20" height="10" fill="#ccc"/></svg>' },
      ],
      options: [
        { t: "The unstable client", ok: true, why: "Airway first." },
        { t: "The stable client", why: "Can wait." },
        { t: "The sleeping client", why: "Can wait too." },
      ],
    },
    {
      ...base("Q3", "sata", "Invented select-all topic", "An invented finding.", "Select all that apply.", "Three are right.", "Count the right ones."),
      options: [
        { t: "Right one", ok: true, why: "Yes." },
        { t: "Right two", ok: true, why: "Yes." },
        { t: "Wrong one", why: "No." },
        { t: "Right three", ok: true, why: "Yes." },
      ],
    },
    {
      ...base("Q4", "highlight", "Invented highlight topic", "An invented note.", "Highlight the findings that need follow-up.", "Two findings need follow-up.", "Look for change."),
      segments: [
        { t: "The client is alert.", why: "Expected." },
        { t: "Heart rate 128.", ok: true, why: "Too fast." },
        { t: "Skin is cool and clammy.", ok: true, why: "Poor perfusion." },
        { t: "Ate breakfast.", why: "Expected." },
      ],
    },
    {
      ...base("Q5", "order", "Invented order topic", "An invented procedure.", "Put the steps in order.", "One, two, three.", "Order matters."),
      items: [{ t: "Step one", why: "First." }, { t: "Step two" }, { t: "Step three" }],
    },
    {
      ...base("Q6", "match", "Invented match topic", "Invented drugs.", "Match each drug to its class.", "A to A, B to B.", "Classes."),
      pairs: [{ l: "Drug A", r: "Class A", why: "A goes with A." }, { l: "Drug B", r: "Class B" }],
      extra: [{ r: "Class C", why: "Matches nothing." }],
    },
    {
      ...base("Q7", "matrix", "Invented matrix topic", "Invented orders.", "Is each order indicated or not?", "One helps, one does not.", "Think it through."),
      columns: ["Indicated", "Not indicated"],
      rows: [{ t: "Order one", ans: "Indicated", why: "Helps." }, { t: "Order two", ans: "Not indicated" }],
    },
    {
      ...base("Q8", "cloze", "Invented cloze topic", "An invented client.", "Complete the sentence.", "Infection because of the wound.", "Link risk to cause."),
      cloze: {
        text: "The client is most at risk for {0} because of {1}.",
        blanks: [{ opts: ["bleeding", "infection", "falls"], ans: 1, why: "Invented reason." }, { opts: ["the wound", "the diet"], ans: 0 }],
      },
    },
  ];
}

/** A four-option single-answer question about an invented finding, with the set's one term. */
export function finding(id: string, topic: string, cj = "Analyze cues"): Record<string, Json> {
  return {
    id,
    type: "single",
    topic,
    cj,
    stem: `An invented client presents with a finding about ${topic}.`,
    ask: "Which action should the nurse take first?",
    options: [
      { t: "The action that addresses the finding", ok: true, why: "It addresses the finding." },
      { t: "An action for a different finding", why: "It does not change this finding." },
      { t: "Waiting to reassess later", why: "It delays care." },
      { t: "Documenting only", why: "It does not treat the client." },
    ],
    rationale: "The first action addresses the invented finding.",
    takeaway: "Match the action to the finding.",
    need: "Physiological integrity",
    diff: 3,
    src: "Invented lecture notes",
    terms: ["invented-term"],
  };
}

/** A select-all question, so a check counts two formats. */
export function safetyChecks(id: string): Record<string, Json> {
  return {
    id,
    type: "sata",
    topic: "Invented safety checks",
    cj: "Recognize cues",
    stem: "An invented client is being prepared for a procedure.",
    ask: "Which checks should the nurse make? Select all that apply.",
    options: [
      { t: "Check the identity band", ok: true, why: "Two identifiers prevent errors." },
      { t: "Check allergies", ok: true, why: "Allergies change the plan." },
      { t: "Skip the consent", why: "Consent is required." },
      { t: "Ask about the last meal", ok: true, why: "It matters for sedation." },
    ],
    rationale: "Identity, allergies and the last meal are checked before an invented procedure.",
    takeaway: "Check identity, allergies and intake first.",
    need: "Safety and infection control",
    diff: 2,
    src: "Invented lecture notes",
    terms: [],
  };
}

/** A plain single-answer question in as few words as the import takes. */
export function plain(id: string, topic: string, kind: "practice" | "exam" = "practice", twinOf?: string): Record<string, Json> {
  const exam = kind === "exam";
  const why = (text: string): Record<string, Json> => (exam ? { why: text } : {});
  return {
    id,
    ...(twinOf === undefined ? {} : { twinOf }),
    type: "single",
    topic,
    cj: "Analyze cues",
    stem: exam ? "An invented exam stem." : "An invented stem.",
    ask: "Which is right?",
    options: [
      { t: "Right", ok: true, ...why("Yes.") },
      { t: "Wrong", ...why("No.") },
      { t: "Also wrong", ...why("No.") },
    ],
    rationale: exam ? "Invented exam rationale." : "Invented rationale.",
    takeaway: exam ? "Invented exam takeaway." : "Invented takeaway.",
    terms: [],
  };
}

/** A set file as text, the way the app sends one. */
export function source(title: string, questions: Json[], extra: Record<string, Json> = {}): string {
  return JSON.stringify({ title, desc: "Invented practice questions.", terms: {}, questions, ...extra });
}
