# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "numpy",
#     "scikit-learn",
# ]
# ///
"""Compare speaker embeddings from the Vedivox database — pairwise cosine similarity
and per-speaker purity analysis using segment-level embeddings."""

import sqlite3
import struct
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from sklearn.metrics.pairwise import cosine_similarity as cos_sim


DB_PATH = Path.home() / "Library/Application Support/Vedivox/Vedivox.sqlite"
EMBEDDING_DIM = 256  # 1024 bytes / 4 bytes per float32


def decode_embedding(blob: bytes) -> np.ndarray:
    return np.array(struct.unpack(f"{EMBEDDING_DIM}f", blob), dtype=np.float32)


@dataclass
class Segment:
    embedding: np.ndarray
    meeting_id: str
    meeting_title: str
    start_time: float


def vedivox_link(meeting_id: str, start_time: float) -> str:
    return f"vedivox://meeting/{meeting_id}?t={int(start_time)}"


def seg_link(seg: Segment, title_len: int = 30) -> str:
    mm, ss = int(seg.start_time) // 60, int(seg.start_time) % 60
    return f"[{mm:02d}:{ss:02d} {seg.meeting_title[:title_len]}]({vedivox_link(seg.meeting_id, seg.start_time)})"


def load_speakers() -> dict[str, dict]:
    conn = sqlite3.connect(DB_PATH)
    rows = conn.execute(
        "SELECT id, nameEn, nameRu, nickname, embedding FROM speakers WHERE embedding IS NOT NULL"
    ).fetchall()
    conn.close()

    speakers = {}
    for sid, name_en, name_ru, nickname, blob in rows:
        label = name_ru or name_en or nickname or sid[:8]
        speakers[sid] = {"id": sid, "label": label, "embedding": decode_embedding(blob)}
    return speakers


def load_segment_embeddings() -> tuple[dict[str, list[np.ndarray]], dict[str, list[Segment]]]:
    """Load per-segment embeddings grouped by speakerId. Returns (emb-only dict, full Segment dict)."""
    conn = sqlite3.connect(DB_PATH)
    rows = conn.execute(
        """SELECT ts.speakerId, ts.embedding, ts.meetingId, m.title, ts.startTime
           FROM transcript_segments ts
           JOIN meetings m ON m.id = ts.meetingId
           WHERE ts.embedding IS NOT NULL AND ts.speakerId IS NOT NULL"""
    ).fetchall()
    conn.close()

    by_speaker: dict[str, list[np.ndarray]] = defaultdict(list)
    by_speaker_full: dict[str, list[Segment]] = defaultdict(list)
    for speaker_id, blob, mid, mtitle, start in rows:
        if len(blob) == EMBEDDING_DIM * 4:
            emb = decode_embedding(blob)
            by_speaker[speaker_id].append(emb)
            by_speaker_full[speaker_id].append(
                Segment(embedding=emb, meeting_id=mid, meeting_title=mtitle or "?", start_time=start)
            )
    return by_speaker, by_speaker_full


def cosine_distance_matrix(embeddings: np.ndarray) -> np.ndarray:
    """Return pairwise cosine similarity matrix."""
    return cos_sim(embeddings)


def best_example(segs: list[Segment], avg_emb: np.ndarray) -> Segment | None:
    """Return the segment closest to the speaker's average embedding."""
    if not segs:
        return None
    emb_matrix = np.array([s.embedding for s in segs])
    sims = cos_sim(emb_matrix, avg_emb.reshape(1, -1)).flatten()
    return segs[int(np.argmax(sims))]


def worst_example(segs: list[Segment], avg_emb: np.ndarray) -> Segment | None:
    """Return the segment furthest from the speaker's average embedding."""
    if not segs:
        return None
    emb_matrix = np.array([s.embedding for s in segs])
    sims = cos_sim(emb_matrix, avg_emb.reshape(1, -1)).flatten()
    return segs[int(np.argmin(sims))]


def analyze_speaker_purity(
    speakers: dict[str, dict],
    segment_embs: dict[str, list[np.ndarray]],
    segment_full: dict[str, list[Segment]],
) -> list[dict]:
    """For each speaker, compute intra-speaker stats from segment embeddings."""
    results = []
    for sid, spk in speakers.items():
        embs = segment_embs.get(sid, [])
        if len(embs) < 3:
            continue

        emb_matrix = np.array(embs)
        # Cosine similarity of each segment to the speaker's average embedding
        avg_emb = spk["embedding"].reshape(1, -1)
        sims_to_avg = cos_sim(emb_matrix, avg_emb).flatten()

        # Intra-cluster: pairwise similarities between all segments
        pairwise = cos_sim(emb_matrix)
        n = len(embs)
        intra_sims = [pairwise[i, j] for i in range(n) for j in range(i + 1, n)]

        segs = segment_full.get(sid, [])
        best = best_example(segs, spk["embedding"])
        worst = worst_example(segs, spk["embedding"])

        # Low min pairwise = there are segments very different from each other
        results.append(
            {
                "id": sid,
                "label": spk["label"],
                "n_segments": n,
                "mean_sim_to_avg": float(np.mean(sims_to_avg)),
                "min_sim_to_avg": float(np.min(sims_to_avg)),
                "intra_mean": float(np.mean(intra_sims)),
                "intra_min": float(np.min(intra_sims)),
                "intra_std": float(np.std(intra_sims)),
                "best_example": best,
                "worst_example": worst,
            }
        )

    results.sort(key=lambda x: x["intra_min"])
    return results


def main() -> None:
    speakers = load_speakers()
    segment_embs, segment_full = load_segment_embeddings()
    print(f"Loaded {len(speakers)} speakers, {sum(len(v) for v in segment_embs.values())} segment embeddings\n")

    # --- Part 1: Pairwise speaker similarity ---
    ids = list(speakers.keys())
    labels = [speakers[sid]["label"] for sid in ids]
    emb_matrix = np.array([speakers[sid]["embedding"] for sid in ids])
    sim_matrix = cos_sim(emb_matrix)

    pairs: list[tuple[float, str, str, str, str]] = []
    n = len(ids)
    for i in range(n):
        for j in range(i + 1, n):
            pairs.append((sim_matrix[i, j], labels[i], labels[j], ids[i], ids[j]))
    pairs.sort(key=lambda x: x[0], reverse=True)

    print("=== TOP 20 MOST SIMILAR PAIRS ===\n")
    for sim, a, b, sid_a, sid_b in pairs[:20]:
        marker = " ⚠️" if sim > 0.85 else ""
        ex_a = best_example(segment_full.get(sid_a, []), speakers[sid_a]["embedding"])
        ex_b = best_example(segment_full.get(sid_b, []), speakers[sid_b]["embedding"])
        link_a = f" — {seg_link(ex_a)}" if ex_a else ""
        link_b = f" — {seg_link(ex_b)}" if ex_b else ""
        print(f"- **{sim:.3f}** {a}{link_a} ↔ {b}{link_b}{marker}")

    # --- Part 2: Speaker purity analysis ---
    print("\n\n=== SPEAKER PURITY (sorted by worst intra-pair, low = mixed) ===\n")

    purity = analyze_speaker_purity(speakers, segment_embs, segment_full)
    for r in purity:
        flag = " ⚠️ MIXED?" if r["intra_min"] < 0.3 else ""
        best = r["best_example"]
        worst = r["worst_example"]
        best_link = seg_link(best) if best else ""
        worst_link = seg_link(worst) if worst else ""
        print(
            f"- **{r['label']}** ({r['n_segments']} segs) "
            f"avg={r['mean_sim_to_avg']:.3f} min={r['min_sim_to_avg']:.3f} "
            f"intra μ={r['intra_mean']:.3f} min={r['intra_min']:.3f} σ={r['intra_std']:.3f}{flag}"
        )
        if best_link or worst_link:
            print(f"  best: {best_link} | worst: {worst_link}")

    # --- Part 3: Cross-check suspicious pairs against segments ---
    print("\n\n=== CROSS-CHECK: suspicious pairs vs segment evidence ===")
    for sim, a, b, sid_a, sid_b in pairs[:6]:
        if sim < 0.85:
            break
        segs_a = segment_embs.get(sid_a, [])
        segs_b = segment_embs.get(sid_b, [])
        if not segs_a or not segs_b:
            print(f"\n{a} ↔ {b} (sim={sim:.3f}): insufficient segment data")
            continue

        # How similar are A's segments to B's average, and vice versa?
        avg_a = speakers[sid_a]["embedding"].reshape(1, -1)
        avg_b = speakers[sid_b]["embedding"].reshape(1, -1)
        a_to_b = cos_sim(np.array(segs_a), avg_b).flatten()
        b_to_a = cos_sim(np.array(segs_b), avg_a).flatten()

        ex_a = best_example(segment_full.get(sid_a, []), speakers[sid_a]["embedding"])
        ex_b = best_example(segment_full.get(sid_b, []), speakers[sid_b]["embedding"])
        link_a = f" {seg_link(ex_a)}" if ex_a else ""
        link_b = f" {seg_link(ex_b)}" if ex_b else ""

        print(f"\n**{a}** ({len(segs_a)} segs){link_a} ↔ **{b}** ({len(segs_b)} segs){link_b}  [avg sim={sim:.3f}]")
        print(
            f"  A's segments → B's avg: mean={np.mean(a_to_b):.3f}, min={np.min(a_to_b):.3f}, max={np.max(a_to_b):.3f}"
        )
        print(
            f"  B's segments → A's avg: mean={np.mean(b_to_a):.3f}, min={np.min(b_to_a):.3f}, max={np.max(b_to_a):.3f}"
        )


if __name__ == "__main__":
    main()
