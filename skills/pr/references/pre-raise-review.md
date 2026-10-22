# Pre-raise review

Run once on the full diff before the `raise pr` commit. Write one verdict line per item in the
report: `ok`, `fixed: <what>`, or `open: <what>` — `open` items go under Known limitations in the
PR description. Default output is verdicts, not tests: write a test only where the verdict was
"not sure". Every item is a question about the diff plus a grep of its callers; none requires
running the product.

1. Heuristics are a last resort. For any string/token/regex rule on user or model text: can a
   structural signal (tool result, message type, the previous assistant turn, a flag) or a tool the
   model calls decide this instead? If yes, do that. If a heuristic survives, say why in one
   comment and test the single failure class most likely in production (usually negation, or a
   question that shares the keyword). No stopword/filler lists.
2. Teardown. For each new flag, early return, or await: what happens if the peer disconnects, the
   task is cancelled, or the call times out at that line, and who resets the flag? Timers: reset or
   cancelled when a newer event arrives?
3. Truncation and digests. Name the fields a caller's question would need; confirm they survive
   or the code falls back when they do not.
4. Claims. Every number and behavior in the description, a comment, or a docstring traces to code
   or to the config default (the project's config file), not to another docstring. Scope claims
   ("server only", "behind the flag") match the file list.
5. Availability. Prompt text naming a tool is conditional on that tool being registered; a flag
   gates both the prompt and the install; a UI gate is no broader than the feature it exposes;
   an error message matches the error class, not every failure.
6. Boundaries. Each budget or counter at 0, 1, n-1, and overflow in the second item, not only the
   first.
7. Callers and rollout. Grep every producer and consumer of a changed field, message type, or
   config key, including sibling protocols or transports, the other platforms (web, mobile,
   desktop), and old clients or old servers during a mixed-version rollout. State which
   side must deploy first, or why either order is safe.
8. Config reach. Changing a default lists every reader of the key; split the wiring from the flip
   when they differ in reach.
9. Identity. Concurrent calls correlate by a per-call id, never by name plus arguments.
10. Bounds. Every queue, cache, or buffer states its bound in bytes and count and what happens on
    overflow; a semaphore bounds concurrency, not memory.
11. Volume and hygiene. No test asserts an exact log string or library semantics; tests drive the
    production ingress path, not a convenient one; docblocks say why, not what; one wiring test
    beats five helper tests. A new prompt rule goes in the section it belongs to, dedupes against
    it, and names no connector, team, or person. Fixtures name no real colleagues or current work.
