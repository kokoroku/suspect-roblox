# SUSPECT — Design Document
**v1.0 — "The Séance" identity / "The Banishment" structure**
*Working title "Suspect" retained; name revisited pre-launch. This document freezes the concept agreed across the design sessions. It supersedes the roadmap's gameplay sections. Changes to this doc go through review, not drift.*

---

## 1. Vision

**One sentence:** a candlelit Victorian manor where players clutch glowing Charms, gather at a séance table to accuse each other, and the ghosts of the murdered wage a hidden war over the truth while forging new Charms for their next life.

**Pillars (every feature must serve at least one):**
1. **Deduction on three axes** — who is the Vessel, what can everyone do, and who do the dead serve.
2. **Power costs information** — every Charm effect emits a proportional, readable Omen. No silent power.
3. **The dead are players** — death changes your game; it never ends it.
4. **Familiar skeleton, unfamiliar muscles** — a new player's first match reads as Among Us; match five is when the manor starts talking.
5. **Screenshot-identity** — gaslight-occult everywhere: deep green-black, candle amber, bone ivory, engraved frames, wax seals. If a screenshot could be another game, it fails.

**Positioning:** shares round-based murder fantasy and build-expression with the MM2/Forsaken/Evade audience without competing head-on — slower, social, occult-elegant. The empty lane is *stylish social deduction with a meta economy*. Mass-market on-ramp is the untouched Among Us core loop; niche-proofing is the depth revealing gradually, never front-loaded.

**Launch scope:** ONE map (the Estate), fully committed. Future venues are content updates — different setting, same vibe (derelict theatre, night train, sanatorium).

---

## 2. Glossary

| Term | Meaning |
|---|---|
| **The Entity** | The presence claiming the manor. Antagonist force; never a character on screen in v1. |
| **Vessel** | The possessed player (impostor role). |
| **Crew** | The living investigators performing the Banishment. |
| **Charm** | A powerup. Composed of a **Core** (what it does) + carries an **Essence** (what it donates when bound). |
| **Face** | A Charm's role-dependent expression: every Charm has a **Crew face** and a **Vessel face**. |
| **Omen** | The public tell an activation emits — lamp shudder, cold shimmer, wrong-sounding chime. |
| **Binding** | Fusing one Charm's Essence onto another's Core at the Forge. Directional: A onto B ≠ B onto A. |
| **Rite** | The combo effect triggered by activating both equipped Charms inside a short window. |
| **Braziers** | Physical ritual progress: each completed task lights one at the séance circle. |
| **The Convergence** | The endgame channel: crew must physically hold the circle to complete the Banishment. |
| **Séance** | A meeting. Held at the physical table; where the living may question the dead. |
| **Faithful / Hollowed** | Ghost allegiances: bound to the crew, or claimed by the Entity. |
| **Memoria** | Ghost-earned currency feeding the Forge economy. |
| **The Veil** | The boundary between living and dead. Veil-sight, veil-shock cross it. |

---

## 3. Match structure — the Banishment arc

**Flow:** intermission (existing round loop, unchanged) → roles assigned, loadouts lock (existing pending→active) → **Act I: Preparation** → braziers reach threshold → **Act II: the Convergence** → resolution → end screen → loop.

### Act I — Preparation
Crew perform ritual tasks across the manor; each completion lights one brazier at the séance circle — the task bar made physical and visible to everyone, Vessel included. The Vessel kills, sabotages, and desecrates. Séances interrupt on body reports and the table button.

### Act II — the Convergence
When lit braziers reach threshold, the ritual arms. To win, the crew must **hold the circle**: a required number of living crew stand in the ring and channel for a sustained duration. A kill on a channeler interrupts the channel (progress decays, doesn't zero). The Vessel must act in the open to stop it. The climax happens at the map's centerpiece, every match.

### Escalation — the Entity's Rage (no doom clock)
A match timer was considered and rejected: a Vessel-favoring timeout incentivizes hiding; a lose-lose timeout punishes casual players. Instead, **ritual progress enrages the Entity**: as braziers light, the manor dims in steps, ambient omens grow louder, and the Vessel's cooldowns ease. The *losing* side gains tension-tools; success breeds danger. Comeback pressure without a clock.

### Win matrix
| Outcome | Condition |
|---|---|
| **Crew win — Banishment** | Convergence channel completes. |
| **Crew win — Verdict** | Vessel ejected at a séance. |
| **Vessel win — Parity** | Living Vessel count ≥ living crew count (existing rule). |
| **Vessel win — Manifestation** | A critical sabotage countdown expires unfixed (existing boiler mechanic, re-themed). |

Task completion is **no longer a win condition**. Tasks feed braziers; braziers arm the Convergence; the Convergence wins.

---

## 4. The living — crew gameplay

### Tasks: authored set-pieces
One map means every task is *somewhere specific, about something specific*. The ten proven interaction verbs (drag, timing, sequence, scrub, search, routing, etc.) and the entire session/validation framework survive; the generic reskin layer dies. In its place, an **authored Estate task list** where location is identity:

- *Wind the grandfather clock in the study* (dial verb)
- *Develop the last photograph in the darkroom* (hold-fill verb; the photo is ambience-horror)
- *Re-lead the chapel's stained glass* (wire verb)
- *Transcribe the medium's final entry* (echo verb)
- *Recover the scattered finger-bones from the conservatory* (spot-check verb)
- *Route the incense through the manor's vents* (flow verb)
- …full list authored during the map pass; each task reviewed individually per standing convention.

**Structural upgrades:**
- **Task chains** — multi-stage preparations moving you across the manor (draw water in the cellar → consecrate it at the font). Chains create the travel patterns deduction feeds on. A chain counts as one assignment with visible stages.
- **Personal errand** — each crew member receives one slightly bespoke assignment per match, so a task list feels like *yours*.
- Assignment keeps the short/long profile variety model, applied to the authored list.

### Séances (meetings)
Unchanged core: physical table button, body reports, discussion, voting, ejection. New: the **spirit question** (see §6). Meeting start still resolves active sabotages and cancels effects (existing rules).

---

## 5. The Vessel

**Kit:** proximity kill (existing), sabotages (existing system, re-themed), plus:
- **Snuffing** (= Lights): kills the manor's lamps. Crew get candle-glow; the Vessel sees far (existing darkness pass, unchanged).
- **Manifestation** (= critical/boiler, mechanically 1:1): the Entity begins breaking through; crew must complete two warding stations before the countdown or lose.
- **Desecrate** (new, third sabotage type): instantly extinguish the most recently lit brazier. Long cooldown. No fix station — the cost is the crew re-earning progress and everyone knowing the Entity acted.
- **Veil-sight** (passive): the Vessel faintly sees spirits at all times. Being watched is knowable.
- **Veil-shock** (passive on kill): a kill detonates a pulse that scatters and briefly blinds nearby spirits, keeping the act unwitnessed-by-default.
- **Rage benefits** (automatic): cooldown relief as braziers light (see tuning).

**Pacing intent:** brazier progress is the forcing function — a passive Vessel watches the circle fill. Desecrate taxes unguarded progress but announces activity. The Convergence forces the endgame reveal.

---

## 6. The dead — spirit gameplay

### The Offer (allegiance)
On death, the Entity makes every spirit an offer. Choose once (changeable once per match):
- **Faithful** — bound to the crew you left.
- **Hollowed** — claimed by the Entity.

The choice is private. Living players never see allegiances.

### Kits
| | Faithful | Hollowed |
|---|---|---|
| Séance answers | Must answer truthfully | Answer however they like |
| World actions | **Tend**: steady a lit brazier so the next Desecrate against it fails (consumed) | **Muffle**: briefly dampen the Vessel's next Omen |
| Economy | Memoria buys **bright Essences** at the Forge | Memoria buys **dark Essences** — exclusive binding material |
| Stakes | Shares the crew victory payout | Shares the Vessel victory payout |

**Design laws:**
- **The living light the braziers; the dead keep them lit.** Ghost work is protective/economic, never additive — dying must never accelerate the ritual, or kills backfire.
- **No free-form ghost→living communication, ever.** All dead knowledge reaches the living only through the séance aggregate and ambient tending effects. The channel is narrow by design; allegiance makes what flows through it untrustworthy in the fun way.
- Hollowed powers are informational and deceptive, never destructive — a dead troll can lie (which is just playing Hollowed) but cannot erase crew progress.

### Ghost tasks
Small veil-chores to erase downtime: tending braziers, sweeping halls for **Memoria** motes, attuning at the circle to strengthen the next séance's flicker clarity. All feed the Forge economy and the protective layer only.

### The spirit question (séance answers) — SHIPS BEHIND A FLAG
Once per séance, the living may pose one yes/no question. Spirits answer by candle-flicker: the anonymous **majority of participating spirits**. Faithful must answer truthfully; Hollowed may lie. Because allegiances are hidden, an answer is *evidence weighted by your read on the dead* — never truth. This is the boldest mechanic in the game and the most balance-dangerous: it ships flag-gated, gets playtested hard, and gets cut without ceremony if it degenerates. The earlier "Vessel falsifies one answer" clause is **dropped** — allegiance contests the channel at the source.

---

## 7. Charms — the identity system

### Laws
1. **Dual-face law:** loadouts lock before roles are assigned (existing pending→active flow — load-bearing). Every Charm therefore has a Crew face and a Vessel face on the same Essence grammar. Builds must be dual-purpose; there is no "killer meta" vs "crew meta."
2. **Omen law:** every activation emits a public Omen; stronger effect, louder Omen. This is the master balance dial and the counterplay guarantee.
3. **Complexity cap:** two slots. A Binding occupies **one** slot — fusion adds depth, never width. Rites only fire between your own two slots.
4. **Weight budget:** every Charm has a weight; loadouts have a cap. No double-Epic-Binding stacking.
5. **Cooldowns are the pacing floor** (+ per-match uses for the strongest, per the Augur precedent). The charge-from-play system is **parked**, revisitable only if playtests show the theme wants it.
6. **Horizontal Bindings:** a bound Charm does something *different*, not the same thing bigger. Progression buys expression, not oppression.

### The five base Charms (rework of the existing five; ids unchanged, display names re-themed)
| Charm (id) | Rarity / Weight | Crew face | Vessel face | Omen |
|---|---|---|---|---|
| **Quickening** (SpeedBoost) | Common / 1 | Burst of speed to flee or deliver | Shorter burst that lunges toward the nearest player | A rushing draft; dust kicks visibly |
| **Wick** (Flashlight) **(RETIRED — rework pending; see section 12)** | Common / 1 | Lantern glow + extended sight during Snuffing | Bend light: fake a lamp-flicker elsewhere as misdirection | Your own light stutters |
| **Shroud** (Invisibility) | Rare / 2 | Veil-step: the Vessel's veil-sight loses you briefly | Classic stalking invisibility; a kill breaks it (existing rule) | A cold-breath shimmer trail |
| **Guise** (Shapeshifter) | Epic / 3 | Project an afterimage of yourself elsewhere — an alibi-maker | Copy a nearby player's appearance + display name (existing rules: real identity never falsified server-side) | A mirror-crack chime near the user |
| **Augur** (Seer) | Epic / 3 | Read a nearby soul: true role, limited uses/match (existing) | Mark prey: see the target through walls briefly | A whisper audible to nearby players |

*Faces above are initial designs; each gets its own review before implementation, per standing convention.*

### Essences (rule templates — one per base Charm)
| Essence | Template it applies when bound |
|---|---|
| **Haste** (Quickening) | faster / shorter |
| **Light** (Wick) | light-bending / revealing radius |
| **Veil** (Shroud) | concealment / muffled Omen |
| **Insight** (Augur) | revelation / marking |
| **Mirage** (Guise) | deception / false image |

### Bindings (Core ← Essence; directional; 20 total identities from 5 bases)
Starter table — 10 drafted, remainder authored during implementation reviews:
| Binding | Recipe | Sketch |
|---|---|---|
| Phantom Step | Shroud-core ← Haste | Short invisible dash that snuffs your own candle glow |
| Ghostride | Quickening-core ← Veil | Speed with muffled Omens, shorter duration |
| Revealing Flame | Wick-core ← Insight | A lantern that makes Guise effects shimmer in its light |
| Chase Instinct | Quickening-core ← Insight | Speed burst that shows fresh footprints |
| Mirrorlight | Guise-core ← Light | Your afterimage carries a lamp — a stronger alibi |
| Hollow Skin | Guise-core ← Veil | Disguise with a muffled Omen, shorter uptime |
| Second Sight | Shroud-core ← Insight | While hidden, nearby Omens read louder to you |
| Flashfire | Wick-core ← Haste | An instant bright pulse instead of a sustained glow |
| Quick Read | Augur-core ← Haste | Instant read, but a louder whisper |
| False Augury | Augur-core ← Mirage | Your read also plants a decoy whisper elsewhere |

Dark/bright Essence variants (ghost economy) tint a Binding's flavor and minor stats; they do not add new mechanics in v1.

### Rites (both slots activated within the window; grammar reuses Essences)
Examples: **Dead Sprint** (Quickening+Shroud — brief total silence while moving) · **Carry the Flame** (Quickening+Wick — a sprint that relights one snuffed brazier on touch, crew face) · **The Understudy** (Guise+Shroud — the decoy walks while you vanish for a beat) · **Lamplight Litany** (Wick+Augur — your light shimmer-marks Guise users in radius) · **Silent Read** (Augur+Shroud — your next read emits no whisper). Ten pair-Rites total for the base five; Bindings inherit the Rite of their Core.

---

## 8. Economy

- **Gacha** stays the faucet (weights per Charm; pity = Rare-or-better within 10 rolls, unchanged). Duplicates: 3 → +1 Tier (max 3), and duplicates additionally serve as **Binding fuel**.
- **Memoria** (ghost-earned) buys Essence variants: bright (Faithful) / dark (Hollowed) — the exclusive materials that make allegiance an economic choice, plus victory payout shares.
- **The Forge**: v1 lives as a tab in the existing hub (next to gacha); the lobby's smith becomes its diegetic home later.
- **Persistence is now mandatory** — see §11. A forge economy that resets per server is not an economy.

---

## 9. Tuning baselines (playtest starting points, not commitments)

| Value | Baseline |
|---|---|
| Braziers / threshold | 8 lit to arm the Convergence |
| Convergence channel | max(2, ⌈living crew ÷ 2⌉) crew in the circle, 12s channel; interrupt decays 33%, never zeroes |
| Desecrate | −1 most recent brazier, 45s cooldown, global "the Entity stirs" Omen |
| Entity's Rage | at 3 / 5 / 7 braziers: Vessel cooldowns −10/−20/−30%, lamps dim one step, ambient omen layer + |
| Veil-shock | 25-stud radius, 4s spirit blind + scatter |
| Séance question | 1 per séance; 12s answer window; flicker = simple majority of participating spirits |
| Weight budget | Loadout cap 4 (Common 1 / Rare 2 / Epic 3 / any Binding +1) |
| Rite window | both activations within 4s |
| Memoria | passive tend tick + per ghost-chore; payouts on faction victory |

---

## 10. Scrutiny ledger (failure modes → design answers)

- **Crew speedrun silently** → scattering can't finish the game; the Convergence forces gathering (a kill window); Desecrate taxes unguarded progress.
- **Vessel stalls** → brazier progress is the forcing function; Rage makes stalling-while-behind worse, not safer.
- **Convergence camping** → interrupting requires acting in view of the assembled crew; that exposure is the price; Desecrate cooldown caps delay.
- **Ghost surveillance** → veil-sight makes watching knowable; veil-shock keeps kills unwitnessed; the only info channel is the narrow séance aggregate, contested by allegiance.
- **Dying is good, actually** → tend-don't-add law; ghost value is protective/economic only.
- **Hollowed griefing** → Hollowed powers are deceptive, never destructive; lying at a séance *is* the role.
- **Discord back-channels** → cannot be designed away in any social deduction game; the bar is that in-game channels don't make it worse — a narrow anonymous aggregate clears it.
- **Complexity overwhelm** → per-player surface: 2 slots, 1 binary ghost choice, omens readable at a glance. First match reads as Among Us; depth reveals across matches.
- **Progression stomping** → weight budget + horizontal Bindings + Omen law (power costs information).

---

## 11. Migration from the current build

### Stays (load-bearing, untouched or extended)
Round loop & MatchService states · RoleManager alive/role authority · KillSystem (gains veil-shock + Rage hooks) · MeetingSystem (gains the séance question) · task session/validation framework, TaskRunner, the ten interaction verbs · SabotageService structure (re-theme + Desecrate type) · LightsSystem (gains Rage dim steps) · LoadoutService pending/active (now load-bearing for the dual-face law) · GachaService · hub/UI framework · DebugFlags/changelog/conventions.

### Deprecated
- Task-completion as a win condition (RoleManager.CheckWinCondition's tasksRemaining path).
- Generic per-map task reskins (TaskDefs' multi-skin model).
- The "impostor" terminology at the display layer (internal ids may remain).
- The three-map launch scope; maps 2–3 sections of the roadmap.

### New services
- **RitualService** — braziers (tagged world parts), progress, threshold, the Convergence channel, Desecrate handling, Rage curve, crew-objective win via MatchService.
- **SpiritService** — the Offer, allegiances, ghost chores, Memoria, séance-answer aggregation, veil-shock reception.
- **CharmDefs** (shared data module) — cores, essences, faces, omens, weights, bindings, rites. PowerupService becomes an interpreter of this data.
- **OmenService** (server) — single emitter of world-visible tells, so omen loudness is one tunable system, not scattered effects.
- **Persistence service** — DataStore-backed ownership/tiers/bindings/memoria/currency with pcall+retry wrapping. Promoted from "later" to **before the Forge ships**.

### Phase plan
- **Phase 0 — Architecture prep** (see the pre-implementation list in the accompanying summary; no gameplay changes).
- **Phase 1 — Ritual core:** braziers, threshold, Convergence, win rework, Desecrate, Rage v0. *Playable milestone: the Banishment arc with existing powerups.*
- **Phase 2 — Charm grammar:** CharmDefs, dual-face rework of the five, OmenService v0. *Milestone: builds matter, omens read.*
- **Phase 3 — Spirit layer:** the Offer, allegiance kits, ghost chores, Memoria; séance question behind its flag. *Milestone: the dead are players.*
- **Phase 4 — Forge + persistence:** Bindings, dark/bright essences, DataStore. *Milestone: the meta economy is real.*
- **Phase 5 — Rites.**
- **Phase 6 — The Estate proper + identity pass:** authored tasks on the real map, séance circle set-piece, gaslight-occult art re-skin of UIStyle, the audio pass.
Each phase ends playtestable; nothing ships to the next phase unverified.

---

## 12. Out of scope for v1
Additional venues · cosmetics store content · mobile input pass (standing debt) · additional Charms beyond the five + their Bindings · the charge system (parked) · doom-clock revisit · Entity as a visible character · trading (never pre-launch, per standing rule).

- **Wick/Flashlight rework** — the original is retired from play; redesign owed before or at the identity pass. Ownership data is preserved.
