# 0049 — Embedding vocab id order, the semantic operating point, and the heater-thread qrels

## Context

The judged-relevance benchmark (decision 0047) measured the semantic slice with the real `bge-small-en-v1.5` model and found the target of the zero-keyword paraphrase query `q142` ("the email about the building warmth being restored") at hybrid rank 21 — far outside the M2 "top 3" Done-when. The pure-vector ranking put unrelated messages ("Re: Purchase order question" at 0.6526) above the heater email (0.6344), and every cosine sat in a narrow 0.63–0.67 band.

Ground truth in Python (torch + HuggingFace tokenizer) ordered the same texts correctly (target 0.6045 vs 0.5400/0.5289), and the conversion self-check (max abs error 0.0047) proved the Core ML graph faithful. The divergence had to be in the Swift-side token ids.

## Root cause

`scripts/convert-embedding-model.py` wrote the vocabulary with `"\n".join(tokenizer.get_vocab().keys())`. `WordPieceTokenizer` assigns ids by file position, so line N must be id N — but HF's `get_vocab()` returns a token→id dict whose key order is not the id order. The written file had `[PAD]` on line 20668, `[CLS]` on line 2471; every Swift token id was wrong. The model then embedded near-random (but deterministic, unit-normalized) vectors: all contract tests still passed (dims, norm, determinism), and the relevant-vs-unrelated ordering test passed on a large-margin pair, so the damage was invisible until a hard within-domain judged set exposed it. The conversion self-check could never catch it: it tokenizes in Python and feeds ids straight to the graph, never round-tripping the vocab file.

## Decision

1. The converter writes the vocabulary sorted by id and refuses to write unless ids are a contiguous 0..N-1 range; it verifies the round trip (`convert_ids_to_tokens(range(8))` equals the first file lines). Fixed in the same commit.
2. A Swift regression test (`testRealVocabMapsKnownTokensToTheirPublishedIds`, real-weights-gated) asserts the published ids — `[CLS]`=101, `[SEP]`=102, `[UNK]`=100, and the golden id vector for "re : heater in unit 4" (`101, 2128, 1024, 3684, 2121, 1999, 3131, 1018, 102`, verified against the HuggingFace tokenizer) — so a scrambled vocab fails a test, not a benchmark.
3. The judged set gains the thread context the paraphrase query needs: `q142` now grades `j047` (repair visit confirmation) and `j048` ("Still cold after the visit") at grade 1 alongside `j046` (grade 2) — they are part of the same warmth-restoration story a person is asking for, and a relevance set that leaves them ungraded mis-penalizes a correct ranking. `q143` ("the email where the landlord agreed to fix the heater") records the ROADMAP M2 exemplar phrasing as a plain keyword-gate query.

## Measured operating point (judged corpus, ~150 messages, real model)

- Keyword-only gate (140 queries): nDCG@10 = 0.9839, recall@50 = 0.9911, mean top rank 1.0.
- Hybrid with the real model (141 queries): gate nDCG@10 = 0.9770, recall@50 = 0.9840, mean top rank 1.0; semantic slice nDCG@10 = 0.6441, recall@50 = 1.0, **top rank 1** — the M2 "semantic query finds its target in the top 3" line is met with real output.
- The previously recorded toy-model numbers (slice top rank 45) were an artifact of the same vocab bug's toy counterpart? No — the toy vocabulary was hand-written in id order and unaffected; its rank 45 reflects the toy model's own quality floor.

## Consequences

- The semantic slice is trustworthy only together with the vocab-order test; any future converted model must run the round-trip check.
- qrels changes are versioned (file `version: 3`) and documented here; they refine judgments toward the corpus's actual content, they do not relax thresholds.
- The hybrid fusion stays unweighted RRF (k = 60): with the vocab fixed, the mechanism meets the roadmap line without touching fusion constants. If a future judged query regresses, tune weights only with measured gate evidence.
