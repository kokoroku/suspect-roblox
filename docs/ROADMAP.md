# SUSPECT — Roadmap

**Status:** the core Among Us-style skeleton is complete — round loop, roles/kills/meetings, the five powerups + gacha, the full 10-task pool, sabotage, darkness, and the UI hub all run end to end.
**Now:** pivoting to the Séance/Banishment design. The authoritative design contract is [docs/DESIGN.md](DESIGN.md); this page is the one-page phase view of its §11 migration plan.

---

## Phases

### Phase 0 — Architecture prep
- **Goal:** groundwork for the pivot; no gameplay changes.
- **Milestone:** none — a non-gameplay refactor step.

### Phase 1 — Ritual core
- **Goal:** braziers, threshold, the Convergence, the win rework, Desecrate, and Rage v0.
- **Milestone:** the Banishment arc playable with the existing powerups.

### Phase 2 — Charm grammar
- **Goal:** `CharmDefs`, the dual-face rework of the five Charms, `OmenService` v0.
- **Milestone:** builds matter, omens read.

### Phase 3 — Spirit layer
- **Goal:** the Offer, allegiance kits, ghost chores, Memoria; the séance question behind its flag.
- **Milestone:** the dead are players.

### Phase 4 — Forge + persistence
- **Goal:** Bindings, dark/bright essences, DataStore-backed persistence.
- **Milestone:** the meta economy is real.

### Phase 5 — Rites
- **Goal:** pair-Rites between a loadout's two slots.
- **Milestone:** —

### Phase 6 — The Estate proper + identity pass
- **Goal:** authored tasks on the real map, the séance-circle set-piece, the gaslight-occult art re-skin of `UIStyle`, and the audio pass.
- **Milestone:** the full identity realized on the committed venue.

Each phase ends playtestable; nothing ships to the next phase unverified.

---

## Deferred (out of scope for v1, per DESIGN.md §12)

- Additional venues (venues 2+).
- Cosmetics store content.
- Mobile input pass.
- The charge-from-play system (parked).
- The doom clock (rejected; revisit only if ever needed).
