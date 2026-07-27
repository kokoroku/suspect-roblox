--[[
	================================================================
	EstateBuilder.lua
	*** EDIT-TIME TOOL. THIS IS NOT A RUNTIME SERVICE. ***
	================================================================

	HOW TO RUN IT - Studio, EDIT MODE (not Play), Command Bar, one line:

	    require(game.ServerScriptService.Services.EstateBuilder).Build()

	Then SAVE THE PLACE. The manor is ordinary Parts in Workspace from that
	moment on; nothing in the running game ever calls this file again.

	*** NEVER REQUIRE THIS AT RUNTIME. *** Bootstrap must not touch it, no
	service may require it, and nothing here may be hooked into the round loop.
	It is a level-design tool that happens to be written in Lua and to live in
	the repo so the map is version-controlled as DATA instead of as a binary
	.rbxl nobody can diff. Requiring it on a live server would rebuild the map
	under the players' feet.

	IDEMPOTENT BY CONSTRUCTION. Build() destroys any existing Workspace model
	named "TheEstate" before it starts, so running it fifty times leaves exactly
	one manor. It also destroys "SuspectTestMap" while DESTROY_TEST_MAP is true
	(default): the graybox estate is RETIRED and must not linger next to the
	real one, or the tagged-part handlers will find two of everything.

	SCOPE - THE SHELL *AND* THE DRESSING PASS (docs/DESIGN.md sections 2-4).
	Rooms, corridors, cellar, stairs, doorways, windows, ceilings, per-wing roofs
	and the grounds; then furniture, room lamps, the ten task stations as diegetic
	objects, the three sabotage stations, the séance heart in the Parlor (inlay
	circle, table, chairs, Convergence zone, eight braziers, emergency button), two
	sealed secret-passage reservations, and the map's spawn. Build() runs seven
	validators - perimeter, stair connectivity, roof coverage, roof/interior
	intersection, the double-height assertion, the burial check and the gameplay
	manifest - and prints their verdicts.

	THE BUILDER SUPPLIES WHAT THE RUNTIME CONSUMES, and nothing here invents a
	contract. Every tag, attribute and child name below was read out of the service
	that reads it - TaskStationHandler, SabotageStationHandler,
	EmergencyButtonHandler, RitualService and LightsSystem - and each is cited at
	the point of use. If one of those services changes its contract, the citation is
	where to look. Art quality is deliberately ROUGH-BUT-EVOCATIVE: plain Parts with
	enough character that the art team has something to react to.

	STRUCTURE - PLAN (data) + BUILDER (interpreter). Every revision to the manor
	should be an edit to the PLAN tables below and nothing else; the builder is
	a dumb interpreter that normalizes the exact wall/floor/opening maths from
	approximate room bounds. If you find yourself editing the builder to move a
	room, the plan is missing a field.

	COORDINATES - Roblox compass convention: NORTH is -Z, SOUTH is +Z, EAST is
	+X, WEST is -X. Ground floor walks at Y = 0. The cellar walks at Y = -11.
	Rects are written {x1, z1, x2, z2} with x1 < x2 and z1 < z2 always.
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
-- The dressing pass tags parts for the runtime handlers; see TAGS below.
local CollectionService = game:GetService("CollectionService")

local EstateBuilder = {}

-- ============================================================
-- BUILD CONFIG
-- ============================================================
-- BUMP THIS ON EVERY EDIT TO THIS FILE, without being asked. It is printed as
-- the first line of the Build() summary for one reason: Studio can hold a stale
-- copy of this module after a Rojo sync, and a build from stale code looks
-- exactly like a build from fresh code. If the revision printed in the Output
-- window is not the one at the top of this file, nothing below it is evidence of
-- anything - re-sync and build again before reading a single result.
local REVISION = "69R2"

local MODEL_NAME = "TheEstate"

-- The graybox is retired. Leaving it in the place alongside the manor would
-- give TaskStationHandler / SabotageStationHandler two sets of tagged parts to
-- register, and the second registration silently wins.
local DESTROY_TEST_MAP = true
local TEST_MAP_NAME = "SuspectTestMap"

-- ============================================================
-- PALETTE - docs/DESIGN.md section 1, pillar 5 (screenshot-identity).
-- Deep green-black, candle amber, bone ivory. These are GRAYBOX values for the
-- art team to react to, not final colors; every one of them is a one-line edit.
-- ============================================================
local PALETTE = {
	DarkWood    = Color3.fromRGB(54, 40, 30),    -- beams, door frames, stair carriage
	WallPlaster = Color3.fromRGB(208, 198, 180), -- bone ivory, upper walls
	WallPanel   = Color3.fromRGB(36, 48, 40),    -- deep green wainscot, lower walls
	Floorboard  = Color3.fromRGB(92, 68, 48),    -- ground-floor boards
	Stone       = Color3.fromRGB(110, 108, 104), -- cellar walls, vault lids
	Slate       = Color3.fromRGB(52, 52, 58),    -- roof
	TrimBrass   = Color3.fromRGB(150, 120, 60),  -- lintels, window arches, mullions, rails
	GlassTint   = Color3.fromRGB(150, 180, 210), -- pale blue night glass
	Grass       = Color3.fromRGB(58, 74, 48),    -- the grounds the manor sits in

	-- ---- DRESSING PASS. Same status as the rest: graybox values to react to.
	Candlelight = Color3.fromRGB(255, 196, 130), -- gaslight bulbs; the manor's only warmth
	ClothGreen  = Color3.fromRGB(26, 48, 38),    -- séance cloth, rugs, pew cushions
	Canvas      = Color3.fromRGB(28, 24, 22),    -- gallery portraits: dark, unreadable
	Iron        = Color3.fromRGB(40, 38, 36),    -- boiler, brackets, hardware
	Copper      = Color3.fromRGB(122, 74, 42),   -- cellar pipework
	Soil        = Color3.fromRGB(44, 34, 26),    -- conservatory planter beds
	Bottle      = Color3.fromRGB(26, 44, 30),    -- wine
	Water       = Color3.fromRGB(38, 58, 66),    -- the cistern
	Bone        = Color3.fromRGB(214, 206, 186), -- bone charms, altar cloth, candles
	BookRed     = Color3.fromRGB(96, 40, 36),
	BookBlue    = Color3.fromRGB(40, 52, 78),
	BookTan     = Color3.fromRGB(128, 108, 76),
}

-- Enum.Material.Plaster exists on modern clients but is not worth a hard
-- dependency in a tool that has to run in whatever Studio the artist has open.
local function material(name, fallback)
	local ok, value = pcall(function()
		return Enum.Material[name]
	end)
	if ok and value then
		return value
	end
	return Enum.Material[fallback]
end

local MATERIALS = {
	Floor        = Enum.Material.WoodPlanks,             -- ground-floor boards
	Panel        = Enum.Material.Wood,                   -- wainscot
	Plaster      = material("Plaster", "SmoothPlastic"), -- upper walls
	CellarStone  = Enum.Material.Slate,                  -- cellar floors + walls
	ChapelFloor  = Enum.Material.Marble,                 -- the chapel reads as consecrated ground
	Roof         = Enum.Material.Slate,
	Trim         = Enum.Material.Metal,
	Glass        = Enum.Material.Glass,
	Timber       = Enum.Material.Wood,
	Grass        = Enum.Material.Grass,
	Plinth       = Enum.Material.Slate,

	-- ---- DRESSING PASS
	Bulb         = Enum.Material.Neon,                 -- every lamp bulb and brazier flame
	Fabric       = material("Fabric", "SmoothPlastic"),-- rugs, cloth, cushions
	Iron         = Enum.Material.Metal,
	Stonework    = Enum.Material.Slate,                -- altar, cistern kerb, planter kerbs
	Soil         = material("Ground", "Slate"),
	Paper        = Enum.Material.SmoothPlastic,
}

-- ============================================================
-- DIMENSIONS. Everything the builder measures with; nothing below is repeated
-- as a literal anywhere in the interpreter.
-- ============================================================
local DIM = {
	WallHeight       = 14,   -- ground floor, floor surface to ceiling underside
	DoubleHeight     = 28,   -- Foyer + Séance Parlor: the two rooms that must feel like rooms
	CellarWallHeight = 10,
	WallThickness    = 1,

	-- THE ONE DETAIL THAT CARRIES THE VICTORIAN READ. Every interior wall is
	-- built as TWO STACKED PARTS: a ~4-stud dark green wood wainscot below, bone
	-- ivory plaster above. A single flat wall part reads as "Roblox baseplate
	-- building" no matter what color it is; the horizontal break at chair-rail
	-- height is what makes a box read as a PANELLED ROOM. It costs one extra
	-- part per wall segment and it is the highest-value stud in this file.
	-- Do not "optimize" it back into one part.
	WainscotHeight   = 4,

	FloorThickness   = 1,
	CeilingThickness = 1,

	DoorWidth        = 8,
	DoorHeight       = 10,
	LintelHeight     = 0.75, -- TrimBrass strip over EVERY doorway
	LintelProud      = 0.5,  -- how far the lintel stands out past the wall face

	-- ONE WINDOW SIZE FOR THE WHOLE MANOR. 6 wide by 8 tall (sill 3 to head 11).
	-- The review found mixed spacing, not mixed sizes, but the size lives here so
	-- there is exactly one place it could ever diverge.
	WindowWidth      = 6,
	WindowSill       = 3,    -- opening bottom, above the wainscot line's foot
	WindowHead       = 11,   -- opening top; tall and narrow reads as arched
	WindowArch       = 0.9,  -- brass arch strip height above the head
	PaneThickness    = 0.4,
	PaneTransparency = 0.35,
	MoonlightBright  = 0.35,
	-- SPACING IS DERIVED FROM WALL LENGTH, NOT FROM ROOMS. One window per this
	-- many studs of exterior run, with at least CornerMargin of solid wall at
	-- each end - so a corner always reads as a corner and no two walls of the
	-- same length can come out different.
	WindowPitch        = 11,
	WindowCornerMargin = 4,

	-- ------------------------------------------------------------
	-- STAIR ASSEMBLY, all of it DERIVED from the room and its doorway (see
	-- deriveStairs and the block comment on PLAN.Stairs).
	--
	-- THE FLIGHT RUNS ALONG D - the vector pointing from the doorway INTO the room,
	-- perpendicular to the doorway's wall. You come through the door and face
	-- straight down the stairs. The previous revision had the flight running
	-- PARALLEL to that wall, which is the opposite arrangement and is why both
	-- stairs presented their long guard rail to their own doorway.
	--
	--   Head           solid floor between the doorway wall and the head of the
	--                  flight, so you step through the door onto floor.
	--   ExitClear      clear DESTINATION-ROOM floor beyond the foot of the flight,
	--                  which is what fixes where the flight has to stop.
	--   Width          shaft width across the flight, capped by the doorway's span.
	--   Tread/RiseMax  the flight fits the run it is given: tread depth is the
	--                  target, and the step count is whatever keeps the rise under
	--                  RiseMax. A short room gets a steeper stair, not a broken one.
	--   TopProximity   how near the doorway the top step must land, in studs.
	-- ------------------------------------------------------------
	StairHead        = 2,
	StairExitClear   = 3,
	StairWidth       = 7,
	StairTread       = 1,
	StairRiseMax     = 1.6,
	StairTopProximity = 6,

	-- THE RAIL IS A RAILING, NOT A PARAPET. It used to be a solid brass slab the
	-- full length of every shaft edge, 3.5 studs tall - from a stair-room doorway
	-- the whole assembly read as a wall of brass with a room hidden behind it.
	-- Posts at a spacing plus one thin top rail: you see the flight THROUGH it.
	RailHeight       = 3,
	RailPost         = 0.4,
	RailPostSpacing  = 3,
	RailTopThickness = 0.3,

	-- Roofs are seated per wing on that wing's wall top, so there is no global
	-- eave height any more. Rise is proportional to the span being covered and
	-- clamped, which keeps a 14-stud corridor from getting a cathedral pitch.
	RoofPitch        = 0.5,
	RoofRiseMin      = 6,
	RoofRiseMax      = 18,
	RoofOverhang     = 2,
	RoofThickness    = 1,
	GableThickness   = 1,

	-- The grounds. Top of the grass is flush with the underside of the ground
	-- floor slab, which is where an exterior wall meets the earth; thickness is
	-- comfortably deeper than the cellar so nothing is left poking out below.
	GroundsMargin    = 80,
	GroundsThickness = 40,
	PlinthHeight     = 1.5,
	-- The plinth stands proud on the EXTERIOR FACE ONLY. It used to be centered on
	-- the wall plane and reach this far past BOTH faces, which is what put a gray
	-- stone strip along the interior base of every exterior wall - see buildGrounds.
	PlinthProud      = 0.6,

	-- BURIAL COVER. How much earth sits over a vault lid where the cellar reaches
	-- past the rooms above it. The lid is sunk by this much and the gap is filled
	-- with turf, so from outside the grounds are uninterrupted lawn and not a gray
	-- slab. Cellar WALLS over the same ground are capped at the same sunk height,
	-- or their tops would surface as lines in the grass. checkBurial() enforces it.
	VaultCover       = 1,

	-- ------------------------------------------------------------
	-- THE RITUAL HEART (docs/DESIGN.md sections 3-4). Four CONCENTRIC radii about
	-- the Parlor centre, and their ORDER IS LOAD-BEARING:
	--     table (4.5) < chairs (10) < Convergence zone (12) < braziers (14)
	-- The zone must sit inside the brazier ring so "hold the circle" reads as
	-- standing among the lit braziers, and MeetingSystem's MEETING_SEAT_RADIUS must
	-- land in the gap BETWEEN the chairs and the braziers or players are teleported
	-- into furniture. That gap is why the chairs are slim and the brazier bowls
	-- narrow: chair backs reach 10.93, brazier bowls start at 13.1, and
	-- MEETING_SEAT_RADIUS = 12 sits almost exactly in the middle of that annulus
	-- with about a stud of clearance on each side. Narrow either ring's furniture
	-- and you narrow that clearance - the numbers are load-bearing, not incidental.
	-- ------------------------------------------------------------
	SeanceTableRadius   = 4.5,
	RitualChairRadius   = 10,
	RitualZoneRadius    = 12,
	RitualBrazierRadius = 14,
	RitualChairCount    = 8,
	-- DESIGN.md section 9 baseline: 8 lit braziers arm the Convergence. This is the
	-- map's physical ceiling; RitualService derives the live threshold from it.
	BrazierCount        = 8,

	-- LAMP TUNING. The manor must read CANDLELIT, not lit: these are deliberately
	-- dim and short-ranged, against Lighting.Brightness 1.2 and a near-black
	-- ambient. LightsSystem captures each PointLight's Brightness as its base and
	-- scales it per Rage step, so these are the numbers the Entity's Rage erodes.
	-- Sconces trimmed a quarter down from 0.7 and pulled in from 15 - see the
	-- comment on KITS.Sconce for the intent. Chandeliers and cellar bulbs are
	-- deliberately UNCHANGED: they are the pools of light, and taking them down
	-- with the sconces would flatten the contrast rather than deepen it.
	SconceBright        = 0.52,
	SconceRange         = 13,
	ChandelierBright    = 0.9,
	ChandelierRange     = 22,
	CellarBulbBright    = 0.6,
	CellarBulbRange     = 14,
	BrazierBright       = 2.2,  -- braziers are RITUAL light, not room light: brighter
	BrazierRange        = 26,

	-- CORRIDOR SPACING and the DARK-PATCH BUDGET, and they are two different jobs.
	--
	-- Spacing is what the run kit aims for. The budget is the largest stretch the
	-- manifest will tolerate before it complains, and it is deliberately LOOSER
	-- than the spacing: it exists to catch a genuinely dead stretch - a corridor
	-- nobody lit at all - not to force density. Setting it tight is what turned the
	-- Gallery into a runway, because every gap the check disliked was answered with
	-- another sconce until both walls were lined with them.
	SconceSpacing       = 22,
	SconceMaxGap        = 26,

	-- ONE BOOK SIZE FOR THE WHOLE MANOR, the same argument as ONE WINDOW SIZE. Three
	-- shelf kits were each inventing their own, so a Library case and a Study case
	-- read as different furniture at a glance.
	BookWidth           = 0.9,
	BookHeight          = 1.15,
	ShelfDepth          = 1.6,
	ShelfHeight         = 8,
	-- Runs stop this far short of a corner so two runs meeting at one can never
	-- interpenetrate, and so a case never looks jammed into the plaster.
	ShelfCornerInset    = 1,
}

-- ============================================================
-- TAGS - the runtime contract, in one place.
--
-- EVERY ONE OF THESE WAS READ OUT OF THE SERVICE THAT CONSUMES IT. Nothing here
-- is a convention this file invented; a tag with no reader is a part that does
-- nothing. Cited at each use site as well, because the use site is where someone
-- editing the map will actually be looking.
-- ============================================================
local TAGS = {
	-- TaskStationHandler.server.lua: part NAME is the task id, TaskType attribute
	-- selects the minigame, ProximityPrompt child required.
	TaskStation = "TaskStation",
	-- SabotageStationHandler.server.lua: SabotageType + FixId attributes,
	-- ProximityPrompt child required (the handler disables the prompt itself).
	SabotageStation = "SabotageStation",
	-- EmergencyButtonHandler.server.lua: ProximityPrompt child required.
	EmergencyButton = "EmergencyButton",
	-- RitualService.lua: BrazierIndex attribute (1..N unique) + a "Flame" child
	-- BasePart holding a PointLight and a Fire.
	Brazier = "Brazier",
	-- RitualService.lua: exactly ONE part; Position is the centre, and the radius
	-- is max(Size.X, Size.Z) / 2.
	ConvergenceZone = "ConvergenceZone",
	-- LightsSystem.lua: the tagged BasePart is darkened and EVERY descendant
	-- PointLight/SpotLight/SurfaceLight is switched off.
	RoomLamp = "RoomLamp",
	-- NOT READ BY ANYTHING YET - a reservation. See PLAN.Secrets.
	SecretPassage = "SecretPassage",
}

local GROUND_Y = 0    -- ground floor walking surface
local CELLAR_Y = -11  -- cellar walking surface

-- ============================================================
-- ============================================================
-- PLAN - THE DATA. Edit this, not the builder.
-- ============================================================
-- ============================================================
local PLAN = {}

-- ------------------------------------------------------------
-- ROOMS. Each entry:
--   name         unique; becomes the Folder name inside the model
--   floor        "Ground" | "Cellar"
--   rects        one or more {x1, z1, x2, z2} footprints. MULTIPLE RECTS make an
--                L-shaped room: the builder suppresses walls between two rects of
--                the SAME room, so the Gallery's dog-leg is one continuous space.
--   doubleHeight ceiling at 28 instead of 14
--   floorMaterial / floorColor  overrides
--   glassWalls   exterior walls become brass-mullioned glass (Conservatory)
--   ceiling      false to skip the solid ceiling (Conservatory has a glass roof)
--   purpose      why this room exists in the design
--
-- FOOTPRINT NOTE, read before enlarging anything: the room sizes below are the
-- ones specified, and laid out with no gaps they bound to roughly 160 x 166
-- studs rather than the 230 x 190 the brief targets. The manor is an irregular
-- H-plan, not a filled rectangle, so the shortfall is real floor area and not
-- just a bounding-box artifact. Growing it is a pure data edit - widen the
-- peripheral rooms and push the wings out - and it is deliberately NOT done
-- here, because guessing at +40% on every room is a design call for the shell
-- review, not a builder decision.
-- ------------------------------------------------------------
PLAN.Rooms = {
	-- ---------- GROUND FLOOR ----------
	{
		name = "GrandFoyer", floor = "Ground", doubleHeight = true,
		rects = { {-22, 56, 22, 90} },
		purpose = "South-center. The arrival hall and the spawn room next prompt. Double-height so the first thing a player sees is scale.",
	},
	{
		name = "GreatHall", floor = "Ground",
		rects = { {-7, -26, 7, 56} },
		purpose = "The N-S spine. 14 wide, 82 long: every route between the Foyer and the Parlor passes through it, which is what makes movement readable to everyone else.",
	},
	{
		name = "SeanceParlor", floor = "Ground", doubleHeight = true,
		rects = { {-22, -70, 22, -26} },
		purpose = "THE HEART (docs/DESIGN.md sections 3 & 4). 44x44, double-height, deliberately EMPTY this pass - the séance table, the brazier ring and the Convergence circle all land here next prompt and must be composed into open floor, not squeezed around furniture.",
	},
	{
		name = "Gallery", floor = "Ground",
		-- Two rects, one room: a long west leg and a short leg flanking the spine.
		-- The west leg runs all the way south to Z=70 so the Gallery still meets
		-- the Foyer directly - the spine leg is cut short at Z=40 to make room for
		-- StairHall, and without this extension the whole west wing would be a
		-- dead end reachable only through the Library.
		rects = { {-36, -76, -22, 70}, {-22, -26, -7, 40} },
		purpose = "West circulation. Wraps the Parlor, hugs the spine, and meets the Foyer on its own west wall.",
	},
	{
		name = "StairHall", floor = "Ground",
		rects = { {-22, 40, -7, 56} },
		-- DEDICATED STAIR ROOM. Standing directive from the shell review: a stair
		-- NEVER lives inside another room's floor. The west flight is entirely
		-- inside this room, behind one doorway off the spine's south-west side, so
		-- the Great Hall floor is solid end to end and the Foyer-to-Parlor walk -
		-- the map's most important sightline and the approach to the séance circle
		-- - is never interrupted.
		--
		-- 15 wide is structural, not a choice: the room has to fill the gap
		-- between the Gallery's spine leg (X=-22) and the Great Hall (X=-7)
		-- exactly, or a sliver of unbuilt space is left in the middle of the plan.
		-- Depth is 16 per the brief.
		purpose = "Dedicated stair room off the Great Hall's south-west side. Holds the west flight and nothing else.",
	},
	{
		name = "Chapel", floor = "Ground",
		rects = { {-66, -76, -36, -40} },
		floorMaterial = MATERIALS.ChapelFloor, floorColor = PALETTE.Stone,
		purpose = "NW corner. Marble floor; the stained-glass re-leading task lives here.",
	},
	{
		name = "Library", floor = "Ground",
		rects = { {-72, -40, -36, -10} },
		purpose = "West wing, north. Tall windows on the west facade.",
	},
	{
		name = "Study", floor = "Ground",
		rects = { {-62, -10, -36, 14} },
		purpose = "West wing, south of the Library. The grandfather clock task room.",
	},
	{
		name = "MusicRoom", floor = "Ground",
		rects = { {-44, 70, -22, 90} },
		purpose = "SW, off the Foyer. Small and acoustically dead-ended on purpose - a room you can be cornered in.",
	},
	{
		name = "Kitchen", floor = "Ground",
		rects = { {7, 32, 33, 56} },
		purpose = "East of the spine, north of the Dining Hall. Its floor is solid - the service stair is next door, not in it.",
	},
	{
		name = "ServiceStair", floor = "Ground",
		rects = { {33, 40, 45, 56} },
		-- DEDICATED STAIR ROOM, same directive as StairHall. The east flight used
		-- to be a pit punched straight through the Kitchen floor; it now lives
		-- here, behind one doorway off the Kitchen's east wall.
		purpose = "Dedicated stair room off the Kitchen. Holds the east flight down to the east cellar landing.",
	},
	{
		name = "Darkroom", floor = "Ground",
		rects = { {7, 14, 23, 32} },
		-- WINDOWLESS ON PURPOSE, and it is the one room where that is a mechanic
		-- rather than a look: developing the last photograph (docs/DESIGN.md
		-- section 4) has to happen somewhere no daylight and no moonlight reaches,
		-- and a windowless room is also the only place on the ground floor a kill
		-- cannot be witnessed through glass. It gets NO entry in PLAN.Windows and
		-- must never be given one.
		purpose = "Off the Kitchen. Windowless - see the comment above; this is load-bearing, not decoration.",
	},
	{
		name = "DiningHall", floor = "Ground",
		rects = { {22, 56, 58, 84} },
		purpose = "East wing, off the Foyer. The long table room; connects the Kitchen and the Conservatory.",
	},
	{
		name = "Conservatory", floor = "Ground", glassWalls = true, ceiling = false,
		rects = { {58, 54, 88, 84} },
		purpose = "East glass wing off the Dining Hall. Brass-mullioned glass walls and a glass pitched roof - the one room lit by the sky, so the one room where being seen is unavoidable.",
	},

	-- ---------- CELLAR (under the east half) ----------
	{
		name = "CellarHall", floor = "Cellar",
		-- Two rects, one room: the E-W spine (reaching west to X=-22 to sit under
		-- StairHall) plus the alcove the west flight descends through. The alcove
		-- is part of the hall rather than a separate room so the builder leaves
		-- them open to each other and the flight crosses no wall on its way down.
		rects = { {-22, 30, 72, 44}, {-22, 44, -6, 56} },
		purpose = "The low cellar spine. Its west alcove receives the west flight; the east flight arrives through CellarLandingEast.",
	},
	{
		name = "CellarLandingEast", floor = "Cellar",
		-- Widened east to X=44 so it contains the WHOLE east shaft. That matters:
		-- if a shaft straddles two cellar rooms, the interior wall between them
		-- runs straight through the middle of the flight.
		rects = { {18, 44, 44, 62} },
		purpose = "Arrival room at the foot of the east flight, doored through to the Cellar Hall. Floor south of the shaft is the landing.",
	},
	{
		name = "WineCellar", floor = "Cellar",
		rects = { {6, 2, 34, 30} },
		purpose = "North of the hall. Racks and a task site next prompt.",
	},
	{
		name = "UtilityRoom", floor = "Cellar",
		rects = { {34, 2, 66, 30} },
		purpose = "North of the hall, east end. The manor's vents and services - the incense-routing task lives down here.",
	},
	{
		name = "BoilerRoom", floor = "Cellar",
		rects = { {-6, 44, 18, 72} },
		purpose = "South of the hall. Manifestation (the critical sabotage) is themed here; its two warding stations land next prompt.",
	},
	{
		name = "Cistern", floor = "Cellar",
		-- West edge pulled back to X=44 to clear the widened CellarLandingEast.
		rects = { {44, 44, 72, 72} },
		purpose = "South of the hall, east end. Standing water; the draw-water stage of the consecration task chain.",
	},
}

-- ------------------------------------------------------------
-- DOORS. Explicit adjacency pairs; the builder finds the shared wall plane
-- itself, takes the overlap, and centers a DoorWidth opening in it. If a pair
-- is listed whose rooms do not actually share a wall, Build() reports it rather
-- than silently producing a sealed room - that is the main way a plan edit goes
-- wrong, so it is checked rather than trusted.
-- ------------------------------------------------------------
PLAN.Doors = {
	{ "GrandFoyer", "GreatHall" },
	{ "GrandFoyer", "Gallery" },
	{ "GrandFoyer", "DiningHall" },
	{ "GrandFoyer", "MusicRoom" },
	{ "GreatHall", "SeanceParlor" },
	{ "GreatHall", "StairHall" },
	{ "Kitchen", "ServiceStair" },
	{ "Gallery", "Library" },
	{ "Gallery", "Study" },
	{ "Gallery", "Chapel" },
	{ "Library", "Study" },
	{ "DiningHall", "Kitchen" },
	{ "Kitchen", "Darkroom" },
	{ "DiningHall", "Conservatory" },
	-- Every cellar room opens onto the hall and nothing else. The cellar is a
	-- hub-and-spoke, so there is exactly one way in and out of each vault.
	{ "CellarHall", "CellarLandingEast" },
	{ "CellarHall", "WineCellar" },
	{ "CellarHall", "UtilityRoom" },
	{ "CellarHall", "BoilerRoom" },
	{ "CellarHall", "Cistern" },
}

-- ------------------------------------------------------------
-- STAIRS. Real walkable stepped parts inside an enclosed stairwell, not a ramp
-- and not a teleport.
--
-- *** ORIENTATION IS DERIVED. THERE IS NO SHAFT RECT AND NO DESCEND DIRECTION
-- IN THIS TABLE ANY MORE, AND NEITHER MAY COME BACK. ***
--
-- Both used to be hand-written here, and a hand-written orientation is a
-- hand-written chance to point the assembly at a wall - which is what the
-- ServiceStair did. Its shaft sat two studs from the Kitchen doorway, so opening
-- that door put you nose-first against the shaft's long guard rail: the whole
-- stairwell presented its side to the only way in, and the room read as a wall of
-- brass with something hidden behind it.
--
-- ONE RULE, AND IT IS GEOMETRIC. Let D be the unit vector pointing from the
-- room's DOORWAY into the room, perpendicular to the doorway's wall. THE FLIGHT
-- DESCENDS ALONG D. You walk through the door and you are facing straight down
-- the stairs; there is no turn, no landing to cross, and nothing to interpret.
--
-- An intermediate revision had the flight running PARALLEL to the doorway wall
-- with a landing in front of it, and shipped: that arrangement satisfies every
-- reasonable-sounding description of a well-placed stair - the head is near the
-- door, there is floor to step onto, the flight is contained - while still
-- presenting its long side to the only way in. The rule is stated as a vector
-- equality now precisely so that no phrasing of it can be satisfied by a stair
-- pointing the wrong way.
--
-- deriveStairs() computes the whole assembly from D plus the room's rect: shaft,
-- head landing, tread count, enclosure, railings, and the bottom doorway. The
-- foot stops DIM.StairExitClear short of wherever the DESTINATION cellar room
-- runs out, and that clearance IS the bottom doorway - the flight arrives and you
-- keep walking the same way into the cellar. Move a door and the stair turns to
-- meet it. checkStairs() then measures the built result back against D.
-- ------------------------------------------------------------
-- `room` NAMES THE GROUND ROOM THE SHAFT MUST LIE INSIDE, and it is checked.
-- An earlier revision had no such field: the east flight simply declared
-- `from = "Kitchen"` and cut its shaft straight through the Kitchen floor, and
-- nothing in the builder objected.
PLAN.Stairs = {
	{
		name = "HallStair", room = "StairHall", to = "CellarHall",
		purpose = "The west flight, entirely inside StairHall, off the Great Hall's east door.",
	},
	{
		name = "ServiceStair", room = "ServiceStair", to = "CellarLandingEast",
		purpose = "The east flight, entirely inside ServiceStair, off the Kitchen's west door.",
	},
}

-- ------------------------------------------------------------
-- WINDOWS. Tall narrow openings with a brass arch strip, a tinted pane, and a
-- dim blue SurfaceLight on the inside face.
--
-- THE MOONLIGHT IS A PLACEHOLDER AND A MOOD LAYER, NOT A LIGHTING SOLUTION.
-- Brightness 0.35 exists so the shell is not pitch black to walk through during
-- review. The manor's actual interior light is the RoomLamps next prompt (which
-- LightsSystem then kills on a Snuffing sabotage); the art pass replaces these
-- SurfaceLights outright. Do not tune gameplay visibility against them.
--
-- `sides` names the faces to TRY. The builder silently skips any side that
-- resolves to an interior wall in the current plan, so listing a side costs
-- nothing if the geometry does not offer it.
--
-- REGULARIZED AFTER THE SHELL REVIEW. There is no longer a per-room `count`,
-- and that removal IS the fix. A count had to be shared out across whatever
-- exterior spans a room happened to have, longest first, which is what produced
-- the Parlor's cluster of windows jammed into one corner while the rest of the
-- facade stayed blank. Spacing is now derived from each WALL, not from the room:
-- every exterior run gets windows of one size at one rhythm (see DIM.WindowPitch
-- and DIM.WindowCornerMargin), so two walls of the same length always come out
-- identical no matter which rooms they belong to. Adding a side here can only
-- ever add a regularly-spaced run of windows.
-- ------------------------------------------------------------
PLAN.Windows = {
	{ room = "SeanceParlor", sides = { "North", "East", "West" } },
	{ room = "DiningHall",   sides = { "North", "East", "South" } },
	{ room = "Library",      sides = { "North", "East", "West" } },
	{ room = "Chapel",       sides = { "North", "East", "West" } },
	-- The four rooms above are the brief's list. The rest carry the same
	-- treatment onto the faces the manor actually presents outward, so the west
	-- and south elevations are not blank; delete a line to strip a facade.
	{ room = "Study",      sides = { "West", "South" } },
	{ room = "MusicRoom",  sides = { "West", "South" } },
	{ room = "GrandFoyer", sides = { "South", "East", "West" } },
	{ room = "Gallery",    sides = { "West" } },
	-- Darkroom is absent and must stay absent - see its room entry.
}

-- ------------------------------------------------------------
-- FURNISH - per-room prop data, interpreted by the KITS library in the builder.
-- Each entry: { kit = "<name in KITS>", room = "<PLAN.Rooms name>", at = {x, z},
-- ... }, plus whatever fields that kit reads (len, along, face, count...).
--
-- `at` is a WORLD X,Z; the kit supplies the Y from the room's floor. `face` is a
-- compass letter for props that lean on a wall - the direction the prop projects
-- INTO the room ("N" = -Z, "S" = +Z, "E" = +X, "W" = -X, the file's convention).
--
-- TWO RULES THIS TABLE MUST KEEP, because nothing enforces them:
--   1. NOTHING IN A DOORWAY. Doors are 8 wide and centered in the widest overlap
--      between two rooms (see findSharedWall), so a prop within ~5 studs of a
--      shared-wall midpoint will be standing in the opening.
--   2. CIRCULATION STAYS GENEROUS. This is a chase map before it is a set: props
--      hug walls, and the middle of every room and every corridor is left open.
--      A room that reads beautifully and plays like a maze is a failed room.
-- ------------------------------------------------------------
PLAN.Furnish = {
	-- ---------- GrandFoyer: arrival. Rug, coat stand, side tables. ----------
	{ kit = "Rug",       room = "GrandFoyer", at = {0, 73}, sx = 22, sz = 16 },
	{ kit = "CoatStand", room = "GrandFoyer", at = {-16, 87} },
	{ kit = "CoatStand", room = "GrandFoyer", at = {16, 87} },
	{ kit = "SideTable", room = "GrandFoyer", at = {-19, 71}, face = "E" },
	{ kit = "SideTable", room = "GrandFoyer", at = {19, 86}, face = "W" },

	-- ---------- GreatHall: the spine. Console tables only - it is a corridor. --
	{ kit = "SideTable", room = "GreatHall", at = {-5.5, -14}, face = "E" },
	{ kit = "SideTable", room = "GreatHall", at = {5.5, 8}, face = "W" },
	{ kit = "SideTable", room = "GreatHall", at = {-5.5, 30}, face = "E" },

	-- ---------- SeanceParlor: EMPTY BY DESIGN. ----------
	-- The ritual heart is built by buildRitual(), not from this table, and nothing
	-- else may stand in this room. DESIGN.md section 4 wants the circle composed
	-- into OPEN FLOOR; the moment a sideboard lands here the Convergence becomes a
	-- game of furniture. Do not add an entry for SeanceParlor.

	-- ---------- Gallery: the portrait run. ----------
	-- COMPUTED, not listed. Twelve hand-placed frames put pictures over windows and
	-- doorways because nobody cross-checked the coordinates against PLAN.Windows
	-- and PLAN.Doors. PortraitRun subtracts every opening on the wall from the run
	-- and spaces what survives evenly - see the WALL RUNS comment in the kits.
	{ kit = "PortraitRun", room = "Gallery", wall = "X", coord = -36, from = -76, to = 70, face = "E", pitch = 12 },
	-- East wall of the west leg. ONLY over Z=-76..-26: north of that the Gallery's
	-- two rects meet and there is no wall to hang on.
	{ kit = "PortraitRun", room = "Gallery", wall = "X", coord = -22, from = -76, to = -26, face = "W", pitch = 12 },
	{ kit = "SideTable", room = "Gallery", at = {-34, 50}, face = "E" },

	-- ---------- StairHall ----------
	-- Against the south wall, clear of the derived shaft and its enclosure. The
	-- flight now runs east-west across this room, so the only floor left for
	-- furniture is the strip behind it.
	{ kit = "SideTable", room = "StairHall", at = {-13.5, 54}, face = "N" },

	-- ---------- Chapel: pews facing the altar. ----------
	{ kit = "Altar", room = "Chapel", at = {-51, -73} },
	{ kit = "PewRow", room = "Chapel", at = {-51, -66}, len = 18 },
	{ kit = "PewRow", room = "Chapel", at = {-51, -62}, len = 18 },
	{ kit = "PewRow", room = "Chapel", at = {-51, -50}, len = 18 },
	{ kit = "PewRow", room = "Chapel", at = {-51, -46}, len = 18 },

	-- ---------- Library: shelving on every wall the windows leave alone. ------
	-- `face` is the way the OPEN FRONT of a case looks, which is what decides which
	-- side its back panel goes on. Get it wrong and the books are inside the wall.
	--
	-- RE-LAID SO NO TWO RUNS TOUCH. The north wall carried four separate units -
	-- two bookshelf runs, the secret bookcase and the SortStow station - laid out
	-- by eye, and three of them overlapped: the station grew through the run beside
	-- it and through the secret section on its other side. The wall is now divided
	-- explicitly, every unit stops DIM.ShelfCornerInset short of a corner, and
	-- there is a clear stud between neighbours. The station and the secret bookcase
	-- own their slots in this layout; move one and you must move the others.
	--   NORTH WALL Z=-40, usable X -65..-37:
	--     -64..-56  Bookshelves       -55..-50  SecretBookcase (PLAN.Secrets)
	--     -49..-44  Bookshelves       -43..-37  SortStow station (PLAN.Stations)
	{ kit = "Bookshelves", room = "Library", at = {-60, -39}, along = "X", len = 8, face = "S" },
	{ kit = "Bookshelves", room = "Library", at = {-46.5, -39}, along = "X", len = 5, face = "S" },
	{ kit = "Bookshelves", room = "Library", at = {-37, -34}, along = "Z", len = 8, face = "W" },
	{ kit = "Bookshelves", room = "Library", at = {-37, -16}, along = "Z", len = 8, face = "W" },
	{ kit = "Bookshelves", room = "Library", at = {-58, -11}, along = "X", len = 8, face = "N" },
	{ kit = "Desk", room = "Library", at = {-60, -30}, face = "E" },
	{ kit = "Desk", room = "Library", at = {-60, -20}, face = "E" },

	-- ---------- Study: the clock room. ----------
	{ kit = "Desk", room = "Study", at = {-46, 4}, face = "N" },
	-- Both runs pulled a stud clear of the Gallery doorway at Z=-2..6, which the
	-- longer versions overlapped by a stud and half a stud respectively.
	{ kit = "Bookshelves", room = "Study", at = {-37, -6}, along = "Z", len = 6, face = "W" },
	{ kit = "Bookshelves", room = "Study", at = {-37, 10}, along = "Z", len = 6, face = "W" },
	{ kit = "SideTable", room = "Study", at = {-60, -7}, face = "S" },

	-- ---------- MusicRoom ----------
	{ kit = "SideTable", room = "MusicRoom", at = {-41, 87}, face = "E" },
	{ kit = "Chair", room = "MusicRoom", at = {-27, 84}, yaw = math.pi },

	-- ---------- Kitchen: counters, the wall shelf, and the centre pendant. ----
	-- The back-wall counter used to run X=17..31 while the Darkroom doorway on the
	-- same wall is X=11..19 - two studs of it stood in the opening. Pulled clear.
	-- The two runs also used to meet AT the north-east corner rather than stopping
	-- short of it, so their carcasses interpenetrated; and the east run overlapped
	-- the ServiceStair doorway at Z=44..52 by two studs.
	{ kit = "CounterRun", room = "Kitchen", at = {24.5, 33.5}, along = "X", len = 9 },
	{ kit = "CounterRun", room = "Kitchen", at = {31.5, 38}, along = "Z", len = 8 },
	-- The flush wall shelf, mounted on the back wall ABOVE the counter run and
	-- aligned to it - see KITS.WallShelf.
	{ kit = "WallShelf", room = "Kitchen", at = {24.5, 32}, face = "S", len = 8, y = 5 },
	{ kit = "HangingPendant", room = "Kitchen", at = {17, 46}, len = 9, clearance = 9.5 },
	{ kit = "SideTable", room = "Kitchen", at = {8.3, 52}, face = "E" },

	-- ---------- Darkroom: windowless, and the print line sells it. ----------
	{ kit = "PrintLine", room = "Darkroom", at = {15, 18}, len = 12 },
	{ kit = "SideTable", room = "Darkroom", at = {9, 29}, face = "E" },

	-- ---------- DiningHall: the long table. ----------
	{ kit = "DiningTable", room = "DiningHall", at = {40, 70}, len = 18, seats = 6 },

	-- ---------- Conservatory: beds, bench, and the bone-charm scatter. --------
	{ kit = "PlanterBed", room = "Conservatory", at = {78, 60}, along = "X", len = 16 },
	{ kit = "PlanterBed", room = "Conservatory", at = {78, 79}, along = "X", len = 16 },
	{ kit = "PlanterBed", room = "Conservatory", at = {85, 69.5}, along = "Z", len = 12 },
	{ kit = "PottingBench", room = "Conservatory", at = {63, 60}, face = "E" },
	-- Gathered onto the reliquary's plinth rather than scattered across the room -
	-- `at` and `plinthTop` match the Reliquary station entry exactly.
	{ kit = "BoneCluster", room = "Conservatory", at = {68, 70}, spread = 3.4, count = 9, plinth = 1.6, plinthTop = 2.2 },

	-- ---------- CELLAR ----------
	-- ONE WALL of racks, the fuller run against the north wall. There were three
	-- runs: this one, a second parallel run stranded seven studs out in the middle
	-- of the floor, and a third on the west wall. A cellar with racks on every
	-- surface reads as storage rather than as a room you can be cornered in.
	{ kit = "WineRack", room = "WineCellar", at = {20, 4.5}, along = "X", len = 22 },
	{ kit = "Crates", room = "WineCellar", at = {28, 24}, count = 4 },

	{ kit = "Shelving", room = "UtilityRoom", at = {50, 4}, along = "X", len = 20 },
	{ kit = "Shelving", room = "UtilityRoom", at = {64, 18}, along = "Z", len = 18 },
	{ kit = "Crates", room = "UtilityRoom", at = {40, 25}, count = 6 },

	{ kit = "Boiler", room = "BoilerRoom", at = {12, 51} },
	-- ONE ASSEMBLY with the FlowRoute station: this `at`/`face` and the station's
	-- must match, or the panel hangs off the end of the run it is plumbed into.
	{ kit = "PipeWall", room = "BoilerRoom", at = {-6, 58}, face = "E", len = 22 },
	{ kit = "Crates", room = "BoilerRoom", at = {13, 68}, count = 3 },

	{ kit = "CisternBasin", room = "Cistern", at = {59, 59}, sx = 20, sz = 20 },

	{ kit = "Crates", room = "CellarHall", at = {66, 37}, count = 3 },
	{ kit = "Crates", room = "CellarLandingEast", at = {24, 58}, count = 3 },
}

-- ------------------------------------------------------------
-- STATIONS - the ten authored tasks as DIEGETIC OBJECTS (docs/DESIGN.md section
-- 4: "location is identity"). One per room; the object a player walks up to IS
-- the task.
--
-- CONTRACT, read out of TaskStationHandler.server.lua - all four are required:
--   * the part's NAME is the task id (TaskManager.RegisterTaskId(part.Name, ...)),
--     so names must be unique map-wide or two stations silently become one task;
--   * a TaskType attribute naming a key in TaskDefs.Types (a missing one falls
--     back to Generic and warns);
--   * the TaskStation tag;
--   * a ProximityPrompt child. The HANDLER owns its style, ActionText,
--     HoldDuration and ClickablePrompt - this file must not set them, or the map
--     and the runtime will disagree about the prompt the moment either changes.
--
-- `kit` builds the object and returns the part that carries the contract, so a
-- station is never a floating cube next to the thing it represents.
-- ------------------------------------------------------------
PLAN.Stations = {
	{ name = "WireSplice",    taskType = "WireSplice",    room = "Chapel",       kit = "StainedGlassFrame", at = {-66, -58}, face = "E" },
	{ name = "DialMatch",     taskType = "DialMatch",     room = "Study",        kit = "GrandfatherClock",  at = {-58, -10}, face = "S" },
	{ name = "HoldFill",      taskType = "HoldFill",      room = "Darkroom",     kit = "DevelopingBench",   at = {23, 22},   face = "W" },
	{ name = "EchoCode",      taskType = "EchoCode",      room = "MusicRoom",    kit = "Piano",             at = {-34, 77},  face = "E" },
	{ name = "ScrubDown",     taskType = "ScrubDown",     room = "DiningHall",   kit = "SilverCabinet",     at = {22, 80},   face = "E" },
	-- Clear of every planter bed, standing on its own plinth on open floor.
	{ name = "SpotCheck",     taskType = "SpotCheck",     room = "Conservatory", kit = "Reliquary",         at = {68, 70},   face = "W" },
	-- SAME `at` AND `face` AS THE PipeWall FURNISH ENTRY - that is what makes the
	-- panel land centred on the run instead of three studs past its end.
	{ name = "FlowRoute",     taskType = "FlowRoute",     room = "BoilerRoom",   kit = "PipeManifold",      at = {-6, 58},   face = "E" },
	{ name = "SliderSync",    taskType = "SliderSync",    room = "Gallery",      kit = "GasValvePanel",     at = {-36, -34}, face = "E" },
	{ name = "PrecisionPins", taskType = "PrecisionPins", room = "GrandFoyer",   kit = "Strongbox",         at = {22, 60},   face = "W" },
	-- Owns X -43..-37 in the Library's north-wall layout; see PLAN.Furnish.
	{ name = "SortStow",      taskType = "SortStow",      room = "Library",      kit = "SortingShelf",      at = {-40, -40}, face = "S" },
}

-- ------------------------------------------------------------
-- SABOTAGE STATIONS - the fix points, same diegetic treatment.
--
-- CONTRACT, read out of SabotageStationHandler.server.lua: the SabotageStation
-- tag, a SabotageType attribute ("Lights" or "Boiler"), a FixId attribute that
-- must be one of the RESERVED keys in SabotageService's Sabotages table
-- ("Sabotage:Lights", "Sabotage:Boiler1", "Sabotage:Boiler2"), and a
-- ProximityPrompt child. A typo in FixId is not a soft failure: RegisterFixStation
-- rejects it and the station silently never appears during a sabotage.
--
-- The handler starts every prompt DISABLED and enables it only while that
-- sabotage is live - the prompt appearing IS the "go fix this" signal - so these
-- correctly look inert in an empty Studio session.
--
-- Manifestation (the critical Boiler sabotage) needs BOTH its stations, and they
-- are deliberately far apart: the boiler itself and the cistern across the cellar.
-- ------------------------------------------------------------
PLAN.Sabotage = {
	{ name = "FuseBox",      sabotageType = "Lights", fixId = "Sabotage:Lights",  room = "UtilityRoom", kit = "FuseBox",     at = {34, 10}, face = "E" },
	{ name = "BoilerValve1", sabotageType = "Boiler", fixId = "Sabotage:Boiler1", room = "BoilerRoom",  kit = "ValveWheel",  at = {12, 46.5}, face = "S" },
	{ name = "BoilerValve2", sabotageType = "Boiler", fixId = "Sabotage:Boiler2", room = "Cistern",     kit = "ValveWheel",  at = {47, 47}, face = "S" },
}

-- ------------------------------------------------------------
-- LAMPS - the diegetic half of the darkness system.
--
-- CONTRACT, read out of LightsSystem.lua: a Part tagged RoomLamp is recolored
-- dark and made SmoothPlastic while the lights are out, and EVERY descendant
-- PointLight/SpotLight/SurfaceLight is switched off. So THE TAG GOES ON THE BULB,
-- not on the fixture: tag a brass ring and the ring goes dark while six neon
-- bulbs hanging off it keep glowing. One chandelier is therefore N lamps, which
-- is why the manifest reports a lamp COUNT rather than an expected number.
--
-- LightsSystem also captures each PointLight's Brightness the first time it
-- touches the lamp and treats it as the base the Entity's Rage scales down, so
-- the DIM.*Bright values are what Rage erodes - see DIM's lamp tuning note.
-- ------------------------------------------------------------
PLAN.Lamps = {
	-- Chandeliers: the four rooms with the ceiling height to carry one, plus the
	-- Parlor's pair flanking the circle (never over it - the braziers own that
	-- light, and a chandelier above the séance table would flatten the whole set).
	{ kit = "Chandelier", room = "SeanceParlor", at = {0, -60}, bulbs = 6 },
	{ kit = "Chandelier", room = "SeanceParlor", at = {0, -36}, bulbs = 6 },
	{ kit = "Chandelier", room = "GrandFoyer",   at = {0, 73},  bulbs = 6 },
	{ kit = "Chandelier", room = "DiningHall",   at = {40, 70}, bulbs = 4 },
	{ kit = "Chandelier", room = "Library",      at = {-54, -25}, bulbs = 4 },

	-- Sconces: `at` is ON the wall plane, `face` is the way the bracket reaches
	-- into the room.
	{ kit = "Sconce", room = "SeanceParlor", at = {-22, -60}, face = "E" },
	{ kit = "Sconce", room = "SeanceParlor", at = {-22, -36}, face = "E" },
	{ kit = "Sconce", room = "SeanceParlor", at = {22, -42},  face = "W" },
	{ kit = "Sconce", room = "GrandFoyer",   at = {-22, 71},  face = "E" },
	{ kit = "Sconce", room = "GrandFoyer",   at = {22, 60},   face = "W" },
	-- CORRIDORS GET RUNS, NOT LISTS, and the runs ALTERNATE WALLS. A run names both
	-- of a corridor's long walls and hands positions to them in turn, so the light
	-- comes from one side then the other and the space between reads as depth. A
	-- position whose turn falls on a wall that is not there, or that has a doorway
	-- or window at that point, goes to the opposite wall instead - see
	-- KITS.SconceRun, which reads the wall pass's own record of what it built.
	--
	-- The Gallery spur has only ONE long wall: its west side is where the Gallery's
	-- two rects meet, and nothing is built there. Its run alternates onto nothing
	-- and falls back every time, which is the correct answer rather than a
	-- special case.
	{ kit = "SconceRun", room = "GreatHall", wall = "X", from = -26, to = 56,
		walls = { { coord = -7, face = "E" }, { coord = 7, face = "W" } } },
	{ kit = "SconceRun", room = "Gallery", wall = "X", from = -76, to = 70,
		walls = { { coord = -36, face = "E" }, { coord = -22, face = "W" } } },
	{ kit = "SconceRun", room = "Gallery", wall = "X", from = -26, to = 40,
		walls = { { coord = -7, face = "W" }, { coord = -22, face = "E" } } },
	{ kit = "Sconce", room = "StairHall",    at = {-7, 42},   face = "W" },
	{ kit = "Sconce", room = "StairHall",    at = {-22, 54},  face = "E" },
	{ kit = "Sconce", room = "Chapel",       at = {-66, -70}, face = "E" },
	{ kit = "Sconce", room = "Chapel",       at = {-66, -46}, face = "E" },
	{ kit = "Sconce", room = "Chapel",       at = {-36, -46}, face = "W" },
	-- The Library's and Study's east walls are wall-to-wall bookcases at 8 studs, so
	-- their sconces move to the walls that are not shelved rather than being buried
	-- in a shelf top.
	{ kit = "Sconce", room = "Library",      at = {-66, -10}, face = "N" },
	{ kit = "Sconce", room = "Library",      at = {-40, -10}, face = "N" },
	{ kit = "Sconce", room = "Study",        at = {-62, -6},  face = "E" },
	{ kit = "Sconce", room = "Study",        at = {-42, -10}, face = "S" },
	{ kit = "Sconce", room = "MusicRoom",    at = {-22, 74},  face = "W" },
	{ kit = "Sconce", room = "MusicRoom",    at = {-22, 86},  face = "W" },
	{ kit = "Sconce", room = "Kitchen",      at = {7, 38},    face = "E" },
	{ kit = "Sconce", room = "Kitchen",      at = {7, 52},    face = "E" },
	{ kit = "Sconce", room = "ServiceStair", at = {45, 44},   face = "W" },
	{ kit = "Sconce", room = "Darkroom",     at = {7, 20},    face = "E" },
	{ kit = "Sconce", room = "DiningHall",   at = {22, 60},   face = "E" },
	{ kit = "Sconce", room = "DiningHall",   at = {58, 78},   face = "W" },
	{ kit = "Sconce", room = "Conservatory", at = {58, 62},   face = "E" },
	{ kit = "Sconce", room = "Conservatory", at = {58, 78},   face = "E" },
	-- The glass wing had two sconces on the ONE wall it shares with the house and
	-- nothing else, so most of it was lit by spill through the Dining Hall door.
	-- Two lanterns of its own, clear of every planter bed and the potting bench.
	{ kit = "HangingLantern", room = "Conservatory", at = {66, 62} },
	{ kit = "HangingLantern", room = "Conservatory", at = {80, 70} },

	-- Cellar: one bare bulb on a cord per space. The change in fixture is the same
	-- trick as the change in wall treatment - you know you left the house.
	-- Clear of the derived HallStair shaft and its enclosure walls: a bulb hung
	-- further west would be inside the stairwell, level with a tread.
	{ kit = "BareBulb", room = "CellarHall", at = {-8, 50} },
	-- THE CELLAR SPINE IS A CORRIDOR TOO - 94 studs of it - and it had four bulbs
	-- on it, leaving thirty-stud runs of black between them. checkManifest derives
	-- corridors by aspect ratio, so this rect is measured against the same
	-- DIM.SconceMaxGap as the Gallery; these eight sit inside it with room to
	-- spare. They are individual entries rather than a run because the cellar's
	-- fixture hangs from the ceiling, not off a wall.
	{ kit = "BareBulb", room = "CellarHall", at = {-16, 37} },
	{ kit = "BareBulb", room = "CellarHall", at = {-4, 37} },
	{ kit = "BareBulb", room = "CellarHall", at = {8, 37} },
	{ kit = "BareBulb", room = "CellarHall", at = {20, 37} },
	{ kit = "BareBulb", room = "CellarHall", at = {32, 37} },
	{ kit = "BareBulb", room = "CellarHall", at = {43, 37} },
	{ kit = "BareBulb", room = "CellarHall", at = {55, 37} },
	{ kit = "BareBulb", room = "CellarHall", at = {67, 37} },
	{ kit = "BareBulb", room = "CellarLandingEast", at = {31, 53} },
	{ kit = "BareBulb", room = "WineCellar", at = {20, 17} },
	{ kit = "BareBulb", room = "UtilityRoom", at = {50, 16} },
	{ kit = "BareBulb", room = "BoilerRoom", at = {4, 60} },
	{ kit = "BareBulb", room = "Cistern", at = {58, 58} },
}

-- ------------------------------------------------------------
-- SECRET PASSAGES - RESERVATIONS ONLY. READ THIS BEFORE WIRING ANYTHING TO THEM.
--
-- *** THERE IS NO MECHANISM HERE AND THERE IS NOT MEANT TO BE ONE YET. ***
-- These two parts are sealed set dressing: a Library bookcase section standing
-- slightly proud of its run with a visible seam down one side, and a Chapel wall
-- panel doing the same. They do not open, they do not teleport, they are not
-- doors, and NOTHING in the running game reads the SecretPassage tag or the
-- RouteId attribute today - grep before you assume otherwise.
--
-- THE HINT IS DELIBERATE. Placing them now costs nothing and means the vents /
-- passages phase inherits two authored locations that already read as "something
-- is behind this wall" instead of picking spots after the art pass has frozen the
-- geometry. When that phase lands, RouteId is the handle that pairs an entrance
-- to an exit; until then a player who notices the seam is being correctly teased.
-- ------------------------------------------------------------
PLAN.Secrets = {
	-- Owns X -55..-50 in the Library's north-wall layout; see PLAN.Furnish.
	{ name = "SecretBookcase", routeId = "Route1", room = "Library", kit = "SecretBookcase", at = {-52.5, -40}, face = "S" },
	{ name = "SecretPanel",    routeId = "Route2", room = "Chapel",  kit = "SecretPanel",    at = {-36, -70}, face = "W" },
}

-- ============================================================
-- ============================================================
-- BUILDER - the interpreter. Nothing below encodes a design decision; it
-- encodes the maths that turns the tables above into parts.
-- ============================================================
-- ============================================================

local EPS = 1e-4

-- ------------------------------------------------------------
-- 1-D span algebra. Spans are {a, b} with a < b. Used for two things that turn
-- out to be the same problem: deciding which stretch of a wall plane needs a
-- wall, and cutting doorways and windows out of it.
-- ------------------------------------------------------------
local function mergeSpans(spans)
	local sorted = table.clone(spans)
	table.sort(sorted, function(a, b)
		return a[1] < b[1]
	end)
	local out = {}
	for _, span in ipairs(sorted) do
		local last = out[#out]
		if last and span[1] <= last[2] + EPS then
			if span[2] > last[2] then
				last[2] = span[2]
			end
		else
			table.insert(out, { span[1], span[2] })
		end
	end
	return out
end

local function subtractSpans(base, cuts)
	local result = {}
	for _, b in ipairs(base) do
		local pieces = { { b[1], b[2] } }
		for _, cut in ipairs(cuts) do
			local remaining = {}
			for _, piece in ipairs(pieces) do
				if cut[2] <= piece[1] + EPS or cut[1] >= piece[2] - EPS then
					table.insert(remaining, piece)
				else
					if cut[1] > piece[1] + EPS then
						table.insert(remaining, { piece[1], cut[1] })
					end
					if cut[2] < piece[2] - EPS then
						table.insert(remaining, { cut[2], piece[2] })
					end
				end
			end
			pieces = remaining
		end
		for _, piece in ipairs(pieces) do
			if piece[2] - piece[1] > EPS then
				table.insert(result, piece)
			end
		end
	end
	return result
end

local function spanOverlap(a, b)
	local lo, hi = math.max(a[1], b[1]), math.min(a[2], b[2])
	if hi - lo > EPS then
		return { lo, hi }
	end
	return nil
end

local function intersectSpans(base, others)
	local out = {}
	for _, b in ipairs(base) do
		for _, o in ipairs(others) do
			local overlap = spanOverlap(b, o)
			if overlap then
				table.insert(out, overlap)
			end
		end
	end
	return mergeSpans(out)
end

local function spansContain(spans, value)
	for _, span in ipairs(spans) do
		if value >= span[1] - EPS and value <= span[2] + EPS then
			return true
		end
	end
	return false
end

-- ------------------------------------------------------------
-- 2-D rect algebra, rects being {x1, z1, x2, z2}. The floor pass needs it: the
-- cellar's ceiling IS the ground floor over the east half, so a ground room's
-- slab has to be its footprint MINUS whatever cellar lies beneath it, and the
-- cellar's lid has to be split into the piece that shows as a room floor and
-- the piece that is a buried vault top.
-- ------------------------------------------------------------
local function rectIntersect(a, b)
	local x1, z1 = math.max(a[1], b[1]), math.max(a[2], b[2])
	local x2, z2 = math.min(a[3], b[3]), math.min(a[4], b[4])
	if x2 - x1 > EPS and z2 - z1 > EPS then
		return { x1, z1, x2, z2 }
	end
	return nil
end

-- Splits `rect` around `cut` into at most four pieces (band above, band below,
-- then the two side slivers of the middle band). Never returns overlapping
-- pieces, which is what keeps the floor pass from double-emitting slabs.
local function rectSubtract(rect, cut)
	local inner = rectIntersect(rect, cut)
	if not inner then
		return { rect }
	end
	local out = {}
	if inner[2] - rect[2] > EPS then
		table.insert(out, { rect[1], rect[2], rect[3], inner[2] })
	end
	if rect[4] - inner[4] > EPS then
		table.insert(out, { rect[1], inner[4], rect[3], rect[4] })
	end
	if inner[1] - rect[1] > EPS then
		table.insert(out, { rect[1], inner[2], inner[1], inner[4] })
	end
	if rect[3] - inner[3] > EPS then
		table.insert(out, { inner[3], inner[2], rect[3], inner[4] })
	end
	return out
end

local function rectSubtractMany(rects, cuts)
	local current = rects
	for _, cut in ipairs(cuts) do
		local remaining = {}
		for _, rect in ipairs(current) do
			for _, piece in ipairs(rectSubtract(rect, cut)) do
				table.insert(remaining, piece)
			end
		end
		current = remaining
	end
	return current
end

-- ------------------------------------------------------------
-- Part factory. Every part this tool makes goes through here, so "all parts
-- Anchored" is a property of the factory rather than a rule to remember.
-- ------------------------------------------------------------
-- Reset at the top of every Build(); declared here because the factory below
-- increments it and the summary at the end reads it.
local counters = { parts = 0, doors = 0, windows = 0, stairs = 0, lights = 0 }

local function makePart(parent, name, size, cframe, mat, color, opts)
	opts = opts or {}
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Material = mat
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	-- Glass panes are SOLID: a window you can walk through is a hole in the map,
	-- and every sightline the design leans on assumes you can see but not pass.
	part.CanCollide = opts.canCollide ~= false
	part.Transparency = opts.transparency or 0
	part.Reflectance = opts.reflectance or 0
	part.CastShadow = opts.castShadow ~= false
	part.Parent = parent
	counters.parts = counters.parts + 1
	return part
end

-- Axis-aligned box from world bounds. Silently drops degenerate boxes so a
-- zero-width wall segment (a doorway that exactly fills its wall) is a no-op
-- rather than a 0-size part Studio will complain about.
local function box(parent, name, x1, y1, z1, x2, y2, z2, mat, color, opts)
	local sx, sy, sz = x2 - x1, y2 - y1, z2 - z1
	if sx <= EPS or sy <= EPS or sz <= EPS then
		return nil
	end
	return makePart(
		parent, name,
		Vector3.new(sx, sy, sz),
		CFrame.new((x1 + x2) / 2, (y1 + y2) / 2, (z1 + z2) / 2),
		mat, color, opts
	)
end

-- ------------------------------------------------------------
-- PLAN INDEX. Normalizes the approximate bounds in PLAN into the exact
-- structures the geometry passes read. Built fresh each Build().
-- ------------------------------------------------------------
local function floorBaseY(floorName)
	return floorName == "Cellar" and CELLAR_Y or GROUND_Y
end

local function roomHeight(room)
	if room.floor == "Cellar" then
		return DIM.CellarWallHeight
	end
	return room.doubleHeight and DIM.DoubleHeight or DIM.WallHeight
end

-- Which sides of a plane a rect sits on:
--   plane X = x1 -> the rect is on the UPPER side (x greater than the plane)
--   plane X = x2 -> the rect is on the LOWER side
-- Same for Z. This is the whole trick behind shared-wall dedupe: a wall exists
-- wherever a plane has an occupant on either side, EXCEPT where both occupants
-- are the same room (an L-shaped room's internal seam).
local function buildPlanes(rectsByFloor)
	local planes = {}
	for floorName, entries in pairs(rectsByFloor) do
		local floorPlanes = { X = {}, Z = {} }
		local function record(axis, coord, side, span, room)
			local byCoord = floorPlanes[axis]
			byCoord[coord] = byCoord[coord] or { lower = {}, upper = {} }
			table.insert(byCoord[coord][side], { span = span, room = room })
		end
		for _, entry in ipairs(entries) do
			local r, room = entry.rect, entry.room
			record("X", r[1], "upper", { r[2], r[4] }, room)
			record("X", r[3], "lower", { r[2], r[4] }, room)
			record("Z", r[2], "upper", { r[1], r[3] }, room)
			record("Z", r[4], "lower", { r[1], r[3] }, room)
		end
		planes[floorName] = floorPlanes
	end
	return planes
end

-- The spans on one plane that need a wall built, and the spans that must NOT
-- get one because the same room is on both sides.
local function planeWallSpans(plane)
	local all, same = {}, {}
	for _, entry in ipairs(plane.lower) do
		table.insert(all, entry.span)
	end
	for _, entry in ipairs(plane.upper) do
		table.insert(all, entry.span)
	end
	for _, low in ipairs(plane.lower) do
		for _, up in ipairs(plane.upper) do
			if low.room == up.room then
				local overlap = spanOverlap(low.span, up.span)
				if overlap then
					table.insert(same, overlap)
				end
			end
		end
	end
	local sameMerged = mergeSpans(same)
	return subtractSpans(mergeSpans(all), sameMerged), sameMerged
end

-- Every coordinate at which the occupancy of a plane can change. A wall span
-- must be cut at these before anything is emitted: one continuous stretch of
-- wall can front SEVERAL different rooms along its length (the west wall at
-- X=-22 runs past the Gallery, then open air, then the Foyer), and each stretch
-- needs its own height and its own owning folder. Without this split the
-- double-height Foyer would inherit a 14-stud wall from its shorter neighbour
-- and stand open above the wainscot line.
local function planeBreakpoints(plane)
	local points = {}
	for _, side in ipairs({ plane.lower, plane.upper }) do
		for _, entry in ipairs(side) do
			table.insert(points, entry.span[1])
			table.insert(points, entry.span[2])
		end
	end
	table.sort(points)
	return points
end

local function splitAtBreakpoints(spans, points)
	local out = {}
	for _, span in ipairs(spans) do
		local start = span[1]
		for _, point in ipairs(points) do
			if point > start + EPS and point < span[2] - EPS then
				table.insert(out, { start, point })
				start = point
			end
		end
		if span[2] - start > EPS then
			table.insert(out, { start, span[2] })
		end
	end
	return out
end

-- Rooms present on each side of a point on a plane, so a wall segment can be
-- filed under a room's folder and sized to the taller of its two neighbours.
local function roomsAt(plane, value)
	local lower, upper
	for _, entry in ipairs(plane.lower) do
		if value > entry.span[1] + EPS and value < entry.span[2] - EPS then
			lower = entry.room
		end
	end
	for _, entry in ipairs(plane.upper) do
		if value > entry.span[1] + EPS and value < entry.span[2] - EPS then
			upper = entry.room
		end
	end
	return lower, upper
end

-- ------------------------------------------------------------
-- EXTERIOR DETECTION. A room face is exterior wherever the far side of its
-- plane has no occupant. Used by the window pass (and reported by the perimeter
-- check), so "which walls face outside" is derived from the plan rather than
-- listed by hand and left to rot when a room moves.
-- ------------------------------------------------------------
local SIDE_SPEC = {
	North = { axis = "Z", edge = 2, mySide = "upper", farSide = "lower", insideDir = 1 },
	South = { axis = "Z", edge = 4, mySide = "lower", farSide = "upper", insideDir = -1 },
	West  = { axis = "X", edge = 1, mySide = "upper", farSide = "lower", insideDir = 1 },
	East  = { axis = "X", edge = 3, mySide = "lower", farSide = "upper", insideDir = -1 },
}

local function exteriorSpans(planes, room, sideName)
	local spec = SIDE_SPEC[sideName]
	local floorPlanes = planes[room.floor]
	local out = {}
	for _, rect in ipairs(room.rects) do
		local coord = rect[spec.edge]
		local span = (spec.axis == "Z") and { rect[1], rect[3] } or { rect[2], rect[4] }
		local plane = floorPlanes[spec.axis][coord]
		local blockers = {}
		if plane then
			for _, entry in ipairs(plane[spec.farSide]) do
				table.insert(blockers, entry.span)
			end
		end
		for _, piece in ipairs(subtractSpans({ span }, mergeSpans(blockers))) do
			table.insert(out, { coord = coord, span = piece, spec = spec })
		end
	end
	return out
end

-- ------------------------------------------------------------
-- OPENINGS. Doors and windows are the same record shape - a span on a plane
-- with a sill and a head - because the wall pass cuts around both identically.
-- ------------------------------------------------------------
local function addOpening(openings, floorName, axis, coord, a, b, record)
	local byFloor = openings[floorName]
	byFloor[axis][coord] = byFloor[axis][coord] or {}
	record.a, record.b = a, b
	table.insert(byFloor[axis][coord], record)
	return record
end

-- Finds the widest shared wall between two rooms and returns the plane it lies
-- on. Two rooms can touch on more than one plane (an L-shaped room wrapping a
-- square one); the widest contact is the one a door belongs in.
local function findSharedWall(roomA, roomB)
	local best
	local function consider(axis, coord, span)
		if span and (not best or (span[2] - span[1]) > (best.span[2] - best.span[1])) then
			best = { axis = axis, coord = coord, span = span }
		end
	end
	for _, a in ipairs(roomA.rects) do
		for _, b in ipairs(roomB.rects) do
			if math.abs(a[3] - b[1]) < EPS then
				consider("X", a[3], spanOverlap({ a[2], a[4] }, { b[2], b[4] }))
			end
			if math.abs(a[1] - b[3]) < EPS then
				consider("X", a[1], spanOverlap({ a[2], a[4] }, { b[2], b[4] }))
			end
			if math.abs(a[4] - b[2]) < EPS then
				consider("Z", a[4], spanOverlap({ a[1], a[3] }, { b[1], b[3] }))
			end
			if math.abs(a[2] - b[4]) < EPS then
				consider("Z", a[2], spanOverlap({ a[1], a[3] }, { b[1], b[3] }))
			end
		end
	end
	return best
end

-- ------------------------------------------------------------
-- WALL EMISSION. NO CSG ANYWHERE: openings are made by building the wall as
-- segments AROUND them, which keeps every part a plain Part the art team can
-- select, move and replace. Unions would look identical and be miserable to edit.
-- ------------------------------------------------------------

-- Places one axis-aligned wall slab of arbitrary height on a plane.
local function wallSlab(folder, axis, coord, a, b, y1, y2, mat, color, name, thickness)
	local half = (thickness or DIM.WallThickness) / 2
	if axis == "X" then
		return box(folder, name, coord - half, y1, a, coord + half, y2, b, mat, color)
	end
	return box(folder, name, a, y1, coord - half, b, y2, coord + half, mat, color)
end

-- THE TWO-TONE WALL. Wainscot below, plaster above, as two stacked parts.
-- See the DIM.WainscotHeight comment: this split is the single highest-value
-- detail in the shell and must survive any refactor of this function.
local function emitWallBand(folder, axis, coord, a, b, y1, y2, baseY, style, name)
	if b - a <= EPS or y2 - y1 <= EPS then
		return
	end
	if style == "Cellar" then
		-- The cellar is undressed stone all the way up - no wainscot. The change
		-- in wall treatment is how a player knows they left the house.
		wallSlab(folder, axis, coord, a, b, y1, y2, MATERIALS.CellarStone, PALETTE.Stone, name)
		return
	end
	local railY = baseY + DIM.WainscotHeight
	if y2 <= railY + EPS then
		wallSlab(folder, axis, coord, a, b, y1, y2, MATERIALS.Panel, PALETTE.WallPanel, name .. "_Wainscot")
	elseif y1 >= railY - EPS then
		wallSlab(folder, axis, coord, a, b, y1, y2, MATERIALS.Plaster, PALETTE.WallPlaster, name .. "_Plaster")
	else
		wallSlab(folder, axis, coord, a, b, y1, railY, MATERIALS.Panel, PALETTE.WallPanel, name .. "_Wainscot")
		wallSlab(folder, axis, coord, a, b, railY, y2, MATERIALS.Plaster, PALETTE.WallPlaster, name .. "_Plaster")
	end
end

-- The Conservatory's exterior walls: a low timber sill, then glass to the eaves
-- divided by brass mullions. The one room in the manor with no privacy.
local function emitGlassBand(folder, axis, coord, a, b, y1, y2)
	if b - a <= EPS then
		return
	end
	local sillTop = y1 + 2
	wallSlab(folder, axis, coord, a, b, y1, sillTop, MATERIALS.Timber, PALETTE.DarkWood, "GlassWall_Sill")
	wallSlab(folder, axis, coord, a, b, sillTop, y2, MATERIALS.Glass, PALETTE.GlassTint, "GlassWall_Pane", DIM.PaneThickness)
	-- Mullions roughly every 5 studs, plus one at each end so the run is framed.
	local width = b - a
	local bays = math.max(1, math.floor(width / 5 + 0.5))
	for i = 0, bays do
		local at = a + (width * i / bays)
		local m1, m2 = math.max(a, at - 0.25), math.min(b, at + 0.25)
		wallSlab(folder, axis, coord, m1, m2, sillTop, y2, MATERIALS.Trim, PALETTE.TrimBrass, "Mullion", DIM.WallThickness)
	end
	wallSlab(folder, axis, coord, a, b, y2 - 0.4, y2, MATERIALS.Trim, PALETTE.TrimBrass, "GlassWall_Head", DIM.WallThickness)
end

-- Brass over every doorway; brass arch, tinted pane and placeholder moonlight
-- over every window.
local function emitOpeningTrim(folder, opening, axis, coord, baseY)
	local a, b = opening.a, opening.b
	local headY = baseY + opening.head
	local proud = DIM.WallThickness + DIM.LintelProud * 2

	if opening.kind == "Door" then
		-- A LINTEL OVER EVERY DOORWAY, no exceptions. A bare rectangular hole in a
		-- wall is the single strongest "this is a graybox" signal; one brass strip
		-- above it reads as a cased opening for the price of one part.
		wallSlab(folder, axis, coord, a, b, headY, headY + DIM.LintelHeight,
			MATERIALS.Trim, PALETTE.TrimBrass, "DoorLintel", proud)
		return
	end

	local sillY = baseY + opening.sill
	-- ARCHED FEEL, NOT A REAL ARCH. A brass strip across the head plus two jambs
	-- suggests the arch at graybox cost; the actual curve is an art-pass mesh.
	wallSlab(folder, axis, coord, a, b, headY, headY + DIM.WindowArch,
		MATERIALS.Trim, PALETTE.TrimBrass, "WindowArch", proud)
	wallSlab(folder, axis, coord, a, a + 0.4, sillY, headY, MATERIALS.Trim, PALETTE.TrimBrass, "WindowJamb", proud)
	wallSlab(folder, axis, coord, b - 0.4, b, sillY, headY, MATERIALS.Trim, PALETTE.TrimBrass, "WindowJamb", proud)
	wallSlab(folder, axis, coord, a, b, sillY - 0.4, sillY, MATERIALS.Trim, PALETTE.TrimBrass, "WindowSill", proud)

	local pane = wallSlab(folder, axis, coord, a, b, sillY, headY,
		MATERIALS.Glass, PALETTE.GlassTint, "WindowPane", DIM.PaneThickness)
	if not pane then
		return
	end
	pane.Transparency = DIM.PaneTransparency
	pane.CanCollide = true -- a window is not a doorway

	-- PLACEHOLDER MOONLIGHT - the mood layer, not the lighting solution. See the
	-- note on PLAN.Windows: RoomLamps carry interiors next prompt and the art
	-- pass replaces these outright. Faces INTO the room.
	local light = Instance.new("SurfaceLight")
	light.Name = "Moonlight"
	light.Brightness = DIM.MoonlightBright
	light.Color = PALETTE.GlassTint
	light.Range = 22
	light.Angle = 100
	light.Shadows = false
	if axis == "X" then
		light.Face = (opening.insideDir < 0) and Enum.NormalId.Left or Enum.NormalId.Right
	else
		light.Face = (opening.insideDir < 0) and Enum.NormalId.Front or Enum.NormalId.Back
	end
	light.Parent = pane
	counters.lights = counters.lights + 1
end

-- The stretches of one plane that have a GROUND ROOM standing over them. Used
-- only by the cellar wall pass: a cellar wall's legal top depends on whether the
-- manor is above it (stop flush under the ground slab) or the lawn is (stop a
-- vault-cover lower, so the turf can close over it). See the burial rule below.
local function groundCoverSpans(ctx, axis, coord)
	local covers = {}
	for _, entry in ipairs(ctx.rectsByFloor.Ground) do
		local r = entry.rect
		if axis == "X" then
			if coord >= r[1] - EPS and coord <= r[3] + EPS then
				table.insert(covers, { r[2], r[4] })
			end
		else
			if coord >= r[2] - EPS and coord <= r[4] + EPS then
				table.insert(covers, { r[1], r[3] })
			end
		end
	end
	return mergeSpans(covers)
end

-- The wall pass for one floor. Walks every plane, works out which stretches
-- need a wall at all, then cuts each stretch around whatever openings land in it.
local function buildWalls(ctx, floorName)
	local floorPlanes = ctx.planes[floorName]
	local baseY = floorBaseY(floorName)
	local style = (floorName == "Cellar") and "Cellar" or "Ground"

	for axis, byCoord in pairs(floorPlanes) do
		for coord, plane in pairs(byCoord) do
			local wallSpans, sameSpans = planeWallSpans(plane)
			ctx.sameRoom[floorName][axis][coord] = sameSpans
			local openings = ctx.openings[floorName][axis][coord] or {}
			-- Cut at every occupancy change first - see planeBreakpoints.
			wallSpans = splitAtBreakpoints(wallSpans, planeBreakpoints(plane))

			for _, piece in ipairs(wallSpans) do
				local lowerRoom, upperRoom = roomsAt(plane, (piece[1] + piece[2]) / 2)
				local owner = lowerRoom or upperRoom
				-- Unreachable given wall spans are derived from occupied spans,
				-- but a plan edit that produces a zero-width sliver would
				-- otherwise crash the build here rather than report itself.
				if owner then
					local folder = ctx.folders[owner.name]
					-- Sized to the TALLER neighbour, so a double-height room stays
					-- enclosed where it borders a single-height one.
					local height = math.max(
						lowerRoom and roomHeight(lowerRoom) or 0,
						upperRoom and roomHeight(upperRoom) or 0
					)
					local top = baseY + height

					-- THE BURIAL RULE, applied at emission time. A cellar wall may
					-- rise to the ground slab's UNDERSIDE where the manor stands on
					-- it, and no higher; where the cellar reaches past the rooms
					-- above, it must stop DIM.VaultCover lower so the turf cap closes
					-- over it. Without this split, every cellar wall outside the
					-- footprint topped out exactly at the grass plane and surfaced as
					-- a gray line in the lawn. The split is per STRETCH, so one wall
					-- crossing the footprint edge steps down at the edge.
					local buriedTop = GROUND_Y - DIM.FloorThickness - DIM.VaultCover
					local coveredSpans = (floorName == "Cellar")
						and groundCoverSpans(ctx, axis, coord) or nil
					local function bandsFor(a, b)
						if not coveredSpans then
							return { { a, b, top } }
						end
						local bands = {}
						for _, under in ipairs(intersectSpans({ { a, b } }, coveredSpans)) do
							table.insert(bands, { under[1], under[2], top })
						end
						for _, open in ipairs(subtractSpans({ { a, b } }, coveredSpans)) do
							table.insert(bands, { open[1], open[2], math.min(top, buriedTop) })
						end
						return bands
					end

					local isExterior = (lowerRoom == nil) or (upperRoom == nil)
					local wantsGlass = isExterior and (
						(lowerRoom and lowerRoom.glassWalls) or (upperRoom and upperRoom.glassWalls)
					)

					local cuts, mine = {}, {}
					for _, opening in ipairs(openings) do
						if opening.a >= piece[1] - EPS and opening.b <= piece[2] + EPS then
							table.insert(cuts, { opening.a, opening.b })
							table.insert(mine, opening)
						end
					end

					local solidTable = ctx.solid[floorName][axis]
					solidTable[coord] = solidTable[coord] or {}
					for _, solid in ipairs(subtractSpans({ piece }, cuts)) do
						for _, band in ipairs(bandsFor(solid[1], solid[2])) do
							if wantsGlass then
								emitGlassBand(folder, axis, coord, band[1], band[2], baseY, band[3])
							else
								emitWallBand(folder, axis, coord, band[1], band[2], baseY, band[3], baseY, style, "Wall")
							end
						end
						table.insert(solidTable[coord], { solid[1], solid[2] })
					end

					-- The plinth follows exterior ground walls only, openings
					-- included: a doorway still meets the earth at its threshold.
					-- `outDir` records WHICH SIDE of the plane is outdoors - the side
					-- with no room on it - because the plinth is an exterior-face
					-- feature and must know which way to stand proud.
					if isExterior and floorName == "Ground" then
						table.insert(ctx.exteriorRuns, {
							axis = axis, coord = coord, a = piece[1], b = piece[2],
							outDir = (upperRoom == nil) and 1 or -1,
						})
					end

					for _, opening in ipairs(mine) do
						if opening.sill > EPS then
							emitWallBand(folder, axis, coord, opening.a, opening.b,
								baseY, baseY + opening.sill, baseY, style, "Under" .. opening.kind)
						end
						if opening.head < height - EPS then
							for _, band in ipairs(bandsFor(opening.a, opening.b)) do
								emitWallBand(folder, axis, coord, band[1], band[2],
									baseY + opening.head, band[3], baseY, style, "Over" .. opening.kind)
							end
						end
						emitOpeningTrim(folder, opening, axis, coord, baseY)
					end

					-- Coverage for the perimeter check: the whole piece is
					-- accounted for, walls and intentional holes alike.
					local cov = ctx.coverage[floorName][axis]
					cov[coord] = cov[coord] or {}
					table.insert(cov[coord], { piece[1], piece[2] })
				end
			end
		end
	end
end

-- ------------------------------------------------------------
-- FLOORS AND CEILINGS.
--
-- THE CELLAR'S CEILING *IS* THE GROUND FLOOR over the east half - one slab, not
-- two coincident ones. That is why this pass does rectangle subtraction instead
-- of just emitting a slab per room: a ground room's floor is its footprint MINUS
-- whatever cellar lies beneath it, and the cellar's lid is split into the piece
-- that shows upstairs as floorboards and the piece that is a buried vault top.
-- Emitting both naively would z-fight along every overlap, which is exactly the
-- artifact this arrangement exists to avoid.
-- ------------------------------------------------------------
-- Where a buried vault rect abuts the region the manor stands on, the strip of
-- boundary that needs closing. Only those edges: a buried rect's other edges meet
-- solid earth (nothing to close) or another buried rect at the same ceiling
-- height (nothing to step). Returned as world rects a wall thick, centred on the
-- boundary, so they can be both built as fascia and carved out of the turf.
local function vaultFasciaStrips(buried, groundRects)
	local strips = {}
	local half = DIM.WallThickness / 2

	local function edge(axis, coord, span, outward)
		local probe = coord + outward * 0.25
		local covers = {}
		for _, g in ipairs(groundRects) do
			local hit, other
			if axis == "X" then
				hit = probe >= g[1] - EPS and probe <= g[3] + EPS
				other = { g[2], g[4] }
			else
				hit = probe >= g[2] - EPS and probe <= g[4] + EPS
				other = { g[1], g[3] }
			end
			if hit then
				local overlap = spanOverlap(span, other)
				if overlap then
					table.insert(covers, overlap)
				end
			end
		end
		for _, piece in ipairs(mergeSpans(covers)) do
			if axis == "X" then
				table.insert(strips, { coord - half, piece[1], coord + half, piece[2] })
			else
				table.insert(strips, { piece[1], coord - half, piece[2], coord + half })
			end
		end
	end

	edge("X", buried[1], { buried[2], buried[4] }, -1)
	edge("X", buried[3], { buried[2], buried[4] }, 1)
	edge("Z", buried[2], { buried[1], buried[3] }, -1)
	edge("Z", buried[4], { buried[1], buried[3] }, 1)
	return strips
end

local function buildFloorsAndCeilings(ctx)
	-- Shafts come from the DERIVED stair assemblies (deriveStairs), never from the
	-- plan - PLAN.Stairs no longer carries a rect to read.
	local shafts = {}
	for _, stair in ipairs(ctx.stairs) do
		table.insert(shafts, stair.shaft)
	end

	local cellarRects, groundEntries = {}, {}
	for _, entry in ipairs(ctx.rectsByFloor.Cellar or {}) do
		table.insert(cellarRects, entry.rect)
	end
	for _, entry in ipairs(ctx.rectsByFloor.Ground or {}) do
		table.insert(groundEntries, entry)
	end

	local function floorMat(room)
		return room.floorMaterial or MATERIALS.Floor, room.floorColor or PALETTE.Floorboard
	end

	-- Ground-floor slabs, minus anything the cellar already lids and minus the
	-- stair shafts (a stairwell needs a real hole, not a step onto a slab).
	for _, entry in ipairs(groundEntries) do
		local folder = ctx.folders[entry.room.name]
		local mat, color = floorMat(entry.room)
		for _, piece in ipairs(rectSubtractMany({ entry.rect }, shafts)) do
			for _, sub in ipairs(rectSubtractMany({ piece }, cellarRects)) do
				box(folder, "Floor", sub[1], GROUND_Y - DIM.FloorThickness, sub[2],
					sub[3], GROUND_Y, sub[4], mat, color)
			end
		end
	end

	-- The cellar lid, doubling as the ground floor. Split per ground room so each
	-- piece wears that room's floor material and files under that room's folder -
	-- from upstairs there is no seam and no way to tell there is a cellar below.
	for _, entry in ipairs(ctx.rectsByFloor.Cellar or {}) do
		local cellarFolder = ctx.folders[entry.room.name]
		local lidPieces = rectSubtractMany({ entry.rect }, shafts)
		for _, lid in ipairs(lidPieces) do
			for _, ground in ipairs(groundEntries) do
				local shared = rectIntersect(lid, ground.rect)
				if shared then
					local mat, color = floorMat(ground.room)
					box(ctx.folders[ground.room.name], "Floor", shared[1], GROUND_Y - DIM.FloorThickness,
						shared[2], shared[3], GROUND_Y, shared[4], mat, color)
				end
			end
			-- Whatever the manor does not stand on is a BURIED vault top, and buried
			-- is meant literally. This lid used to occupy the same slot as the ground
			-- floor - top at GROUND_Y, underside at the grass plane - which put a
			-- stone slab a full stud PROUD of the lawn wherever the cellar reached
			-- past the rooms above it: the exposed gray patch outside. It is now sunk
			-- so its TOP sits DIM.VaultCover below the grass, and buildGrounds lays a
			-- collidable turf cap over the same rects. From outside there is nothing
			-- but grass; the cellar below simply gains a lower soffit out there.
			local groundRects = {}
			for _, ground in ipairs(groundEntries) do
				table.insert(groundRects, ground.rect)
			end
			local vaultTop = GROUND_Y - DIM.FloorThickness - DIM.VaultCover
			for _, buried in ipairs(rectSubtractMany({ lid }, groundRects)) do
				box(cellarFolder, "VaultLid", buried[1], vaultTop - DIM.FloorThickness, buried[2],
					buried[3], vaultTop, buried[4], MATERIALS.CellarStone, PALETTE.Stone)
				table.insert(ctx.buriedRects, buried)

				-- ============================================================
				-- THE VAULT FASCIA, and it is the fix for GRASS BEING VISIBLE FROM
				-- INSIDE THE CELLAR.
				--
				-- Sinking the vault lid left the cellar ceiling with a STEP at the
				-- manor's footprint edge: under the house the ceiling is the ground
				-- slab's underside, past it the ceiling is the sunk lid two studs
				-- lower. The vertical face of that step was made of the turf cap's
				-- own side - so from inside the cellar, looking at the boundary, you
				-- saw a band of lawn hanging in the ceiling.
				--
				-- This closes the step with stone. It is placed centred on the
				-- boundary and runs from the sunk lid's underside up to the grass
				-- plane, so from inside it reads as a downstand beam carrying the
				-- exterior wall - which is exactly what is standing on it. Its top
				-- is at lawn level and it is only a wall thick, and the boundary of
				-- a buried region is BY CONSTRUCTION under an exterior wall (the
				-- region is the cellar minus the rooms above it), so the manor's own
				-- wall and plinth hide it from outside.
				--
				-- buildGrounds then carves these strips OUT of the turf, so no grass
				-- reaches the boundary at all rather than merely being covered.
				-- ============================================================
				for _, strip in ipairs(vaultFasciaStrips(buried, groundRects)) do
					box(cellarFolder, "VaultFascia", strip[1], vaultTop - DIM.FloorThickness, strip[2],
						strip[3], GROUND_Y - DIM.FloorThickness, strip[4],
						MATERIALS.CellarStone, PALETTE.Stone)
					table.insert(ctx.fasciaRects, strip)
				end
			end
		end

		-- Cellar floor slab.
		box(cellarFolder, "Floor", entry.rect[1], CELLAR_Y - DIM.FloorThickness, entry.rect[2],
			entry.rect[3], CELLAR_Y, entry.rect[4], MATERIALS.CellarStone, PALETTE.Stone)
	end

	-- Ground-floor ceilings, at the room's own height so the two double-height
	-- rooms actually read as double-height from inside.
	for _, entry in ipairs(groundEntries) do
		if entry.room.ceiling ~= false then
			-- roomHeight() is the ONLY source of ceiling height, and it reads the
			-- doubleHeight flag - so the Foyer and the Parlor land at 28 by the
			-- same path every other room lands at 14. Recorded here so
			-- checkDoubleHeight() can assert the built result rather than the
			-- intent.
			local top = GROUND_Y + roomHeight(entry.room)
			box(ctx.folders[entry.room.name], "Ceiling", entry.rect[1], top, entry.rect[2],
				entry.rect[3], top + DIM.CeilingThickness, entry.rect[4],
				MATERIALS.Plaster, PALETTE.WallPlaster)
			ctx.ceilingTops[entry.room.name] = top
		end
	end
end

-- ------------------------------------------------------------
-- Which room (if any) occupies a point on a floor. Used by the stair derivation
-- and by checkStairs; defined here because the derivation runs first.
-- ------------------------------------------------------------
local function roomAtPoint(ctx, floorName, x, z)
	for _, entry in ipairs(ctx.rectsByFloor[floorName] or {}) do
		local r = entry.rect
		if x > r[1] + EPS and x < r[3] - EPS and z > r[2] + EPS and z < r[4] - EPS then
			return entry.room
		end
	end
	return nil
end

-- ============================================================
-- STAIR DERIVATION. See the block comment on PLAN.Stairs for why nothing about a
-- stair's orientation may be written down by hand any more.
--
-- The whole assembly comes out of two facts already in the plan: the stair room's
-- rect, and which of its walls the doorway is on.
--
--   1. The DOORWAY WALL is found the same way the door itself is - the widest
--      shared wall between this room and whatever PLAN.Doors pairs it with. That
--      guarantees the stair and the door agree about which wall they are on, even
--      if the plan moves the room.
--   2. D is the inward normal of that wall, and THE FLIGHT DESCENDS ALONG D.
--      There is no choice of direction left to make and no second candidate to
--      score: the doorway decides it outright.
--   3. Across the flight, the shaft is centred on the DOORWAY'S OWN SPAN wherever
--      the room allows, so the stair is square in front of the door rather than
--      off to one side of it.
--   4. Along D, the head sits DIM.StairHead inside the doorway wall and the foot
--      stops DIM.StairExitClear short of wherever the DESTINATION cellar room
--      runs out. That clearance is the bottom doorway: the flight arrives and you
--      keep walking the same way into the room. The reach is found by SAMPLING
--      outward rather than by arithmetic, because the cellar room under a stair
--      room need not share its edges.
--   5. Everything else - shaft rect, tread count, enclosure and railings -
--      follows, and rotates together.
-- ============================================================
local function stairDoorway(ctx, host)
	local best
	for _, pair in ipairs(PLAN.Doors) do
		local otherName = (pair[1] == host.name and pair[2])
			or (pair[2] == host.name and pair[1])
			or nil
		local other = otherName and ctx.rooms[otherName]
		if other then
			local shared = findSharedWall(host, other)
			if shared and (not best or (shared.span[2] - shared.span[1]) > (best.span[2] - best.span[1])) then
				best = shared
			end
		end
	end
	return best
end

local function deriveStairs(ctx, warnings)
	ctx.stairs = {}

	for _, plan in ipairs(PLAN.Stairs) do
		local host = ctx.rooms[plan.room]
		local door = host and stairDoorway(ctx, host)
		if not host then
			table.insert(warnings, string.format("stair '%s' names room '%s', which is not in PLAN.Rooms", plan.name, tostring(plan.room)))
		elseif not door then
			table.insert(warnings, string.format("stair room '%s' has no doorway in PLAN.Doors - orientation cannot be derived", host.name))
		else
			local rect = host.rects[1]

			-- ---- D: from the doorway, into the room, perpendicular to its wall --
			-- The doorway plane lies on one of the room's four edges; which edge it
			-- is decides which way "into the room" points, and that is the entire
			-- input to the orientation.
			local doorAxis = door.axis
			local doorSide, inward
			if doorAxis == "X" then
				if math.abs(door.coord - rect[1]) < EPS then
					doorSide, inward = "W", 1
				else
					doorSide, inward = "E", -1
				end
			else
				if math.abs(door.coord - rect[2]) < EPS then
					doorSide, inward = "N", 1
				else
					doorSide, inward = "S", -1
				end
			end
			local flightAxis = doorAxis
			local crossAxis = (doorAxis == "X") and "Z" or "X"
			local doorCentre = (door.span[1] + door.span[2]) / 2
			local dirX = (flightAxis == "X") and inward or 0
			local dirZ = (flightAxis == "Z") and inward or 0

			-- ---- Across the flight: centred on the doorway's own span ----------
			-- Centred on the doorway wherever the room allows, so the flight is
			-- square in front of the door rather than off to one side.
			local cLo, cHi = (crossAxis == "X") and rect[1] or rect[2], (crossAxis == "X") and rect[3] or rect[4]
			local width = math.min(DIM.StairWidth, door.span[2] - door.span[1], (cHi - cLo) - 2)
			local across1 = math.clamp(doorCentre - width / 2, cLo + 1, cHi - 1 - width)
			local across2 = across1 + width
			local acrossMid = (across1 + across2) / 2

			-- ---- Along the flight: head near the door, foot short of the cellar --
			-- The HEAD sits DIM.StairHead inside the doorway wall. The FOOT has to
			-- stop DIM.StairExitClear short of wherever the DESTINATION cellar room
			-- runs out, because that clearance IS the bottom doorway - the flight
			-- arrives and you keep walking in the same direction into the room.
			local aLo, aHi = (flightAxis == "X") and rect[1] or rect[2], (flightAxis == "X") and rect[3] or rect[4]
			local head = (inward > 0) and (aLo + DIM.StairHead) or (aHi - DIM.StairHead)

			-- Walk outward from the head in one-stud steps to find where the
			-- destination room stops. Sampling beats arithmetic here: the cellar
			-- room under a stair room need not share its edges, and this reads the
			-- rooms that are actually there.
			local limit = (inward > 0) and aHi or aLo
			local reach = head
			for step = 1, 200 do
				local probe = head + inward * step
				if (inward > 0 and probe > limit) or (inward < 0 and probe < limit) then
					break
				end
				local px = (flightAxis == "X") and probe or acrossMid
				local pz = (flightAxis == "X") and acrossMid or probe
				local landed = roomAtPoint(ctx, "Cellar", px, pz)
				if not landed or landed.name ~= plan.to then
					break
				end
				reach = probe
			end

			local foot = reach - inward * DIM.StairExitClear
			local length = math.abs(foot - head)
			local feasible = length >= 4

			if not feasible then
				-- Reported, never guessed at. A flight with nowhere to arrive is
				-- exactly the failure this derivation exists to end, and the stair
				-- check below fails loudly on the same condition.
				table.insert(warnings, string.format(
					"stair '%s': only %.1f studs of run available along D before %s runs out - the flight cannot be built facing its doorway",
					plan.name, length, tostring(plan.to)))
			end

			local a1 = math.min(head, foot)
			local a2 = math.max(head, foot)
			local shaft
			if flightAxis == "X" then
				shaft = { a1, across1, a2, across2 }
			else
				shaft = { across1, a1, across2, a2 }
			end

			-- Tread depth is the target and the rise follows, floored at whatever
			-- keeps the rise under DIM.StairRiseMax: a short room gets a steeper
			-- flight rather than a flight that does not reach the cellar.
			local drop = GROUND_Y - CELLAR_Y
			local steps = math.max(math.ceil(drop / DIM.StairRiseMax), math.floor(length / DIM.StairTread + 0.5), 1)

			table.insert(ctx.stairs, {
				plan = plan,
				name = plan.name,
				host = host,
				shaft = shaft,
				axis = flightAxis,
				crossAxis = crossAxis,
				downPositive = (inward > 0),
				doorSide = doorSide,
				doorAxis = doorAxis,
				doorCoord = door.coord,
				doorCentre = doorCentre,
				dirX = dirX,
				dirZ = dirZ,
				head = head,
				foot = foot,
				acrossMid = acrossMid,
				steps = steps,
				rise = drop / steps,
				run = length / steps,
				exitClear = math.abs(reach - foot),
				feasible = feasible,
			})
		end
	end
end

-- ------------------------------------------------------------
-- THE RAILING KIT. Posts at a spacing plus one thin top rail - see DIM.RailHeight
-- for what this replaced and why. `axis` is the axis the run travels along.
-- ------------------------------------------------------------
local function railRun(folder, axis, coord, a, b, baseY)
	if b - a <= EPS then
		return
	end
	local top = baseY + DIM.RailHeight
	local p = DIM.RailPost / 2
	local t = DIM.RailTopThickness / 2

	local spans = math.max(1, math.floor((b - a) / DIM.RailPostSpacing + 0.5))
	for i = 0, spans do
		local at = a + (b - a) * i / spans
		-- End posts are pulled inboard by half their width so a run never reaches
		-- past the shaft edge it is guarding.
		at = math.min(math.max(at, a + p), b - p)
		if axis == "X" then
			box(folder, "RailPost", at - p, baseY, coord - p, at + p, top - DIM.RailTopThickness, coord + p,
				MATERIALS.Trim, PALETTE.TrimBrass)
		else
			box(folder, "RailPost", coord - p, baseY, at - p, coord + p, top - DIM.RailTopThickness, at + p,
				MATERIALS.Trim, PALETTE.TrimBrass)
		end
	end
	if axis == "X" then
		box(folder, "RailTop", a, top - DIM.RailTopThickness, coord - t, b, top, coord + t,
			MATERIALS.Trim, PALETTE.TrimBrass)
	else
		box(folder, "RailTop", coord - t, top - DIM.RailTopThickness, a, coord + t, top, b,
			MATERIALS.Trim, PALETTE.TrimBrass)
	end
end

-- ------------------------------------------------------------
-- STAIRS. Real stepped parts, one part per tread, inside an enclosed stairwell.
-- Entirely orientation-agnostic: it reads the derived assembly and never asks
-- which way is Z.
-- ------------------------------------------------------------
local function buildStairs(ctx)
	for _, stair in ipairs(ctx.stairs) do
		local folder = Instance.new("Folder")
		folder.Name = stair.name
		folder.Parent = ctx.stairFolder

		local sh = stair.shaft
		local alongX = (stair.axis == "X")
		-- a* runs ALONG the flight, c* ACROSS it.
		local a1, a2 = alongX and sh[1] or sh[2], alongX and sh[3] or sh[4]
		local c1, c2 = alongX and sh[2] or sh[1], alongX and sh[4] or sh[3]

		local steps, run, rise = stair.steps, stair.run, stair.rise
		local down = stair.downPositive

		-- Tread i counts DOWN from the head toward the foot, so which end of the
		-- shaft is the top depends entirely on the derived direction.
		for i = 1, steps do
			local at = down and (a1 + run * (i - 1)) or (a2 - run * i)
			local topY = GROUND_Y - rise * i
			if alongX then
				box(folder, "Step", at, topY - rise, c1, at + run, topY, c2,
					MATERIALS.Timber, PALETTE.DarkWood)
			else
				box(folder, "Step", c1, topY - rise, at, c2, topY, at + run,
					MATERIALS.Timber, PALETTE.DarkWood)
			end
		end

		-- SHAFT ENCLOSURE, below the floor only. Walls from the cellar floor up to
		-- the underside of the ground slab on the two long sides and the HEAD end,
		-- leaving the foot end open to walk out of. Built here rather than relying
		-- on cellar room boundaries, so the stairwell is enclosed by construction
		-- wherever the shaft happens to sit.
		local wallTop = GROUND_Y - DIM.FloorThickness
		local w = DIM.WallThickness
		local headEnd = down and a1 or a2
		local footEnd = down and a2 or a1
		local function shaftWall(lo1, lo2, hi1, hi2)
			box(folder, "ShaftWall", lo1, CELLAR_Y, lo2, hi1, wallTop, hi2,
				MATERIALS.CellarStone, PALETTE.Stone)
		end
		-- The head-end wall sits just OUTSIDE the head, closing the space under the
		-- head landing; the foot end stays open so the flight has somewhere to
		-- arrive.
		local headLo = down and (headEnd - w) or headEnd
		local headHi = down and headEnd or (headEnd + w)
		if alongX then
			shaftWall(a1, c1 - w, a2, c1)
			shaftWall(a1, c2, a2, c2 + w)
			shaftWall(headLo, c1 - w, headHi, c2 + w)
		else
			shaftWall(c1 - w, a1, c1, a2)
			shaftWall(c2, a1, c2 + w, a2)
			shaftWall(c1 - w, headLo, c2 + w, headHi)
		end

		-- Railings at ground level around the two long edges and the FOOT end. The
		-- head end is left clear - that is the way in, and it is the edge the
		-- doorway now looks at.
		local railAxis = alongX and "X" or "Z"
		local crossAxis = alongX and "Z" or "X"
		railRun(folder, railAxis, c1, a1, a2, GROUND_Y)
		railRun(folder, railAxis, c2, a1, a2, GROUND_Y)
		railRun(folder, crossAxis, footEnd, c1, c2, GROUND_Y)

		counters.stairs = counters.stairs + 1
	end
end

-- ------------------------------------------------------------
-- STAIR CONNECTIVITY VALIDATOR. New after the shell review, and it exists
-- because the perimeter check STRUCTURALLY CANNOT catch this failure class: the
-- perimeter check asks "is every edge walled", and a stair that descends into
-- sealed ground fails by being TOO well walled. Nothing about the geometry was
-- invalid - the Kitchen Stair's bottom step simply faced a wall, and the only
-- way to notice was to walk down it in Studio.
--
-- For each stair this probes one stud beyond the top tread at ground level and
-- one stud beyond the bottom tread at cellar level, and requires that each probe
-- lands inside a room of the right floor AND is not cut off by solid wall on the
-- plane it crosses. Runs on every build, not just the one that fixed this.
-- ------------------------------------------------------------
local function checkStairs(ctx)
	local results = {}
	for _, stair in ipairs(ctx.stairs) do
		local sh = stair.shaft
		local alongX = (stair.axis == "X")
		local a1, a2 = alongX and sh[1] or sh[2], alongX and sh[3] or sh[4]
		local c1, c2 = alongX and sh[2] or sh[1], alongX and sh[4] or sh[3]
		local centre = (c1 + c2) / 2
		local down = stair.downPositive
		local topEdge = down and a1 or a2
		local bottomEdge = down and a2 or a1
		local topProbe = topEdge + (down and -1 or 1)
		local bottomProbe = bottomEdge + (down and 1 or -1)

		local function at(along, across)
			if alongX then
				return along, across
			end
			return across, along
		end

		local tx, tz = at(topProbe, centre)
		local bx, bz = at(bottomProbe, centre)
		local topRoom = roomAtPoint(ctx, "Ground", tx, tz)
		local bottomRoom = roomAtPoint(ctx, "Cellar", bx, bz)
		local topBlocked = spansContain(ctx.solid.Ground[stair.axis][topEdge] or {}, centre)
		local bottomBlocked = spansContain(ctx.solid.Cellar[stair.axis][bottomEdge] or {}, centre)

		local problems = {}
		if not topRoom then
			table.insert(problems, "top step opens into nothing on the ground floor")
		elseif topBlocked then
			table.insert(problems, "top step is walled off from " .. topRoom.name)
		end
		if not bottomRoom then
			table.insert(problems, "bottom step opens into SEALED GROUND")
		elseif bottomBlocked then
			table.insert(problems, "bottom step is walled off from " .. bottomRoom.name)
		end

		-- CONTAINMENT - the check whose absence let the last revision ship. Probing
		-- the two ENDS says nothing about where the shaft's MIDDLE is, so a flight
		-- punched straight through a corridor floor passed cleanly. The shaft must
		-- lie inside its declared stair room and touch no other ground room.
		local host = stair.host
		local outside = rectSubtractMany({ stair.shaft }, host.rects)
		if #outside > 0 then
			table.insert(problems, "shaft is not fully inside " .. host.name)
		end
		for _, entry in ipairs(ctx.rectsByFloor.Ground) do
			if entry.room ~= host and rectIntersect(stair.shaft, entry.rect) then
				table.insert(problems, "shaft CUTS THROUGH " .. entry.room.name .. "'s floor")
			end
		end
		if topRoom and topRoom ~= host then
			table.insert(problems, "top step opens into " .. topRoom.name .. ", not " .. host.name)
		end

		local destination = ctx.rooms[stair.plan.to]
		if destination and bottomRoom and bottomRoom ~= destination then
			table.insert(problems, string.format("bottom step opens into %s, not the declared %s", bottomRoom.name, destination.name))
		end

		-- ============================================================
		-- THE GEOMETRIC FACING TEST.
		--
		-- The previous revision's facing assertion PASSED on a build that was
		-- visibly wrong, which means it was not testing the property anyone cared
		-- about. It asked whether the flight ran PARALLEL to the doorway wall and
		-- whether there was a landing in front of it - and both of those are true
		-- of a stairwell you walk in and see side-on, which is exactly what shipped.
		-- It has been DELETED rather than tightened; a test that can pass a wrong
		-- build is worse than no test, because it launders the wrongness.
		--
		-- What replaces it is pure geometry with nothing left to interpret:
		--
		--   D = the unit vector from the doorway INTO the room, perpendicular to
		--       the doorway's wall.
		--   1. TOP-STEP PROXIMITY - the top step is the part of the flight nearest
		--      the doorway, and within DIM.StairTopProximity studs of it.
		--   2. AXIS MATCH - the horizontal descent vector, top-step centre to
		--      bottom-step centre, normalized, equals D within tolerance.
		--
		-- Together those say: walking through the door, you face straight down the
		-- flight. A stair turned any other way has a descent vector perpendicular
		-- to D (or reversed), fails condition 2 by construction, and CANNOT print
		-- PASS. Positions and both vectors are printed every build so the verdict
		-- can be checked by eye against the geometry rather than trusted.
		-- ============================================================
		local halfRun = stair.run / 2
		local topAlong = stair.head + (down and halfRun or -halfRun)
		local bottomAlong = stair.foot - (down and halfRun or -halfRun)
		local topX, topZ = at(topAlong, stair.acrossMid)
		local bottomX, bottomZ = at(bottomAlong, stair.acrossMid)
		local doorX, doorZ = (stair.doorAxis == "X") and stair.doorCoord or stair.doorCentre,
			(stair.doorAxis == "X") and stair.doorCentre or stair.doorCoord

		local topGap = math.sqrt((topX - doorX) ^ 2 + (topZ - doorZ) ^ 2)
		local bottomGap = math.sqrt((bottomX - doorX) ^ 2 + (bottomZ - doorZ) ^ 2)

		local dx, dz = bottomX - topX, bottomZ - topZ
		local length = math.sqrt(dx * dx + dz * dz)
		local descentX = (length > EPS) and (dx / length) or 0
		local descentZ = (length > EPS) and (dz / length) or 0
		-- Dot of the two unit vectors: 1 is a perfect match, 0 perpendicular,
		-- -1 reversed.
		local alignment = descentX * stair.dirX + descentZ * stair.dirZ

		if topGap > DIM.StairTopProximity + EPS then
			table.insert(problems, string.format(
				"top step is %.1f studs from the doorway (max %d) - you do not arrive at the head of the flight",
				topGap, DIM.StairTopProximity))
		end
		if bottomGap <= topGap + EPS then
			table.insert(problems, string.format(
				"the BOTTOM step (%.1f) is at least as near the doorway as the top (%.1f) - the flight is reversed",
				bottomGap, topGap))
		end
		if alignment < 1 - 0.01 then
			table.insert(problems, string.format(
				"descent vector (%.2f, %.2f) does not match D (%.0f, %.0f); alignment %.2f, needs 1.00",
				descentX, descentZ, stair.dirX, stair.dirZ, alignment))
		end
		if not stair.feasible then
			table.insert(problems, string.format(
				"only %.1f studs of run were available along D before %s ran out",
				length, tostring(stair.plan.to)))
		end

		table.insert(results, {
			name = stair.name,
			ok = #problems == 0,
			host = host.name,
			topRoom = topRoom and topRoom.name or "-",
			bottomRoom = bottomRoom and bottomRoom.name or "-",
			doorSide = stair.doorSide,
			doorAt = string.format("(%.1f, %.1f)", doorX, doorZ),
			topAt = string.format("(%.1f, %.1f)", topX, topZ),
			requiredD = string.format("(%.0f, %.0f)", stair.dirX, stair.dirZ),
			descent = string.format("(%.2f, %.2f)", descentX, descentZ),
			topGap = topGap,
			alignment = alignment,
			steps = stair.steps,
			rise = stair.rise,
			run = stair.run,
			problems = problems,
		})
	end
	return results
end

-- ------------------------------------------------------------
-- ROOF. Two slate slabs pitched to a ridge over the core, plus the
-- Conservatory's own glass pitch. Simple on purpose: the roof's job in a shell
-- is to close the silhouette and stop the sky pouring in, not to be architecture.
-- ------------------------------------------------------------
-- One pitched roof over one rect. `ridgeAxis` is the axis the RIDGE RUNS ALONG,
-- so the slopes fall away along the other one. Gable triangles close the two
-- ends perpendicular to the ridge - without them a pitched roof is just two
-- floating planks with the attic open to the weather at both ends.
-- ============================================================
-- THE ABUTMENT RULE. A LOWER ROOF DIES INTO A TALLER WALL, NEVER THROUGH IT.
--
-- Every wing used to be roofed over its rect expanded by a uniform overhang on
-- all four sides, with a gable closing each end. That is correct only where the
-- edge faces sky. Where a 14-stud wing butts against a 28-stud one, the
-- overhang and the gable were being built INSIDE the taller room: the Parlor's
-- upper walls showed the neighbouring wings' slopes crossing them as diagonal
-- slabs, and their WallPlaster gable halves as chevrons - the thin white ledge
-- too, which is a gable's own base course seen edge-on through the wall.
--
-- So each edge is now classified before anything is emitted:
--   * faces sky            -> overhang and gable exactly as before
--   * abuts a TALLER mass  -> NO overhang, NO gable (that wall closes the end
--                             itself), and the geometry stops at the shared
--                             wall's near face less an epsilon.
-- The classification is per EDGE, so a partly-taller edge (the Gallery's east
-- side runs past the Parlor, two short rooms, then the Foyer) is trimmed along
-- its whole length. That errs toward a missing overhang rather than a slab
-- through someone's ceiling, which is the right way to be wrong.
-- ============================================================
local ROOF_CLEAR = 0.05 -- the epsilon; keeps a trimmed edge off the wall face

-- True when the strip immediately beyond `side` of `rect` is occupied by a
-- ground room whose walls stand higher than this roof's seat.
local function edgeAbutsTaller(ctx, rect, side, wallHeight)
	local p = 0.5 -- reaches into the shared wall, never past it
	local probe
	if side == "West" then
		probe = { rect[1] - p, rect[2], rect[1], rect[4] }
	elseif side == "East" then
		probe = { rect[3], rect[2], rect[3] + p, rect[4] }
	elseif side == "North" then
		probe = { rect[1], rect[2] - p, rect[3], rect[2] }
	else
		probe = { rect[1], rect[4], rect[3], rect[4] + p }
	end
	for _, entry in ipairs(ctx.rectsByFloor.Ground) do
		if roomHeight(entry.room) > wallHeight + EPS and rectIntersect(probe, entry.rect) then
			return true
		end
	end
	return false
end

-- One slope slab between two points on the same side of the ridge. Heights come
-- from the ridge plane rather than from the slab's own extent, so TRIMMING AN
-- EAVE SHORTENS THE SLAB WITHOUT CHANGING THE PITCH - a trimmed side simply
-- stops higher up the same plane, which is what dying into a wall looks like.
local function emitSlope(folder, fallAxis, a, b, ridgeCoord, ridgeY, slope, lo, hi, mat, color, name, opts)
	local run = b - a
	if math.abs(run) <= EPS or hi - lo <= EPS then
		return
	end
	local ha = ridgeY - slope * math.abs(a - ridgeCoord)
	local hb = ridgeY - slope * math.abs(b - ridgeCoord)
	local length = math.sqrt(run * run + (hb - ha) * (hb - ha))
	local tilt = math.atan((hb - ha) / run)

	if fallAxis == "X" then
		makePart(folder, name,
			Vector3.new(length, DIM.RoofThickness, hi - lo),
			CFrame.new((a + b) / 2, (ha + hb) / 2, (lo + hi) / 2) * CFrame.Angles(0, 0, tilt),
			mat, color, opts)
	else
		makePart(folder, name,
			Vector3.new(hi - lo, DIM.RoofThickness, length),
			CFrame.new((lo + hi) / 2, (ha + hb) / 2, (a + b) / 2) * CFrame.Angles(-tilt, 0, 0),
			mat, color, opts)
	end
end

-- Half a gable end: the wall between the eave line and the roof plane, from the
-- ridge out to `farCoord`. Where that half runs the full slope it is a triangle
-- and one WedgePart does it. Where the eave on that side was TRIMMED the roof
-- plane stops above the eave line, so the shape is a TRAPEZOID - a rectangle up
-- to the trimmed height with the wedge riding on top of it.
local function emitGableHalf(folder, spanAxis, planeCoord, ridgeCoord, farCoord, eaveY, ridgeY, slope)
	local run = math.abs(farCoord - ridgeCoord)
	if run <= EPS then
		return
	end
	local lo, hi = math.min(ridgeCoord, farCoord), math.max(ridgeCoord, farCoord)
	local farH = math.max(0, (ridgeY - slope * run) - eaveY)
	local t = DIM.GableThickness

	local function place(part, yLow, yHigh)
		part.Anchored = true
		part.Material = MATERIALS.Plaster
		part.Color = PALETTE.WallPlaster
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Size = Vector3.new(t, yHigh - yLow, hi - lo)
		local mid = (lo + hi) / 2
		local yaw
		if spanAxis == "X" then
			yaw = (farCoord > ridgeCoord) and (math.pi / 2) or (-math.pi / 2)
			part.CFrame = CFrame.new(mid, (yLow + yHigh) / 2, planeCoord) * CFrame.Angles(0, yaw, 0)
		else
			yaw = (farCoord > ridgeCoord) and 0 or math.pi
			part.CFrame = CFrame.new(planeCoord, (yLow + yHigh) / 2, mid) * CFrame.Angles(0, yaw, 0)
		end
		part.Parent = folder
		counters.parts = counters.parts + 1
	end

	if farH > EPS then
		local block = Instance.new("Part")
		block.Name = "GableBase"
		place(block, eaveY, eaveY + farH)
	end
	if ridgeY - (eaveY + farH) > EPS then
		local wedge = Instance.new("WedgePart")
		wedge.Name = "Gable"
		-- A WedgePart is full height at its local -Z edge and tapers to nothing at
		-- +Z, so the yaw above points local +Z at the FAR end and leaves the tall
		-- edge standing under the ridge.
		place(wedge, eaveY + farH, ridgeY)
	end
end

-- One pitched roof over one wing. `rect` is the wing footprint (it fixes where
-- the ridge sits); `eaves` is that rect after per-edge overhang or trimming;
-- `blocked` marks the edges that abut something taller.
local function buildPitch(folder, rect, eaves, blocked, eaveY, rise, ridgeAxis, mat, color, name, opts, withGables)
	local ridgeY = eaveY + rise

	if ridgeAxis == "Z" then
		-- Ridge along Z at mid-X; slopes fall east and west, gables close N and S.
		local ridgeX = (rect[1] + rect[3]) / 2
		-- Pitch is set by the LONGER side, so a trimmed side keeps the same plane.
		local nominal = math.max(ridgeX - eaves[1], eaves[3] - ridgeX)
		if nominal <= EPS then
			return
		end
		local slope = rise / nominal
		emitSlope(folder, "X", eaves[1], ridgeX, ridgeX, ridgeY, slope, eaves[2], eaves[4], mat, color, name, opts)
		emitSlope(folder, "X", ridgeX, eaves[3], ridgeX, ridgeY, slope, eaves[2], eaves[4], mat, color, name, opts)
		if withGables and not blocked.North then
			emitGableHalf(folder, "X", eaves[2], ridgeX, eaves[1], eaveY, ridgeY, slope)
			emitGableHalf(folder, "X", eaves[2], ridgeX, eaves[3], eaveY, ridgeY, slope)
		end
		if withGables and not blocked.South then
			emitGableHalf(folder, "X", eaves[4], ridgeX, eaves[1], eaveY, ridgeY, slope)
			emitGableHalf(folder, "X", eaves[4], ridgeX, eaves[3], eaveY, ridgeY, slope)
		end
	else
		-- Ridge along X at mid-Z; slopes fall north and south, gables close E and W.
		local ridgeZ = (rect[2] + rect[4]) / 2
		local nominal = math.max(ridgeZ - eaves[2], eaves[4] - ridgeZ)
		if nominal <= EPS then
			return
		end
		local slope = rise / nominal
		emitSlope(folder, "Z", eaves[2], ridgeZ, ridgeZ, ridgeY, slope, eaves[1], eaves[3], mat, color, name, opts)
		emitSlope(folder, "Z", ridgeZ, eaves[4], ridgeZ, ridgeY, slope, eaves[1], eaves[3], mat, color, name, opts)
		if withGables and not blocked.West then
			emitGableHalf(folder, "Z", eaves[1], ridgeZ, eaves[2], eaveY, ridgeY, slope)
			emitGableHalf(folder, "Z", eaves[1], ridgeZ, eaves[4], eaveY, ridgeY, slope)
		end
		if withGables and not blocked.East then
			emitGableHalf(folder, "Z", eaves[3], ridgeZ, eaves[2], eaveY, ridgeY, slope)
			emitGableHalf(folder, "Z", eaves[3], ridgeZ, eaves[4], eaveY, ridgeY, slope)
		end
	end
end

local SIDE_INDEX = { West = 1, North = 2, East = 3, South = 4 }
-- +1 on the min sides, -1 on the max sides: which way is "outward" for each edge.
local SIDE_OUT = { West = -1, North = -1, East = 1, South = 1 }

local function buildRoof(ctx)
	-- WAIVED by design review as an EXTERIOR feature: players remain indoors, so
	-- the roof's outward appearance buys nothing yet and is logged for a later
	-- exterior pass. The abutment rule below is not part of that waiver - it is an
	-- INTERIOR correctness fix, because the old roof was visible inside rooms.
	local folder = Instance.new("Folder")
	folder.Name = "Roof"
	folder.Parent = ctx.model
	ctx.roofFolder = folder

	for _, wing in ipairs(PLAN.Roofs) do
		local r = wing.rect
		-- SEATED FLUSH, ZERO AIR GAP: the eave sits on the top of the ceiling
		-- slab, which is the top of the wall.
		local eaveY = GROUND_Y + wing.wallHeight + DIM.CeilingThickness
		local spanX, spanZ = r[3] - r[1], r[4] - r[2]
		local ridgeAxis = wing.ridgeAxis or ((spanZ > spanX) and "Z" or "X")
		local across = (ridgeAxis == "Z") and spanX or spanZ
		local rise = math.clamp((across / 2) * DIM.RoofPitch, DIM.RoofRiseMin, DIM.RoofRiseMax)

		local eaves, blocked = {}, {}
		for side, index in pairs(SIDE_INDEX) do
			local taller = edgeAbutsTaller(ctx, r, side, wing.wallHeight)
			blocked[side] = taller
			local out = SIDE_OUT[side]
			if taller then
				-- Stop at the shared wall's near face, less the epsilon.
				eaves[index] = r[index] - out * (DIM.WallThickness / 2 + ROOF_CLEAR)
			else
				eaves[index] = r[index] + out * DIM.RoofOverhang
			end
		end

		buildPitch(folder, r, eaves, blocked, eaveY, rise, ridgeAxis,
			MATERIALS.Roof, PALETTE.Slate, wing.name .. "_Slope", nil, true)
	end

	-- The Conservatory keeps its own low glass pitch and is exempt from the wing
	-- list; it is the one room meant to be lit by the sky. Nothing taller adjoins
	-- it, so it needs no trimming and carries no gables.
	local conservatory = ctx.rooms.Conservatory
	if conservatory then
		local c = conservatory.rects[1]
		local eave = GROUND_Y + DIM.WallHeight
		-- No overhang on the WEST edge: that side meets the Dining Hall, and an
		-- overhang there would reach past the shared wall's inner face into the
		-- room - the same defect as the wing roofs, one stud at a time. The other
		-- three edges face sky and overhang normally.
		buildPitch(folder, c, { c[1], c[2] - 1, c[3] + 1, c[4] + 1 }, {}, eave, 7, "Z",
			MATERIALS.Glass, PALETTE.GlassTint, "ConservatoryGlassRoof",
			{ transparency = 0.5, castShadow = false }, false)
	end
end

-- ------------------------------------------------------------
-- ROOF / INTERIOR INTERSECTION VALIDATOR. The coverage check asks whether every
-- room has roof ABOVE it; this asks the opposite and equally necessary question
-- - whether any roof is INSIDE it. Nothing in the plan data can answer that,
-- because the offending geometry is rotated slabs and wedges whose reach is a
-- product of pitch, rise and overhang; it has to be measured against the parts
-- that were actually built.
--
-- GetPartsInPart, not GetPartBoundsInBox: a tilted slope slab's bounding box is
-- far larger than the slab, and box tests would report penetrations that are not
-- there. The probe is the room's interior volume - its rect inset past the wall
-- faces, floor to ceiling underside - and the query is filtered to the roof
-- folder alone, so a wall, a stair rail or a neighbour's ceiling can never be
-- mistaken for a roof. THE TARGET IS ZERO.
-- ------------------------------------------------------------
local function checkRoofIntersections(ctx)
	local hits = {}
	if not ctx.roofFolder then
		return hits
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { ctx.roofFolder }
	params.MaxParts = 100

	local inset = DIM.WallThickness / 2 + ROOF_CLEAR
	for _, entry in ipairs(ctx.rectsByFloor.Ground) do
		local room = entry.room
		local r = entry.rect
		local x1, z1 = r[1] + inset, r[2] + inset
		local x2, z2 = r[3] - inset, r[4] - inset
		-- Top inset by half a roof slab: a pitch legitimately SEATED on a wall top
		-- with no ceiling under it (the Conservatory's glass) hangs its slab half a
		-- thickness below the seat line, and that is not a penetration. Anything
		-- actually reaching into a room clears this by studs, not fractions.
		local top = GROUND_Y + roomHeight(room) - (DIM.RoofThickness / 2 + ROOF_CLEAR)
		if x2 - x1 > EPS and z2 - z1 > EPS and top - GROUND_Y > EPS then
			local probe = Instance.new("Part")
			probe.Name = "InteriorProbe"
			probe.Anchored = true
			probe.CanCollide = false
			probe.Transparency = 1
			probe.Size = Vector3.new(x2 - x1, top - GROUND_Y, z2 - z1)
			probe.CFrame = CFrame.new((x1 + x2) / 2, (GROUND_Y + top) / 2, (z1 + z2) / 2)
			probe.Parent = Workspace

			for _, part in ipairs(Workspace:GetPartsInPart(probe, params)) do
				table.insert(hits, { room = room.name, part = part.Name })
			end
			probe:Destroy()
		end
	end
	return hits
end

-- ------------------------------------------------------------
-- ROOF COVERAGE CHECK. Every ground room's ceiling must sit under roof volume.
-- Done by rectangle subtraction rather than a point sample, so a room half
-- covered by a wing that stops short of it reports the uncovered remainder
-- instead of passing on its center point.
-- ------------------------------------------------------------
local function checkRoofCoverage(ctx)
	local exposed = {}
	for _, entry in ipairs(ctx.rectsByFloor.Ground) do
		local room = entry.room
		if room.ceiling ~= false then
			local ceilingTop = GROUND_Y + roomHeight(room)
			-- Only wings seated at or above this room's ceiling can shelter it; a
			-- lower wing's roof would be passing THROUGH the room, not over it.
			local shelters = {}
			for _, wing in ipairs(PLAN.Roofs) do
				local wingEave = GROUND_Y + wing.wallHeight + DIM.CeilingThickness
				if wingEave >= ceilingTop - EPS then
					table.insert(shelters, wing.rect)
				end
			end
			for _, gap in ipairs(rectSubtractMany({ entry.rect }, shelters)) do
				table.insert(exposed, string.format("%s open to sky over X[%.0f..%.0f] Z[%.0f..%.0f]",
					room.name, gap[1], gap[3], gap[2], gap[4]))
			end
		end
	end
	return exposed
end

-- ------------------------------------------------------------
-- DOUBLE-HEIGHT ASSERTION. The flag was already honored - roomHeight() is the
-- single source both the ceiling pass and the wall pass read - but "it looked
-- short in a screenshot" is not something to answer from memory, so the built
-- result is now measured and reported every build.
-- ------------------------------------------------------------
local function checkDoubleHeight(ctx)
	local results = {}
	for _, room in ipairs(PLAN.Rooms) do
		if room.doubleHeight then
			local built = ctx.ceilingTops[room.name]
			table.insert(results, {
				name = room.name,
				built = built,
				ok = built ~= nil and math.abs(built - (GROUND_Y + DIM.DoubleHeight)) < EPS,
			})
		end
	end
	return results
end

-- ------------------------------------------------------------
-- GROUNDS. The manor was reading as a model floating over void. A single earth
-- slab whose TOP is flush with the underside of the ground floor buries the
-- whole cellar and gives every exterior wall something to meet, and a stone
-- plinth skirt around the exterior wall base makes that meeting deliberate
-- rather than a seam.
--
-- TWO BURIAL FIXES LIVE HERE, both of them "the cellar must not be visible":
-- the TURF CAP that closes the lawn over the sunk vault lids, and the plinth's
-- restriction to EXTERIOR faces. Read their comments before moving either.
-- ------------------------------------------------------------
local function buildGrounds(ctx)
	local folder = Instance.new("Folder")
	folder.Name = "Grounds"
	folder.Parent = ctx.model
	ctx.groundsFolder = folder

	local b = ctx.fullBounds
	local m = DIM.GroundsMargin
	-- Grass top = underside of the ground floor slab = where a wall meets earth.
	local grassTop = GROUND_Y - DIM.FloorThickness
	local earthBottom = grassTop - DIM.GroundsThickness
	local outer = { b[1] - m, b[2] - m, b[3] + m, b[4] + m }

	-- THE EARTH MUST NOT FILL THE CELLAR. A single slab this deep would swallow
	-- the whole cellar volume in solid grass, so it is emitted in two parts: the
	-- ground AROUND the cellar footprint at full depth, and a floor UNDER the
	-- cellar from the bottom of its slab downward. Between them the cellar is
	-- enclosed by earth on every side without any of it reaching inside.
	local cellarRects = {}
	for _, entry in ipairs(ctx.rectsByFloor.Cellar or {}) do
		table.insert(cellarRects, entry.rect)
	end

	for _, piece in ipairs(rectSubtractMany({ outer }, cellarRects)) do
		box(folder, "Earth", piece[1], earthBottom, piece[2], piece[3], grassTop, piece[4],
			MATERIALS.Grass, PALETTE.Grass, { castShadow = false })
	end
	for _, rect in ipairs(cellarRects) do
		box(folder, "EarthUnderCellar", rect[1], earthBottom, rect[2],
			rect[3], CELLAR_Y - DIM.FloorThickness, rect[4],
			MATERIALS.Grass, PALETTE.Grass, { castShadow = false })
	end

	-- TURF OVER THE BURIED VAULTS. The earth slab above is punched out over the
	-- WHOLE cellar footprint, which is right where the manor stands on it and
	-- wrong where it does not - that hole is what left the vault lids showing as
	-- bare stone. buildFloorsAndCeilings sank those lids by DIM.VaultCover and
	-- handed back their rects; this fills the gap with the same grass as the rest
	-- of the grounds. It is COLLIDABLE, because out there this IS the lawn a
	-- player walks on: the lid no longer carries them, the turf does.
	--
	-- CARVED BACK OFF THE FOOTPRINT BOUNDARY. The fascia strips the floor pass
	-- emitted (see VaultFascia) already close the ceiling step in stone; carving
	-- the same strips out of the turf means no grass even REACHES the boundary,
	-- so there is nothing there to be seen from the cellar whether the fascia is
	-- in front of it or not. Belt and braces, deliberately: "covered up" and "not
	-- there" fail differently, and only one of them survives someone later moving
	-- the fascia.
	for _, piece in ipairs(rectSubtractMany(ctx.buriedRects, ctx.fasciaRects)) do
		box(folder, "TurfCap", piece[1], grassTop - DIM.VaultCover, piece[2],
			piece[3], grassTop, piece[4],
			MATERIALS.Grass, PALETTE.Grass, { castShadow = false })
	end

	-- Plinth skirt, following the real exterior outline collected by the wall
	-- pass, from the wall centerline OUTWARD ONLY.
	--
	-- EXTERIOR FACE ONLY, and that restriction is the fix for the interior base
	-- strips. This skirt used to be centered on the wall plane with a half-width
	-- of WallThickness/2 + PlinthProud, so it stood 0.6 studs proud of the INSIDE
	-- face too, and its top at grassTop + PlinthHeight is half a stud above the
	-- finished floor - a gray Slate strip running along the base of every interior
	-- face of an exterior wall, most visible in the Séance Parlor. Reaching only
	-- outward keeps the base course reading as a base course from the grounds
	-- while leaving nothing of it inside any room.
	local reach = DIM.WallThickness / 2 + DIM.PlinthProud
	for _, run in ipairs(ctx.exteriorRuns) do
		local outer = run.coord + run.outDir * reach
		local lo, hi = math.min(run.coord, outer), math.max(run.coord, outer)
		if run.axis == "X" then
			box(folder, "Plinth", lo, grassTop, run.a,
				hi, grassTop + DIM.PlinthHeight, run.b,
				MATERIALS.Plinth, PALETTE.Stone)
		else
			box(folder, "Plinth", run.a, grassTop, lo,
				run.b, grassTop + DIM.PlinthHeight, hi,
				MATERIALS.Plinth, PALETTE.Stone)
		end
	end
end

-- ============================================================
-- ============================================================
-- THE DRESSING PASS - props, lamps, stations and the ritual heart.
--
-- Same PLAN + interpreter split as the shell: everything below reads PLAN.Furnish
-- / .Stations / .Sabotage / .Lamps / .Secrets and turns it into parts. Moving a
-- sofa is a data edit. The KITS table is the vocabulary those tables speak in.
-- ============================================================
-- ============================================================

-- ------------------------------------------------------------
-- PROP PRIMITIVES. Furniture is described the way a person describes it - "3
-- studs tall, standing here" - so every kit passes a floor Y and a footprint
-- centre instead of the world-space bounds pairs the shell's box() wants.
-- ------------------------------------------------------------
local function propBox(folder, name, cx, baseY, cz, sx, sy, sz, mat, color, opts)
	if sx <= EPS or sy <= EPS or sz <= EPS then
		return nil
	end
	return makePart(folder, name, Vector3.new(sx, sy, sz),
		CFrame.new(cx, baseY + sy / 2, cz), mat, color, opts)
end

-- Same, yawed about Y. Chairs looking at a table and pews looking at an altar are
-- the only reason this exists.
local function propYaw(folder, name, cx, baseY, cz, sx, sy, sz, yaw, mat, color, opts)
	if sx <= EPS or sy <= EPS or sz <= EPS then
		return nil
	end
	return makePart(folder, name, Vector3.new(sx, sy, sz),
		CFrame.new(cx, baseY + sy / 2, cz) * CFrame.Angles(0, yaw, 0), mat, color, opts)
end

-- A cylinder STANDING ON ITS BASE. Roblox cylinders run along the part's local X,
-- so the size is (height, diameter, diameter) and the part is rolled upright.
-- Table pedestals, pipes, the boiler drum, brazier stems, lamp cords.
local function cylinderUp(folder, name, cx, baseY, cz, diameter, height, mat, color, opts)
	if diameter <= EPS or height <= EPS then
		return nil
	end
	local part = makePart(folder, name, Vector3.new(height, diameter, diameter),
		CFrame.new(cx, baseY + height / 2, cz) * CFrame.Angles(0, 0, math.pi / 2),
		mat, color, opts)
	part.Shape = Enum.PartType.Cylinder
	return part
end

-- A sphere at an absolute Y (bulbs hang, they do not stand).
local function sphereAt(folder, name, cx, cy, cz, diameter, mat, color, opts)
	local part = makePart(folder, name, Vector3.new(diameter, diameter, diameter),
		CFrame.new(cx, cy, cz), mat, color, opts)
	part.Shape = Enum.PartType.Ball
	return part
end

-- Compass letters to unit directions, on the file's convention (N = -Z, S = +Z,
-- E = +X, W = -X). `face` in the PLAN tables always means "the way this prop
-- projects INTO the room", so a sconce on the west wall of a room faces East.
local FACE_DIR = { N = { 0, -1 }, S = { 0, 1 }, E = { 1, 0 }, W = { -1, 0 } }

local function faceDir(face)
	local d = FACE_DIR[face] or FACE_DIR.S
	return d[1], d[2]
end

-- The yaw that points a part's local +Z along `face`. R_y(θ) sends (0,0,1) to
-- (sin θ, 0, cos θ), which is where these four values come from.
local function faceYaw(face)
	if face == "N" then
		return math.pi
	elseif face == "E" then
		return math.pi / 2
	elseif face == "W" then
		return -math.pi / 2
	end
	return 0
end

-- The Y a CELLAR prop hangs from. The cellar's lid sits at the ground slab's
-- underside where the manor stands over it and DIM.VaultCover lower where it does
-- not (the burial rule), so a cord hung at one fixed height would punch up through
-- the lawn out past the footprint. checkBurial() would catch that; this stops it
-- happening in the first place.
local function cellarCeilingY(ctx, x, z)
	for _, entry in ipairs(ctx.rectsByFloor.Ground) do
		local r = entry.rect
		if x >= r[1] - EPS and x <= r[3] + EPS and z >= r[2] - EPS and z <= r[4] + EPS then
			return GROUND_Y - DIM.FloorThickness
		end
	end
	return GROUND_Y - DIM.FloorThickness - DIM.VaultCover
end

-- ------------------------------------------------------------
-- A BARE ProximityPrompt, AND DELIBERATELY BARE.
--
-- TaskStationHandler, SabotageStationHandler and EmergencyButtonHandler each
-- configure the prompts they adopt - Style, ActionText, HoldDuration and the
-- E-only ClickablePrompt = false rule that exists because mouse clicks were
-- leaking through open task windows and re-triggering the station behind them.
-- If this file set any of that too, the MAP would become a second source of truth
-- for prompt behaviour and would drift from the handlers the first time either
-- side changed. The map's whole obligation is that a prompt EXISTS to adopt.
-- ------------------------------------------------------------
local function addPrompt(part)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Prompt"
	prompt.Parent = part
	return prompt
end

-- ============================================================
-- *** RESERVED ANCHOR FOR THE DIEGETIC-TASK ANIMATION PASS. ***
--
-- Every task and fix station carries one of these: an invisible, non-colliding,
-- non-queryable marker recording WHERE A PLAYER WILL STAND, and which way they
-- will be facing, while working that station.
--
-- IT IS NOT DECORATION, IT IS NOT A SPAWN, AND IT IS NOT LIVE YET. Today the ten
-- tasks and the two fix minigames are played in a floating window in the middle
-- of the screen. The intent on record is that REPAIRS WILL BE PERFORMED HERE -
-- the character walks to this point, turns to face the object, and plays the
-- animation in the world with the window reduced or gone. When that pass lands,
-- THIS is the transform it snaps the character to, which is why it is authored
-- now, next to the object, by the person who knows which side of it you use.
--
-- DO NOT delete, rename or reparent these, and NEVER give one collision - a solid
-- block standing in front of every station would wall players out of their own
-- tasks and the failure would look like a task bug, not a map bug.
-- ============================================================
local function addInteractPoint(part, x, y, z, lookX, lookZ)
	local point = Instance.new("Part")
	point.Name = "InteractPoint"
	point.Anchored = true
	point.CanCollide = false
	point.CanQuery = false
	point.CanTouch = false
	point.Transparency = 1
	point.CastShadow = false
	point.Size = Vector3.new(2, 0.2, 2)
	point.CFrame = CFrame.new(Vector3.new(x, y, z), Vector3.new(lookX, y, lookZ))
	point.Parent = part
	counters.parts = counters.parts + 1
	return point
end

-- One warm bulb, tagged so LightsSystem owns it. THE TAG GOES ON THE BULB and the
-- PointLight is its child - see PLAN.Lamps for why tagging the fixture instead
-- leaves neon bulbs glowing through a blackout.
local function addBulb(folder, cx, cy, cz, diameter, brightness, range)
	local bulb = sphereAt(folder, "LampBulb", cx, cy, cz, diameter,
		MATERIALS.Bulb, PALETTE.Candlelight, { canCollide = false, castShadow = false })
	local light = Instance.new("PointLight")
	light.Name = "Glow"
	light.Color = PALETTE.Candlelight
	light.Brightness = brightness
	light.Range = range
	light.Shadows = false
	light.Parent = bulb
	CollectionService:AddTag(bulb, TAGS.RoomLamp)
	counters.lights = counters.lights + 1
	return bulb
end

-- ============================================================
-- KITS - the prop vocabulary. Every kit is
--     KITS.Name(ctx, folder, entry, baseY)
-- where `entry` is the PLAN row (so a kit reads its own extra fields) and `baseY`
-- is the floor it stands on. STATION kits additionally RETURN the part that
-- carries the runtime contract, so the object itself is the station and never a
-- floating cube parked next to it.
-- ============================================================
local KITS = {}

-- ---------- Soft furnishing ----------
KITS.Rug = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local sx, sz = e.sx or 16, e.sz or 12
	propBox(folder, "RugBorder", x, baseY, z, sx, 0.08, sz, MATERIALS.Trim, PALETTE.TrimBrass,
		{ canCollide = false, castShadow = false })
	propBox(folder, "Rug", x, baseY + 0.08, z, sx - 1.6, 0.1, sz - 1.6, MATERIALS.Fabric, PALETTE.ClothGreen,
		{ canCollide = false, castShadow = false })
end

KITS.CoatStand = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	cylinderUp(folder, "CoatStandBase", x, baseY, z, 2.2, 0.3, MATERIALS.Timber, PALETTE.DarkWood)
	cylinderUp(folder, "CoatStandPost", x, baseY, z, 0.5, 7.5, MATERIALS.Timber, PALETTE.DarkWood)
	for i = 0, 3 do
		local a = i * math.pi / 2
		propYaw(folder, "CoatPeg", x + math.cos(a) * 0.7, baseY + 6.8, z + math.sin(a) * 0.7,
			1.6, 0.25, 0.25, -a, MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	end
end

KITS.SideTable = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local dx = select(1, faceDir(e.face))
	-- Long axis runs ALONG the wall the table leans on: a console pushed against a
	-- wall is long and shallow, never square.
	local sx = (dx ~= 0) and 1.6 or 4.5
	local sz = (dx ~= 0) and 4.5 or 1.6
	propBox(folder, "TableTop", x, baseY + 2.4, z, sx, 0.3, sz, MATERIALS.Timber, PALETTE.DarkWood)
	local ox, oz = sx / 2 - 0.3, sz / 2 - 0.3
	for _, s in ipairs({ { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } }) do
		propBox(folder, "TableLeg", x + s[1] * ox, baseY, z + s[2] * oz, 0.35, 2.4, 0.35,
			MATERIALS.Timber, PALETTE.DarkWood)
	end
end

-- ============================================================
-- WALL RUNS. Anything hung at regular intervals along a wall - portraits,
-- corridor sconces - is placed by these, and NEVER by a hand-written list of
-- coordinates.
--
-- The hand-written lists are what produced both defects this pass is fixing:
-- portrait frames sitting on top of windows and doorways, because nobody
-- cross-checked twelve coordinates against the opening table; and a 30-stud
-- unlit stretch in the middle of the Gallery, because eyeballed spacing drifts.
-- A run derives its own positions from the wall it is on, subtracts every
-- opening the plan puts in that wall, and spaces what survives evenly.
-- ============================================================

-- The solid stretches of one wall plane: the span minus every door and window
-- opening on it, each widened by `margin` so a frame or a bracket cannot crowd
-- an opening's trim. Read straight out of ctx.openings, which IS what the wall
-- pass cut the holes from - so this can never disagree with the built wall.
local function solidSpansOn(ctx, floorName, axis, coord, span, margin)
	local cuts = {}
	for _, opening in ipairs((ctx.openings[floorName][axis][coord]) or {}) do
		table.insert(cuts, { opening.a - margin, opening.b + margin })
	end
	return subtractSpans({ span }, mergeSpans(cuts))
end

-- Evenly spaced positions inside one solid stretch, at most `maxGap` apart, with
-- the item's own width kept inside the stretch at both ends.
--
-- EDGE-ANCHORED, NOT CENTRED, AND THAT IS THE WHOLE POINT. A stretch is only ever
-- one PIECE of a wall - the openings have already been cut out of it - so the gap
-- a player actually walks through is the one that spans a doorway, from the last
-- item on one side to the first on the other. Centring each stretch's items
-- pushes both of those away from the opening and adds most of the stretch's end
-- margins to that gap: it is what left a twenty-stud unlit stretch across the
-- Great Hall's stair doorway even though every individual stretch looked evenly
-- lit. Anchoring the first and last item to the stretch ends bounds the
-- cross-opening gap at roughly the opening's own width.
local function spaceAlong(lo, hi, maxGap, item)
	local first, last = lo + item / 2, hi - item / 2
	local usable = last - first
	if usable < -EPS then
		return {}
	end
	-- Too short to be worth more than one: centre it and let the neighbours carry
	-- the run. (Also the only sane answer when usable is zero.)
	if usable <= maxGap / 2 then
		return { (lo + hi) / 2 }
	end
	local n = math.max(2, math.ceil(usable / maxGap) + 1)
	local out = {}
	for i = 1, n do
		table.insert(out, first + usable * (i - 1) / (n - 1))
	end
	return out
end

-- The Gallery's portrait run. Hung ABOVE the wainscot line (DIM.WainscotHeight),
-- because a painting whose frame crosses the chair rail looks like a mistake.
-- The canvases are deliberately near-black: a row of unreadable dark faces down a
-- long corridor is the cheapest gaslight-occult beat in the manor.
KITS.PortraitRun = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local alongX = (e.wall == "Z")
	local w, h = e.w or 4, e.h or 6
	local pitch = e.pitch or 12

	for _, solid in ipairs(solidSpansOn(ctx, "Ground", e.wall, e.coord, { e.from, e.to }, 1.5)) do
		for _, at in ipairs(spaceAlong(solid[1], solid[2], pitch, w)) do
			local x = alongX and at or (e.coord + dx * 0.4)
			local z = alongX and (e.coord + dz * 0.4) or at
			propBox(folder, "PortraitFrame", x, baseY + DIM.WainscotHeight, z,
				alongX and w or 0.4, h, alongX and 0.4 or w,
				MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
			propBox(folder, "PortraitCanvas", x + dx * 0.12, baseY + DIM.WainscotHeight + 0.6, z + dz * 0.12,
				alongX and w - 1 or 0.35, h - 1.2, alongX and 0.35 or w - 1,
				MATERIALS.Paper, PALETTE.Canvas, { canCollide = false })
		end
	end
end

-- A corridor's sconces, ALTERNATING BETWEEN ITS TWO WALLS.
--
-- The Gallery is why. Lighting one wall at a tight interval put a sconce every
-- few studs down a 146-stud corridor and the whole thing read as a lit runway -
-- and the fix is not fewer lamps on one wall, it is the same lamps STAGGERED, so
-- the light comes from alternating sides and the space between reads as depth
-- rather than as a gap somebody forgot. Positions are struck along the corridor
-- at DIM.SconceSpacing and handed to the walls in turn.
--
-- A wall is only usable where SOLID WALL WAS ACTUALLY BUILT. `ctx.solid` is the
-- wall pass's own record of what it emitted, so this cannot disagree with the
-- geometry: a doorway, a window, or a plane with no wall at all (the Gallery's
-- two rects meet with nothing between them) simply hands that position to the
-- opposite wall, and if neither will take it the position is dropped.
KITS.SconceRun = function(ctx, folder, e, baseY)
	local alongX = (e.wall == "Z")
	local walls = e.walls
	local reach = 0.8 -- half a bracket: the whole fixture has to be on solid wall

	for index, at in ipairs(spaceAlong(e.from, e.to, e.spacing or DIM.SconceSpacing, 2)) do
		local first = ((index - 1) % #walls) + 1
		local order = { walls[first] }
		for j = 1, #walls do
			if j ~= first then
				table.insert(order, walls[j])
			end
		end
		for _, wall in ipairs(order) do
			local solid = ctx.solid.Ground[e.wall][wall.coord]
			if solid and spansContain(solid, at - reach) and spansContain(solid, at + reach) then
				local x = alongX and at or wall.coord
				local z = alongX and wall.coord or at
				KITS.Sconce(ctx, folder, { at = { x, z }, face = wall.face }, baseY)
				break
			end
		end
	end
end

KITS.Chair = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local yaw = e.yaw or 0
	propYaw(folder, "ChairSeat", x, baseY + 1.5, z, 1.8, 0.25, 1.8, yaw, MATERIALS.Timber, PALETTE.DarkWood)
	propYaw(folder, "ChairBack", x - math.sin(yaw) * 0.8, baseY + 1.7, z - math.cos(yaw) * 0.8,
		1.8, 2.2, 0.25, yaw, MATERIALS.Timber, PALETTE.DarkWood)
	for _, s in ipairs({ { -0.7, -0.7 }, { -0.7, 0.7 }, { 0.7, -0.7 }, { 0.7, 0.7 } }) do
		propBox(folder, "ChairLeg", x + s[1], baseY, z + s[2], 0.22, 1.5, 0.22,
			MATERIALS.Timber, PALETTE.DarkWood)
	end
end

-- ---------- Shelving and books ----------
-- ONE BOOK SIZE FOR THE WHOLE MANOR. Three kits were each inventing their own
-- proportions - 0.9 x 1.05-1.41 here, 0.5 x 1.0 x 1.4 on the sorting trolley, a
-- single 4.2-stud slab in the secret bookcase - so the same object read as three
-- different things depending on which room you were standing in. Every book in
-- the manor now comes out of this one function at DIM.BookWidth x DIM.BookHeight,
-- with only a deterministic hair of height variation so a row is not a solid bar.
local BOOK_COLORS = { PALETTE.BookRed, PALETTE.BookBlue, PALETTE.BookTan }

local function bookRow(folder, alongX, cLo, cHi, baseY, other, depth, seed)
	local run = cHi - cLo
	local slots = math.floor(run / (DIM.BookWidth + 0.25))
	for i = 1, slots do
		local t = (i - 0.5) / slots
		local along = cLo + run * t
		-- DETERMINISTIC VARIATION. There is no math.random anywhere in this file:
		-- two builds of the same plan must come out identical, or "idempotent by
		-- construction" is a slogan rather than a property.
		local color = BOOK_COLORS[((i + seed * 2) % 3) + 1]
		local h = DIM.BookHeight + ((i + seed) % 3) * 0.12
		local bx = alongX and along or other
		local bz = alongX and other or along
		propBox(folder, "Book", bx, baseY, bz,
			alongX and DIM.BookWidth or depth, h, alongX and depth or DIM.BookWidth,
			MATERIALS.Paper, color, { canCollide = false })
	end
end

-- An open case: back panel, two ends, a BOTTOM at floor level, a top, and shelf
-- boards. `face` is the way the OPEN FRONT looks, which decides which side the
-- back panel goes on.
--
-- THE BOTTOM BOARD IS NOT DECORATION. Without it the lowest shelf was a plank
-- floating four tenths of a stud off the floorboards with a shadow gap under it,
-- which is what "sunken units" looks like from inside the room. Every case now
-- SITS on the floor and every book sits on a board.
local function shelfCase(folder, x, z, baseY, len, height, depth, alongX, dx, dz, nameStem)
	local sx = alongX and len or depth
	local sz = alongX and depth or len
	propBox(folder, nameStem .. "Back", x - dx * (depth / 2 - 0.2), baseY, z - dz * (depth / 2 - 0.2),
		alongX and len or 0.4, height, alongX and 0.4 or len, MATERIALS.Timber, PALETTE.DarkWood)
	for _, s in ipairs({ -1, 1 }) do
		propBox(folder, nameStem .. "End",
			x + (alongX and s * (len / 2 - 0.2) or 0), baseY,
			z + (alongX and 0 or s * (len / 2 - 0.2)),
			alongX and 0.4 or depth, height, alongX and depth or 0.4,
			MATERIALS.Timber, PALETTE.DarkWood)
	end
	propBox(folder, nameStem .. "Bottom", x, baseY, z, sx, 0.3, sz, MATERIALS.Timber, PALETTE.DarkWood)
	propBox(folder, nameStem .. "Top", x, baseY + height - 0.3, z, sx, 0.3, sz,
		MATERIALS.Timber, PALETTE.DarkWood)
end

KITS.Bookshelves = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local len = e.len or 10
	local height, depth = DIM.ShelfHeight, DIM.ShelfDepth
	local alongX = (e.along ~= "Z")
	local dx, dz = faceDir(e.face)
	shelfCase(folder, x, z, baseY, len, height, depth, alongX, dx, dz, "Shelf")

	local run = len - 0.8
	local lo = (alongX and x or z) - run / 2
	local hi = lo + run
	-- Four bays above the bottom board, the lowest sitting ON it.
	for s = 1, 4 do
		local y = baseY + 0.3 + (s - 1) * 1.85
		propBox(folder, "ShelfBoard", x, y, z, alongX and run or depth - 0.4, 0.2,
			alongX and depth - 0.4 or run, MATERIALS.Timber, PALETTE.DarkWood)
		bookRow(folder, alongX, lo, hi, y + 0.2,
			(alongX and z or x) + (alongX and dz or dx) * 0.15, depth - 0.7, s)
	end
end

KITS.Shelving = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local len = e.len or 12
	local alongX = (e.along ~= "Z")
	local depth, height = 2, 7
	for _, s in ipairs({ -1, 1 }) do
		propBox(folder, "ShelfUpright",
			x + (alongX and s * (len / 2) or 0), baseY,
			z + (alongX and 0 or s * (len / 2)),
			alongX and 0.3 or depth, height, alongX and depth or 0.3,
			MATERIALS.Iron, PALETTE.Iron)
	end
	for s = 1, 4 do
		propBox(folder, "ShelfBoard", x, baseY + 0.8 + (s - 1) * 1.9, z,
			alongX and len or depth, 0.2, alongX and depth or len,
			MATERIALS.Timber, PALETTE.DarkWood)
	end
end

KITS.Crates = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local count = e.count or 3
	for i = 1, count do
		-- Deterministic scatter: a fixed lattice with a fixed stagger, so a crate
		-- pile looks tumbled without a random seed in an idempotent tool.
		local ox = ((i - 1) % 3) * 2.6 - 2.6
		local oz = math.floor((i - 1) / 3) * 2.6
		local size = 2 + ((i % 3) * 0.3)
		local stacked = (i % 4 == 0) and (2 + 0.3) or 0
		propYaw(folder, "Crate", x + ox, baseY + stacked, z + oz, size, size, size,
			(i % 3) * 0.25, MATERIALS.Timber, PALETTE.DarkWood)
	end
end

-- ---------- Desks, tables, seating ----------
KITS.Desk = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local dx, dz = faceDir(e.face)
	local sx = (dx ~= 0) and 3 or 6
	local sz = (dx ~= 0) and 6 or 3
	propBox(folder, "DeskTop", x, baseY + 2.6, z, sx, 0.3, sz, MATERIALS.Timber, PALETTE.DarkWood)
	for _, s in ipairs({ -1, 1 }) do
		propBox(folder, "DeskPedestal",
			x + (dx ~= 0 and 0 or s * (sx / 2 - 0.7)), baseY,
			z + (dx ~= 0 and s * (sz / 2 - 0.7) or 0),
			(dx ~= 0) and sx - 0.6 or 1.2, 2.6, (dx ~= 0) and 1.2 or sz - 0.6,
			MATERIALS.Timber, PALETTE.DarkWood)
	end
	KITS.Chair(ctx, folder, { at = { x + dx * 2.8, z + dz * 2.8 }, yaw = faceYaw(e.face) + math.pi }, baseY)
end

KITS.DiningTable = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local len = e.len or 18
	local seats = e.seats or 6
	propBox(folder, "DiningTop", x, baseY + 2.8, z, len, 0.4, 5, MATERIALS.Timber, PALETTE.DarkWood)
	propBox(folder, "DiningRunner", x, baseY + 3.2, z, len - 2, 0.08, 2.2,
		MATERIALS.Fabric, PALETTE.ClothGreen, { canCollide = false })
	for _, s in ipairs({ -1, 1 }) do
		propBox(folder, "DiningTrestle", x + s * (len / 2 - 1.5), baseY, z, 1, 2.8, 4,
			MATERIALS.Timber, PALETTE.DarkWood)
	end
	-- Candlesticks down the centre line: unlit dressing, NOT lamps. Nothing here
	-- is tagged RoomLamp, so a blackout leaves them exactly as they are.
	for i = 1, 3 do
		local cxi = x - len / 4 + (i - 1) * (len / 4)
		cylinderUp(folder, "Candlestick", cxi, baseY + 3, z, 0.4, 1.6, MATERIALS.Trim, PALETTE.TrimBrass)
		cylinderUp(folder, "Candle", cxi, baseY + 4.6, z, 0.3, 1.1, MATERIALS.Paper, PALETTE.Bone)
	end
	for i = 1, seats do
		local t = (i - 0.5) / seats
		local sxp = x - (len / 2 - 1) + (len - 2) * t
		KITS.Chair(ctx, folder, { at = { sxp, z - 3.6 }, yaw = 0 }, baseY)
		KITS.Chair(ctx, folder, { at = { sxp, z + 3.6 }, yaw = math.pi }, baseY)
	end
end

KITS.PewRow = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local len = e.len or 16
	propBox(folder, "PewSeat", x, baseY + 1.6, z, len, 0.3, 1.6, MATERIALS.Timber, PALETTE.DarkWood)
	propBox(folder, "PewCushion", x, baseY + 1.9, z, len - 0.5, 0.15, 1.3,
		MATERIALS.Fabric, PALETTE.ClothGreen, { canCollide = false })
	-- The back is on the SOUTH side because Chapel pews all look north to the altar.
	propBox(folder, "PewBack", x, baseY + 1.9, z + 0.85, len, 2.2, 0.3, MATERIALS.Timber, PALETTE.DarkWood)
	for _, s in ipairs({ -1, 1 }) do
		propBox(folder, "PewEnd", x + s * (len / 2 - 0.2), baseY, z, 0.4, 1.6, 1.8,
			MATERIALS.Timber, PALETTE.DarkWood)
	end
end

KITS.Altar = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	propBox(folder, "AltarStep", x, baseY, z, 10, 0.5, 5, MATERIALS.Stonework, PALETTE.Stone)
	propBox(folder, "AltarBlock", x, baseY + 0.5, z, 7, 2.6, 3, MATERIALS.Stonework, PALETTE.Stone)
	propBox(folder, "AltarCloth", x, baseY + 3.1, z, 7.4, 0.12, 3.4,
		MATERIALS.Fabric, PALETTE.Bone, { canCollide = false })
	for _, s in ipairs({ -2.2, 2.2 }) do
		cylinderUp(folder, "AltarCandlestick", x + s, baseY + 3.2, z, 0.4, 1.4, MATERIALS.Trim, PALETTE.TrimBrass)
		cylinderUp(folder, "AltarCandle", x + s, baseY + 4.6, z, 0.3, 1.4, MATERIALS.Paper, PALETTE.Bone)
	end
end

-- ---------- Service rooms ----------
KITS.CounterRun = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local len = e.len or 12
	local alongX = (e.along ~= "Z")
	local depth = 2.4
	propBox(folder, "CounterCarcass", x, baseY, z, alongX and len or depth, 2.8, alongX and depth or len,
		MATERIALS.Timber, PALETTE.DarkWood)
	propBox(folder, "CounterTop", x, baseY + 2.8, z, alongX and len or depth + 0.3, 0.3,
		alongX and depth + 0.3 or len, MATERIALS.Stonework, PALETTE.Stone)
	local doors = math.max(1, math.floor(len / 3))
	for i = 1, doors do
		local t = (i - 0.5) / doors
		local px = alongX and (x - len / 2 + len * t) or (x + depth / 2)
		local pz = alongX and (z + depth / 2) or (z - len / 2 + len * t)
		propBox(folder, "CounterHandle", px, baseY + 2.1, pz, alongX and 0.9 or 0.12, 0.12,
			alongX and 0.12 or 0.9, MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	end
end

-- THE KITCHEN'S CENTRE PENDANT - a hanging pot rack that is also the room's main
-- light. Three things were wrong with it and all three are fixed here:
--
--   1. IT HUNG FROM NOTHING. Its chains stopped nearly three studs below the
--      ceiling, so the whole fixture floated. They now run to the actual ceiling,
--      derived from the room's own height.
--   2. IT HUNG TOO LOW. The bar sat at 7 studs with pots dangling to 5.4 - head
--      height in a room people run through. `clearance` is now the number that
--      drives the layout: it is the height the lowest thing on the fixture must
--      clear, and everything else is placed up from it.
--   3. IT EMITTED NO LIGHT. It looked exactly like a lamp, was not tagged, had no
--      PointLight, and so did nothing at all when the manor went dark. It is now
--      a proper RoomLamp per LightsSystem's contract - and checkManifest counts
--      unlit lamps every build so this class cannot come back quietly.
KITS.HangingPendant = function(ctx, folder, e, baseY)
	local room = ctx.rooms[e.room]
	local x, z = e.at[1], e.at[2]
	local len = e.len or 8
	local ceilingY = baseY + roomHeight(room)
	local dia = 1
	local bulbY = baseY + (e.clearance or 9.5) + dia / 2
	local barY = bulbY + 0.9

	propBox(folder, "PendantBar", x, barY, z, len, 0.25, 0.25,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	for _, s in ipairs({ -1, 1 }) do
		propBox(folder, "PendantChain", x + s * (len / 2 - 0.3), barY + 0.25, z, 0.15,
			ceilingY - (barY + 0.25), 0.15, MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	end

	-- Pots between the bulbs, hung so their undersides clear the same line.
	local pots = math.max(2, math.floor(len / 2.6))
	for i = 1, pots do
		local t = (i - 0.5) / pots
		cylinderUp(folder, "Pot", x - len / 2 + len * t, bulbY + 0.05, z, 1.2 + (i % 2) * 0.4, 0.85,
			MATERIALS.Iron, PALETTE.Iron, { canCollide = false })
	end
	for _, s in ipairs({ -1, 1 }) do
		addBulb(folder, x + s * (len / 2 - 1), bulbY, z, dia, DIM.ChandelierBright, DIM.ChandelierRange)
	end
end

-- A shelf mounted FLUSH on a wall face, with crockery on it. `at` is on the wall
-- plane and the back board sits on the wall's inner face - not a stud off it,
-- which is what made the thing it replaces read as floating.
KITS.WallShelf = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local len = e.len or 8
	local depth = 1.2
	local alongX = (dx == 0)
	local off = DIM.WallThickness / 2 + depth / 2
	local x, z = e.at[1] + dx * off, e.at[2] + dz * off
	local sx = alongX and len or depth
	local sz = alongX and depth or len

	for _, level in ipairs({ e.y or 5.5, (e.y or 5.5) + 2 }) do
		propBox(folder, "ShelfBoard", x, baseY + level, z, sx, 0.25, sz,
			MATERIALS.Timber, PALETTE.DarkWood)
		-- Brackets under each board, back against the wall.
		for _, s in ipairs({ -1, 1 }) do
			propBox(folder, "ShelfBracket",
				x + (alongX and s * (len / 2 - 0.6) or 0), baseY + level - 0.7,
				z + (alongX and 0 or s * (len / 2 - 0.6)),
				alongX and 0.3 or depth, 0.7, alongX and depth or 0.3,
				MATERIALS.Iron, PALETTE.Iron, { canCollide = false })
		end
	end

	local items = math.max(2, math.floor(len / 1.6))
	for i = 1, items do
		local t = (i - 0.5) / items
		local at = (alongX and (x - len / 2 + len * t) or (z - len / 2 + len * t))
		local cx = alongX and at or x
		local cz = alongX and z or at
		cylinderUp(folder, "Crockery", cx, baseY + (e.y or 5.5) + 0.25, cz,
			0.9 + (i % 2) * 0.3, 0.8, MATERIALS.Paper, PALETTE.Bone, { canCollide = false })
		cylinderUp(folder, "Crockery", cx, baseY + (e.y or 5.5) + 2.25, cz,
			0.8, 0.6, MATERIALS.Paper, PALETTE.Bone, { canCollide = false })
	end
end

-- A single hanging lantern on a chain - the Conservatory's own light, so the one
-- room roofed in glass no longer borrows its illumination from the Dining Hall
-- doorway. Hangs from the eave line, which is where its glass pitch is seated.
KITS.HangingLantern = function(ctx, folder, e, baseY)
	local room = ctx.rooms[e.room]
	local x, z = e.at[1], e.at[2]
	local ceilingY = baseY + roomHeight(room)
	local lanternY = baseY + (e.clearance or 9.5) + 1.1

	propBox(folder, "LanternChain", x, lanternY + 1.1, z, 0.15, ceilingY - (lanternY + 1.1), 0.15,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	propBox(folder, "LanternCap", x, lanternY + 0.9, z, 1.6, 0.25, 1.6,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	propBox(folder, "LanternBase", x, lanternY - 1.1, z, 1.6, 0.25, 1.6,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	for _, s in ipairs({ { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } }) do
		propBox(folder, "LanternPost", x + s[1] * 0.65, lanternY - 1.1, z + s[2] * 0.65, 0.15, 2, 0.15,
			MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	end
	addBulb(folder, x, lanternY, z, 1.2, DIM.ChandelierBright, DIM.ChandelierRange)
end

KITS.PrintLine = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local len = e.len or 10
	local y = baseY + 7.5
	propBox(folder, "PrintLine", x, y, z, len, 0.1, 0.1, MATERIALS.Paper, PALETTE.Bone, { canCollide = false })
	for i = 1, math.max(3, math.floor(len / 2)) do
		local t = (i - 0.5) / math.max(3, math.floor(len / 2))
		-- Hanging prints: the ambience-horror beat DESIGN.md section 4 asks the
		-- Darkroom for. What is ON them is an art-pass decal, not a builder concern.
		propBox(folder, "HangingPrint", x - len / 2 + len * t, y - 2.2, z, 1.6, 2.2, 0.06,
			MATERIALS.Paper, PALETTE.Canvas, { canCollide = false })
	end
end

KITS.WineRack = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local len = e.len or 16
	local alongX = (e.along ~= "Z")
	local depth, height = 2, 6.5
	for _, s in ipairs({ -1, 1 }) do
		propBox(folder, "RackUpright",
			x + (alongX and s * (len / 2) or 0), baseY,
			z + (alongX and 0 or s * (len / 2)),
			alongX and 0.35 or depth, height, alongX and depth or 0.35,
			MATERIALS.Timber, PALETTE.DarkWood)
	end
	for s = 1, 4 do
		local y = baseY + 0.9 + (s - 1) * 1.5
		propBox(folder, "RackBoard", x, y, z, alongX and len or depth, 0.2, alongX and depth or len,
			MATERIALS.Timber, PALETTE.DarkWood)
		local bottles = math.max(2, math.floor(len / 1.4))
		for i = 1, bottles do
			local t = (i - 0.5) / bottles
			local bx = alongX and (x - len / 2 + len * t) or x
			local bz = alongX and z or (z - len / 2 + len * t)
			cylinderUp(folder, "Bottle", bx, y + 0.2, bz, 0.8, 1.1,
				MATERIALS.Glass, PALETTE.Bottle, { canCollide = false })
		end
	end
end

KITS.Boiler = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	cylinderUp(folder, "BoilerDrum", x, baseY, z, 8, 8, MATERIALS.Iron, PALETTE.Iron)
	cylinderUp(folder, "BoilerCollar", x, baseY + 7.4, z, 8.6, 0.6, MATERIALS.Trim, PALETTE.TrimBrass)
	cylinderUp(folder, "BoilerFlue", x, baseY + 8, z, 1.6, 1.4, MATERIALS.Iron, PALETTE.Iron)
	propBox(folder, "BoilerFirebox", x, baseY, z + 4, 3.4, 3, 1.4, MATERIALS.Iron, PALETTE.Iron)
	for i = 1, 3 do
		propBox(folder, "BoilerRivetBand", x, baseY + 1 + (i - 1) * 2.6, z, 8.2, 0.3, 8.2,
			MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	end
end

-- ============================================================
-- THE BOILER ROOM'S PIPE WALL, and it is ONE ASSEMBLY with the FlowRoute station
-- that mounts on it. It was three loosely-related things before:
--   * the mains ran from `centre - len/2` while the station panel was placed at
--     its own unrelated coordinate, so three studs of panel hung past the end of
--     the run it was supposedly plugged into;
--   * the mains simply stopped in mid-air at both ends, with nothing to read as
--     a termination;
--   * a vertical drop landed exactly where the panel wanted to be.
--
-- Both kits now take the SAME `at` and `len`, so the panel is centred on the run
-- by construction rather than by two numbers agreeing. The run terminates at
-- flanges, and the drops skip the centre bay to leave the panel a clean mount.
-- PIPE_* below is the shared geometry both kits read.
-- ============================================================
local PIPE_STANDOFF = 1      -- mains this far off the wall plane
local PIPE_LEVELS = { 3, 6.5 }
local PIPE_BAY = 5           -- clear span at the centre of the run for the station

KITS.PipeWall = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local len = e.len or 16
	local dx, dz = faceDir(e.face)
	local px, pz = x + dx * PIPE_STANDOFF, z + dz * PIPE_STANDOFF
	local alongX = (dx == 0)
	local centre = alongX and x or z
	local lo, hi = centre - len / 2, centre + len / 2

	for _, y in ipairs(PIPE_LEVELS) do
		propBox(folder, "PipeMain", px, baseY + y, pz,
			alongX and len or 0.9, 0.9, alongX and 0.9 or len,
			MATERIALS.Iron, PALETTE.Copper, { canCollide = false })
		-- FLANGES, so a run ends at something instead of stopping in the air.
		for _, at in ipairs({ lo, hi }) do
			local fx = alongX and at or px
			local fz = alongX and pz or pz
			if not alongX then
				fz = at
			end
			propBox(folder, "PipeFlange", fx, baseY + y - 0.7, fz,
				alongX and 0.4 or 1.4, 1.4, alongX and 1.4 or 0.4,
				MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
		end
	end

	local drops = math.max(3, math.floor(len / 4))
	for i = 1, drops do
		local t = (i - 0.5) / drops
		local at = lo + len * t
		-- Leave the centre bay clear: that is where the station panel mounts.
		if math.abs(at - centre) > PIPE_BAY / 2 then
			local ox = alongX and at or px
			local oz = alongX and pz or at
			propBox(folder, "PipeDrop", ox, baseY, oz, 0.7, PIPE_LEVELS[2] + 0.5, 0.7,
				MATERIALS.Iron, PALETTE.Copper, { canCollide = false })
			cylinderUp(folder, "PipeValve", ox + dx * 0.5, baseY + 4.4, oz + dz * 0.5, 1.4, 0.3,
				MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
		end
	end
end

KITS.CisternBasin = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local sx, sz = e.sx or 18, e.sz or 18
	local kerb = 1.6
	-- Four kerb walls around a sunk water plane. The basin is a HOLE in the floor
	-- as far as the eye is concerned; the water slab is thin and non-colliding so
	-- nobody drowns in a graybox.
	propBox(folder, "BasinKerb", x, baseY, z - sz / 2 + kerb / 2, sx, 1.4, kerb, MATERIALS.Stonework, PALETTE.Stone)
	propBox(folder, "BasinKerb", x, baseY, z + sz / 2 - kerb / 2, sx, 1.4, kerb, MATERIALS.Stonework, PALETTE.Stone)
	propBox(folder, "BasinKerb", x - sx / 2 + kerb / 2, baseY, z, kerb, 1.4, sz - kerb * 2, MATERIALS.Stonework, PALETTE.Stone)
	propBox(folder, "BasinKerb", x + sx / 2 - kerb / 2, baseY, z, kerb, 1.4, sz - kerb * 2, MATERIALS.Stonework, PALETTE.Stone)
	propBox(folder, "BasinWater", x, baseY + 0.8, z, sx - kerb * 2, 0.2, sz - kerb * 2,
		MATERIALS.Glass, PALETTE.Water, { canCollide = false, transparency = 0.45, castShadow = false })
end

-- ---------- Conservatory ----------
KITS.PlanterBed = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local len = e.len or 14
	local alongX = (e.along ~= "Z")
	local width = 5
	local sx = alongX and len or width
	local sz = alongX and width or len
	propBox(folder, "PlanterKerb", x, baseY, z, sx, 1.8, sz, MATERIALS.Stonework, PALETTE.Stone)
	propBox(folder, "PlanterSoil", x, baseY + 1.4, z, sx - 1, 0.5, sz - 1, MATERIALS.Soil, PALETTE.Soil)
	-- PLANTS, not stumps. These were fat 2.4-stud cylinders sitting in the soil,
	-- which reads as a row of bollards. A slim trunk with a canopy on top is the
	-- minimum that says "plant" at graybox, and two sizes alternating stops the bed
	-- looking machine-planted.
	local plants = math.max(3, math.floor(len / 3))
	for i = 1, plants do
		local t = (i - 0.5) / plants
		local px = alongX and (x - len / 2 + len * t) or x
		local pz = alongX and z or (z - len / 2 + len * t)
		local big = (i % 2 == 0)
		local trunk = big and 3.2 or 2.2
		local canopy = big and 3.4 or 2.4
		cylinderUp(folder, "PlantTrunk", px, baseY + 1.8, pz, 0.5, trunk,
			MATERIALS.Timber, PALETTE.DarkWood, { canCollide = false })
		sphereAt(folder, "PlantCanopy", px, baseY + 1.8 + trunk + canopy / 2 - 0.5, pz, canopy,
			MATERIALS.Grass, PALETTE.Grass, { canCollide = false })
	end
end

KITS.PottingBench = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	propBox(folder, "BenchTop", x, baseY + 2.6, z, 3, 0.3, 7, MATERIALS.Timber, PALETTE.DarkWood)
	propBox(folder, "BenchShelf", x, baseY + 1.2, z, 2.6, 0.2, 6.4, MATERIALS.Timber, PALETTE.DarkWood)
	for _, s in ipairs({ -1, 1 }) do
		propBox(folder, "BenchLeg", x, baseY, z + s * 3, 2.6, 2.6, 0.4, MATERIALS.Timber, PALETTE.DarkWood)
	end
	for i = 1, 3 do
		cylinderUp(folder, "FlowerPot", x, baseY + 2.9, z - 2.4 + (i - 1) * 2.4, 1.4, 1.3,
			MATERIALS.Stonework, PALETTE.Copper, { canCollide = false })
	end
end

-- The bone charms DESIGN.md section 4 asks for ("recover the scattered
-- finger-bones"). Pure dressing: the interactable is the Reliquary station kit.
--
-- A DELIBERATE CLUSTER, NOT A SCATTER. Spread across eleven studs of conservatory
-- they read as litter someone forgot to clean up, and gave no hint where the task
-- actually is. Gathered onto and immediately around the reliquary's plinth they
-- read as an offering, and the station is the obvious thing to walk to. `plinth`
-- is the plinth's half-extent, so the inner ring lands ON it.
KITS.BoneCluster = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local count = e.count or 9
	local plinth = e.plinth or 1.6
	local spread = e.spread or 3.4
	for i = 1, count do
		-- Deterministic phyllotaxis: an even, unpatterned-looking cluster with no
		-- random seed. Same input, same charms, every build.
		local a = i * 2.39996
		local r = spread * math.sqrt(i / count)
		-- Anything inside the plinth's footprint sits ON its top face; the rest
		-- rests on the floor around it.
		local onPlinth = (r <= plinth)
		propYaw(folder, "BoneCharm", x + math.cos(a) * r, baseY + (onPlinth and (e.plinthTop or 2.2) or 0),
			z + math.sin(a) * r, 0.9, 0.25, 0.3, a, MATERIALS.Paper, PALETTE.Bone, { canCollide = false })
	end
end

-- ============================================================
-- STATION KITS. Each builds its object and RETURNS the single part that will
-- carry the runtime contract - the name, the attributes, the tag, the prompt and
-- the InteractPoint. Returning the part rather than tagging it here keeps the
-- contract in ONE place (buildStations / buildSabotageStations) so a change to
-- what the handlers want is a one-line edit, not a sweep through twelve kits.
-- ============================================================

-- Chapel. The re-leading task is the window itself (DESIGN.md section 4).
KITS.StainedGlassFrame = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1] + dx * 0.6, e.at[2] + dz * 0.6
	local alongX = (dx == 0)
	local w, h = 6.5, 9
	local frame = propBox(folder, "StainedGlass", x, baseY + 2.5, z,
		alongX and w or 0.7, h, alongX and 0.7 or w, MATERIALS.Trim, PALETTE.TrimBrass)
	local panes = { PALETTE.BookRed, PALETTE.BookBlue, PALETTE.ClothGreen, PALETTE.TrimBrass }
	for row = 1, 4 do
		for col = 1, 3 do
			local ox = (col - 2) * 1.9
			local color = panes[((row + col) % 4) + 1]
			propBox(folder, "LeadedPane",
				x + (alongX and ox or dx * 0.2), baseY + 3 + (row - 1) * 2,
				z + (alongX and dz * 0.2 or ox),
				alongX and 1.6 or 0.35, 1.7, alongX and 0.35 or 1.6,
				MATERIALS.Glass, color, { canCollide = false, transparency = 0.3 })
		end
	end
	return frame
end

-- Study. "Wind the grandfather clock in the study" - the dial verb, on the dial.
KITS.GrandfatherClock = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1] + dx * 1.4, e.at[2] + dz * 1.4
	local alongX = (dx == 0)
	local w, d = 3.2, 1.8
	local case = propBox(folder, "ClockCase", x, baseY, z,
		alongX and w or d, 9.5, alongX and d or w, MATERIALS.Timber, PALETTE.DarkWood)
	propBox(folder, "ClockHood", x, baseY + 9.5, z,
		alongX and w + 0.6 or d + 0.4, 1.2, alongX and d + 0.4 or w + 0.6,
		MATERIALS.Timber, PALETTE.DarkWood)
	cylinderUp(folder, "ClockDial", x + dx * (d / 2), baseY + 7.4, z + dz * (d / 2), 2.4, 0.25,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	-- The pendulum window: a glazed slot with the bob visible behind it. Cheap, and
	-- it is the whole reason a clock case reads as a clock and not a wardrobe.
	propBox(folder, "ClockGlass", x + dx * (d / 2 - 0.05), baseY + 3, z + dz * (d / 2 - 0.05),
		alongX and 1.4 or 0.2, 3.4, alongX and 0.2 or 1.4,
		MATERIALS.Glass, PALETTE.GlassTint, { canCollide = false, transparency = 0.5 })
	cylinderUp(folder, "ClockPendulum", x, baseY + 3.2, z, 1.2, 0.2,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	return case
end

-- Darkroom. "Develop the last photograph" - the hold-fill verb, at the trays.
KITS.DevelopingBench = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1] + dx * 1.6, e.at[2] + dz * 1.6
	local alongX = (dx == 0)
	local len, d = 8, 2.6
	local bench = propBox(folder, "DevelopingBench", x, baseY, z,
		alongX and len or d, 3, alongX and d or len, MATERIALS.Timber, PALETTE.DarkWood)
	propBox(folder, "BenchTop", x, baseY + 3, z,
		alongX and len + 0.3 or d + 0.3, 0.3, alongX and d + 0.3 or len + 0.3,
		MATERIALS.Stonework, PALETTE.Stone)
	for i = 1, 3 do
		local o = (i - 2) * 2.3
		propBox(folder, "DeveloperTray",
			x + (alongX and o or 0), baseY + 3.3, z + (alongX and 0 or o),
			alongX and 2 or 1.8, 0.5, alongX and 1.8 or 2,
			MATERIALS.Iron, PALETTE.Iron, { canCollide = false })
	end
	return bench
end

-- MusicRoom. "Transcribe the medium's final entry" - the echo verb, at the keys.
KITS.Piano = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1], e.at[2]
	local yaw = faceYaw(e.face)
	propYaw(folder, "PianoBody", x, baseY + 2.4, z, 7, 1.6, 4.5, yaw, MATERIALS.Timber, PALETTE.DarkWood)
	-- The RAISED LID is the silhouette: flat it is a sideboard, propped it is a
	-- piano from across the room.
	local lid = makePart(folder, "PianoLid", Vector3.new(7, 0.25, 4.5),
		CFrame.new(x - dx * 1.2, baseY + 5, z - dz * 1.2)
			* CFrame.Angles(0, yaw, 0) * CFrame.Angles(0.55, 0, 0),
		MATERIALS.Timber, PALETTE.DarkWood, { canCollide = false })
	lid.Reflectance = 0.05
	propYaw(folder, "PianoLidProp", x - dx * 2.6, baseY + 4, z - dz * 2.6, 0.2, 2.4, 0.2, yaw,
		MATERIALS.Timber, PALETTE.DarkWood, { canCollide = false })
	for _, s in ipairs({ -2.6, 2.6 }) do
		propYaw(folder, "PianoLeg", x + s * math.cos(yaw), baseY, z - s * math.sin(yaw),
			0.5, 2.4, 0.5, yaw, MATERIALS.Timber, PALETTE.DarkWood)
	end
	local keys = propYaw(folder, "PianoKeys", x + dx * 2.5, baseY + 2.4, z + dz * 2.5,
		6, 0.4, 1.4, yaw, MATERIALS.Paper, PALETTE.Bone)
	propYaw(folder, "PianoFallboard", x + dx * 3.2, baseY + 2.8, z + dz * 3.2,
		6, 0.9, 0.3, yaw, MATERIALS.Timber, PALETTE.DarkWood, { canCollide = false })
	KITS.Chair(ctx, folder, { at = { x + dx * 5, z + dz * 5 }, yaw = yaw + math.pi }, baseY)
	return keys
end

-- DiningHall. "Polish the silverware" - the scrub verb, at the cabinet.
KITS.SilverCabinet = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1] + dx * 1.4, e.at[2] + dz * 1.4
	local alongX = (dx == 0)
	local w, d = 7, 2.2
	local cabinet = propBox(folder, "SilverCabinet", x, baseY, z,
		alongX and w or d, 8, alongX and d or w, MATERIALS.Timber, PALETTE.DarkWood)
	propBox(folder, "CabinetGlass", x + dx * (d / 2 - 0.05), baseY + 3.4, z + dz * (d / 2 - 0.05),
		alongX and w - 1 or 0.2, 4, alongX and 0.2 or w - 1,
		MATERIALS.Glass, PALETTE.GlassTint, { canCollide = false, transparency = 0.45 })
	for row = 1, 2 do
		for i = 1, 5 do
			local o = (i - 3) * 1.1
			propBox(folder, "Silverware",
				x + (alongX and o or dx * 0.4), baseY + 3.8 + (row - 1) * 1.9,
				z + (alongX and dz * 0.4 or o),
				alongX and 0.6 or 0.9, 1.1, alongX and 0.9 or 0.6,
				MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
		end
	end
	return cabinet
end

-- Conservatory. "Recover the scattered finger-bones" - the spot-check verb. The
-- charms are clustered on its plinth by KITS.BoneCluster; THIS is what you interact
-- with, so the search has somewhere to end.
-- FREE-STANDING, SO ITS FRONT HAS TO BE AIMED. Wall-mounted stations get their
-- facing for free - a panel on a wall can only face one way - but a chest in the
-- middle of a glass room will happily present its back to the door, which is what
-- this one did: the clasp was hardcoded to +Z while the room's only doorway is
-- due west. The whole chest now follows `face`, which is the same field that
-- places the InteractPoint, so the clasp, the front, and the spot a player stands
-- are one decision instead of three.
KITS.Reliquary = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	local dx, dz = faceDir(e.face)
	local frontX = (dx ~= 0)
	-- Long axis across the front, bands wrapping the short way over the lid.
	local plinthX = frontX and 3 or 4
	local plinthZ = frontX and 4 or 3
	local chestX = frontX and 2.4 or 3.4
	local chestZ = frontX and 3.4 or 2.4

	propBox(folder, "ReliquaryPlinth", x, baseY, z, plinthX, 2.2, plinthZ, MATERIALS.Stonework, PALETTE.Stone)
	local chest = propBox(folder, "ReliquaryChest", x, baseY + 2.2, z, chestX, 2, chestZ,
		MATERIALS.Timber, PALETTE.DarkWood)
	for _, s in ipairs({ -1, 1 }) do
		propBox(folder, "ReliquaryBand",
			x + (frontX and 0 or s * 1), baseY + 2.2, z + (frontX and s * 1 or 0),
			frontX and 2.5 or 0.35, 2.05, frontX and 0.35 or 2.5,
			MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	end
	-- The clasp IS the front, and it points down `face` at the InteractPoint.
	propBox(folder, "ReliquaryClasp", x + dx * 1.25, baseY + 3, z + dz * 1.25,
		frontX and 0.25 or 0.8, 0.6, frontX and 0.8 or 0.25,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	return chest
end

-- BoilerRoom. "Route the incense through the manor's vents" - the flow verb, on
-- the manifold that plugs into KITS.PipeWall's run.
-- Mounts flush ON the pipe run and CENTRED in the bay KITS.PipeWall leaves for
-- it: same `at`, same wall, same standoff, so the two cannot drift apart. Its
-- width is the bay width, so nothing overhangs the run at either end.
KITS.PipeManifold = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local off = PIPE_STANDOFF + 0.85
	local x, z = e.at[1] + dx * off, e.at[2] + dz * off
	local alongX = (dx == 0)
	local w = PIPE_BAY - 0.5
	local top, bottom = PIPE_LEVELS[2] + 0.9, PIPE_LEVELS[1] - 0.9

	local panel = propBox(folder, "PipeManifold", x, baseY + bottom, z,
		alongX and w or 0.8, top - bottom, alongX and 0.8 or w, MATERIALS.Iron, PALETTE.Iron)
	for i = 1, 3 do
		local o = (i - 2) * (w / 3.4)
		cylinderUp(folder, "ManifoldGauge",
			x + (alongX and o or dx * 0.45), baseY + top - 1.3, z + (alongX and dz * 0.45 or o),
			1.2, 0.25, MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
		-- Spurs reach BACK to the two mains, so the panel reads as plumbed in
		-- rather than stuck on.
		for _, level in ipairs(PIPE_LEVELS) do
			propBox(folder, "ManifoldSpur",
				x - dx * 0.5 + (alongX and o or 0), baseY + level - 0.25,
				z - dz * 0.5 + (alongX and 0 or o),
				alongX and 0.5 or 1.2, 0.5, alongX and 1.2 or 0.5,
				MATERIALS.Iron, PALETTE.Copper, { canCollide = false })
		end
	end
	return panel
end

-- Gallery. "Trim the gas lamps" - the slider verb, on the corridor's gas valves.
KITS.GasValvePanel = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1] + dx * 0.9, e.at[2] + dz * 0.9
	local alongX = (dx == 0)
	local panel = propBox(folder, "GasValvePanel", x, baseY + 3, z,
		alongX and 4.5 or 0.7, 4, alongX and 0.7 or 4.5, MATERIALS.Trim, PALETTE.TrimBrass)
	for i = 1, 3 do
		local o = (i - 2) * 1.3
		cylinderUp(folder, "ValveDial",
			x + (alongX and o or dx * 0.4), baseY + 4.6, z + (alongX and dz * 0.4 or o),
			1, 0.25, MATERIALS.Iron, PALETTE.Iron, { canCollide = false })
	end
	propBox(folder, "GasRiser", x - dx * 0.2, baseY, z - dz * 0.2, 0.6, 3, 0.6,
		MATERIALS.Iron, PALETTE.Copper, { canCollide = false })
	return panel
end

-- GrandFoyer. "Pick the cabinet lock" - the pins verb, on the hall strongbox.
KITS.Strongbox = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1] + dx * 2, e.at[2] + dz * 2
	propBox(folder, "StrongboxPlinth", x, baseY, z, 4, 1.2, 3, MATERIALS.Stonework, PALETTE.Stone)
	local box_ = propBox(folder, "Strongbox", x, baseY + 1.2, z, 3.4, 3.4, 2.6,
		MATERIALS.Iron, PALETTE.Iron)
	cylinderUp(folder, "StrongboxDial", x + dx * 1.35, baseY + 2.6, z + dz * 1.35, 1.4, 0.3,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	propBox(folder, "StrongboxHandle", x + dx * 1.4, baseY + 1.6, z + dz * 1.4, 0.9, 0.3, 0.9,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	return box_
end

-- Library. "Shelve the library books" - the sort verb, on a case in the run.
KITS.SortingShelf = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1] + dx * 1, e.at[2] + dz * 1
	local alongX = (dx == 0)
	local w, d = 6, 1.8
	local case = propBox(folder, "SortingShelf", x, baseY, z,
		alongX and w or d, 8, alongX and d or w, MATERIALS.Timber, PALETTE.DarkWood)
	for s = 1, 3 do
		propBox(folder, "SortingBoard", x + dx * 0.2, baseY + 1.6 + (s - 1) * 2, z + dz * 0.2,
			alongX and w - 0.6 or d - 0.4, 0.2, alongX and d - 0.4 or w - 0.6,
			MATERIALS.Timber, PALETTE.Floorboard, { canCollide = false })
	end
	-- The trolley of unshelved books: the task's premise, standing next to it.
	-- Books come out of bookRow like every other book in the manor - see
	-- DIM.BookWidth for why three kits no longer each invent their own size.
	local tx, tz = x + dx * 3, z + dz * 3
	propBox(folder, "BookTrolley", tx, baseY + 1.2, tz, 2.8, 0.3, 2,
		MATERIALS.Timber, PALETTE.DarkWood)
	bookRow(folder, true, tx - 1.2, tx + 1.2, baseY + 1.5, tz, DIM.ShelfDepth - 0.7, 1)
	return case
end

-- ---------- Sabotage fixtures ----------
KITS.FuseBox = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1] + dx * 0.9, e.at[2] + dz * 0.9
	local alongX = (dx == 0)
	local box_ = propBox(folder, "FuseBox", x, baseY + 3, z,
		alongX and 4 or 1.4, 4.5, alongX and 1.4 or 4,
		MATERIALS.Iron, PALETTE.Iron)
	for i = 1, 4 do
		local o = (i - 2.5) * 0.9
		propBox(folder, "FuseSwitch",
			x + (alongX and o or dx * 0.75), baseY + 5, z + (alongX and dz * 0.75 or o),
			alongX and 0.5 or 0.4, 1.2, alongX and 0.4 or 0.5,
			MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	end
	-- 1.2 tall, and that is a burial constraint rather than a taste one: the Utility
	-- Room sits entirely outside the manor footprint, so its lid is DIM.VaultCover
	-- BELOW the lawn (Y = -2) and a taller conduit would spear up through the turf.
	propBox(folder, "FuseConduit", x - dx * 0.3, baseY + 7.5, z - dz * 0.3, 0.5, 1.2, 0.5,
		MATERIALS.Iron, PALETTE.Copper, { canCollide = false })
	return box_
end

KITS.ValveWheel = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1] + dx * 0.8, e.at[2] + dz * 0.8
	propBox(folder, "ValveStub", x, baseY, z, 1.2, 4, 1.2, MATERIALS.Iron, PALETTE.Copper)
	propBox(folder, "ValveBody", x, baseY + 4, z, 2, 1.6, 2, MATERIALS.Iron, PALETTE.Iron)
	local wheel = cylinderUp(folder, "ValveWheel", x, baseY + 5.6, z, 3.2, 0.4,
		MATERIALS.Trim, PALETTE.TrimBrass)
	for i = 1, 4 do
		local a = (i - 1) * math.pi / 2
		propYaw(folder, "ValveSpoke", x + math.cos(a) * 0.8, baseY + 5.65, z + math.sin(a) * 0.8,
			1.8, 0.25, 0.25, -a, MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	end
	return wheel
end

-- ---------- Secret-passage reservations (see PLAN.Secrets: NO MECHANISM) ------
KITS.SecretBookcase = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1] + dx * 1, e.at[2] + dz * 1
	local alongX = (dx == 0)
	-- Stands 0.4 PROUD of its neighbours in the run, and the seam beside it is a
	-- visible 0.25-stud gap of shadow. That is the entire tell.
	local section = propBox(folder, "SecretBookcase", x + dx * 0.4, baseY, z + dz * 0.4,
		alongX and 5 or 1.6, 8, alongX and 1.6 or 5, MATERIALS.Timber, PALETTE.DarkWood)
	for _, s in ipairs({ -1, 1 }) do
		propBox(folder, "SecretSeam",
			x + (alongX and s * 2.6 or dx * 0.4), baseY,
			z + (alongX and dz * 0.4 or s * 2.6),
			alongX and 0.25 or 1.7, 8, alongX and 1.7 or 0.25,
			MATERIALS.Timber, PALETTE.Canvas, { canCollide = false })
	end
	-- Real books at the manor's one book size, not a painted slab - the section has
	-- to be indistinguishable from the run it hides in, and a 4.2-stud block of
	-- solid tan was the tell that gave it away.
	for s = 1, 3 do
		local y = baseY + 1.4 + (s - 1) * 2.2
		if alongX then
			bookRow(folder, true, x - 2.1, x + 2.1, y, z + dz * 0.6, DIM.ShelfDepth - 0.7, s)
		else
			bookRow(folder, false, z - 2.1, z + 2.1, y, x + dx * 0.6, DIM.ShelfDepth - 0.7, s)
		end
	end
	return section
end

KITS.SecretPanel = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local x, z = e.at[1] + dx * 0.7, e.at[2] + dz * 0.7
	local alongX = (dx == 0)
	local panel = propBox(folder, "SecretPanel", x, baseY, z,
		alongX and 4.5 or 0.8, 9, alongX and 0.8 or 4.5, MATERIALS.Panel, PALETTE.WallPanel)
	propBox(folder, "SecretPanelBead", x + dx * 0.2, baseY + 0.6, z + dz * 0.2,
		alongX and 3.4 or 0.5, 7.8, alongX and 0.5 or 3.4,
		MATERIALS.Timber, PALETTE.DarkWood, { canCollide = false })
	for _, s in ipairs({ -1, 1 }) do
		propBox(folder, "SecretSeam",
			x + (alongX and s * 2.4 or dx * 0.1), baseY,
			z + (alongX and dz * 0.1 or s * 2.4),
			alongX and 0.25 or 0.9, 9, alongX and 0.9 or 0.25,
			MATERIALS.Timber, PALETTE.Canvas, { canCollide = false })
	end
	return panel
end

-- ---------- Lamps ----------
KITS.Chandelier = function(ctx, folder, e, baseY)
	local room = ctx.rooms[e.room]
	local x, z = e.at[1], e.at[2]
	local ceilingY = baseY + roomHeight(room)
	-- Double-height rooms drop the fitting further so it hangs IN the room instead
	-- of pressed against a ceiling nobody can see from the floor.
	local drop = e.drop or ((roomHeight(room) > 20) and 11 or 4.5)
	local ringY = ceilingY - drop
	local bulbs = e.bulbs or 4
	local ringRadius = (bulbs > 4) and 2.8 or 2.2

	propBox(folder, "ChandelierRod", x, ringY, z, 0.3, drop, 0.3,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	propBox(folder, "ChandelierBoss", x, ringY - 0.4, z, 1.2, 0.8, 1.2,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	-- The ring, as tangent segments: a flat cylinder would read as a disc.
	local segments = 20
	for i = 1, segments do
		local a = (i - 0.5) * 2 * math.pi / segments
		local px, pz = x + math.cos(a) * ringRadius, z + math.sin(a) * ringRadius
		makePart(folder, "ChandelierRing",
			Vector3.new(2 * ringRadius * math.sin(math.pi / segments) + 0.05, 0.3, 0.3),
			CFrame.new(Vector3.new(px, ringY, pz), Vector3.new(x, ringY, z)),
			MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false, castShadow = false })
	end
	for i = 1, bulbs do
		local a = (i - 1) * 2 * math.pi / bulbs
		local px, pz = x + math.cos(a) * ringRadius, z + math.sin(a) * ringRadius
		propBox(folder, "ChandelierArm", px, ringY, pz, 0.25, 1, 0.25,
			MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
		addBulb(folder, px, ringY + 1.5, pz, 0.9, DIM.ChandelierBright, DIM.ChandelierRange)
	end
end

-- ============================================================
-- THE SCONCE, AND WHAT IT IS FOR.
--
-- *** DEEP SHADOW BETWEEN POOLS OF LIGHT IS THE AESTHETIC. *** A sconce is not
-- here to light a corridor; it is here to put ONE pool of amber on a wall and
-- leave the stretch either side of it dark. The manor has to read as candlelit -
-- a place you move through in and out of visibility - and the failure mode is not
-- "too dark", it is "evenly lit", which is what a hotel corridor looks like and
-- is what the Gallery had become.
--
-- Two things follow from that, and both are easy to undo by accident:
--   * DIM.SconceBright and DIM.SconceRange are deliberately low. They were cut a
--     quarter this revision. If a room reads dark BETWEEN sconces, that is the
--     design working; the answer is never to raise these.
--   * The gap budget the manifest enforces (DIM.SconceMaxGap) is looser than the
--     spacing the runs aim for, so it catches a corridor nobody lit at all
--     without pressuring anyone into lining both walls.
-- Chandeliers and cellar bulbs carry the rooms; sconces punctuate the routes.
-- ============================================================
KITS.Sconce = function(ctx, folder, e, baseY)
	local dx, dz = faceDir(e.face)
	local wx, wz = e.at[1], e.at[2]
	local y = baseY + 8
	propBox(folder, "SconceBracket", wx + dx * 0.7, y - 0.6, wz + dz * 0.7,
		(dx ~= 0) and 1.4 or 0.3, 0.3, (dx ~= 0) and 0.3 or 1.4,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	propBox(folder, "SconceBackplate", wx + dx * 0.55, y - 1.4, wz + dz * 0.55,
		(dx ~= 0) and 0.3 or 1.2, 2.2, (dx ~= 0) and 1.2 or 0.3,
		MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false })
	addBulb(folder, wx + dx * 1.4, y, wz + dz * 1.4, 1, DIM.SconceBright, DIM.SconceRange)
end

KITS.BareBulb = function(ctx, folder, e, baseY)
	local x, z = e.at[1], e.at[2]
	-- Hung from the cellar's ACTUAL lid at this point, which steps down past the
	-- manor footprint - see cellarCeilingY and the burial rule.
	local ceilingY = cellarCeilingY(ctx, x, z)
	local drop = e.drop or 2.6
	propBox(folder, "BulbCord", x, ceilingY - drop, z, 0.12, drop, 0.12,
		MATERIALS.Iron, PALETTE.Iron, { canCollide = false, castShadow = false })
	addBulb(folder, x, ceilingY - drop - 0.4, z, 0.8, DIM.CellarBulbBright, DIM.CellarBulbRange)
end

-- ============================================================
-- THE RITUAL HEART. Assembled on the Séance Parlor's floor centre - the same
-- point the shell has been printing as THE MEETING / RITUAL CENTER since the
-- first build, and now the point MeetingSystem.MEETING_TABLE_CENTER names.
--
-- It is built from the ROOM, not from a literal: the centre is derived from
-- PLAN.Rooms.SeanceParlor's rect, so moving the Parlor moves the ritual with it
-- and the summary's printed centre stays true.
--
-- The order of the four radii is asserted by construction (DIM's ritual note):
--   table 4.5  <  chairs 10  <  Convergence zone 12  <  braziers 14
-- Everything faces the middle. From the Great Hall doorway a player should see a
-- ring of cold braziers around a green-clothed table and know, without being
-- told, that this room is what the match is about.
-- ============================================================
local function buildRitual(ctx, warnings)
	local parlor = ctx.rooms.SeanceParlor
	if not parlor then
		table.insert(warnings, "PLAN.Rooms has no SeanceParlor - the ritual heart cannot be built")
		return
	end
	local folder = ctx.folders.SeanceParlor
	local r = parlor.rects[1]
	local cx, cz = (r[1] + r[3]) / 2, (r[2] + r[4]) / 2
	local baseY = GROUND_Y

	-- ---- The Convergence inlay: a brass ring set flush into the floorboards ----
	local function ringOfSegments(name, radius, width, segments)
		local chord = 2 * radius * math.sin(math.pi / segments) + 0.05
		for i = 1, segments do
			local a = (i - 0.5) * 2 * math.pi / segments
			local px, pz = cx + math.cos(a) * radius, cz + math.sin(a) * radius
			-- CFrame.new(pos, target) points the part's front at the centre, which
			-- leaves its local X running along the tangent - exactly what a ring
			-- segment wants, with no angle arithmetic to get backwards.
			makePart(folder, name, Vector3.new(chord, 0.08, width),
				CFrame.new(Vector3.new(px, baseY + 0.04, pz), Vector3.new(cx, baseY + 0.04, cz)),
				MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false, castShadow = false })
		end
	end
	ringOfSegments("ConvergenceInlay", DIM.RitualZoneRadius, 0.7, 64)
	ringOfSegments("ConvergenceInlayInner", DIM.SeanceTableRadius + 1.5, 0.4, 40)
	-- Eight spokes, on the brazier bearings (the same half-step offset the brazier
	-- loop below uses), tying the inner ring to the outer one.
	for i = 1, DIM.BrazierCount do
		local a = (i - 0.5) * 2 * math.pi / DIM.BrazierCount
		local r1, r2 = DIM.SeanceTableRadius + 1.5, DIM.RitualZoneRadius
		local mid = (r1 + r2) / 2
		makePart(folder, "ConvergenceSpoke", Vector3.new(0.35, 0.08, r2 - r1),
			CFrame.new(Vector3.new(cx + math.cos(a) * mid, baseY + 0.04, cz + math.sin(a) * mid),
				Vector3.new(cx, baseY + 0.04, cz)),
			MATERIALS.Trim, PALETTE.TrimBrass, { canCollide = false, castShadow = false })
	end

	-- ---- The séance table ----
	local d = DIM.SeanceTableRadius * 2
	cylinderUp(folder, "SeanceTableFoot", cx, baseY, cz, 5, 0.5, MATERIALS.Timber, PALETTE.DarkWood)
	cylinderUp(folder, "SeanceTablePedestal", cx, baseY + 0.5, cz, 2.6, 2.1, MATERIALS.Timber, PALETTE.DarkWood)
	cylinderUp(folder, "SeanceTableTop", cx, baseY + 2.6, cz, d, 0.5, MATERIALS.Timber, PALETTE.DarkWood)
	cylinderUp(folder, "SeanceCloth", cx, baseY + 3.1, cz, d + 0.6, 0.12,
		MATERIALS.Fabric, PALETTE.ClothGreen, { canCollide = false })
	cylinderUp(folder, "SeanceClothSkirt", cx, baseY + 1.9, cz, d + 0.6, 1.2,
		MATERIALS.Fabric, PALETTE.ClothGreen, { canCollide = false })

	-- ---- The emergency button, on the table ----
	-- CONTRACT (EmergencyButtonHandler.server.lua): the EmergencyButton tag and a
	-- ProximityPrompt child; the handler sets ActionText "Call meeting" and the
	-- 0.5s hold itself. It sits at the exact table centre because a séance is
	-- convened AT the table, and it must stay inside prompt range of a player who
	-- has walked up to it - not of one teleported to a meeting seat.
	local button = cylinderUp(folder, "EmergencyButton", cx, baseY + 3.22, cz, 1.9, 0.45,
		MATERIALS.Trim, PALETTE.TrimBrass)
	cylinderUp(folder, "EmergencyButtonCap", cx, baseY + 3.6, cz, 1.3, 0.35,
		MATERIALS.Iron, PALETTE.BookRed, { canCollide = false })
	CollectionService:AddTag(button, TAGS.EmergencyButton)
	addPrompt(button)

	-- ---- Eight chairs, looking in ----
	for i = 1, DIM.RitualChairCount do
		local a = (i - 1) * 2 * math.pi / DIM.RitualChairCount
		local px, pz = cx + math.cos(a) * DIM.RitualChairRadius, cz + math.sin(a) * DIM.RitualChairRadius
		-- Yaw that points the chair's local +Z at the table, so KITS.Chair puts the
		-- backrest on the outside.
		KITS.Chair(ctx, folder, { at = { px, pz }, yaw = math.atan2(cx - px, cz - pz) }, baseY)
	end

	-- ---- The Convergence zone ----
	-- CONTRACT (RitualService.lua): exactly ONE part tagged ConvergenceZone; its
	-- Position is the centre and its radius is max(Size.X, Size.Z) / 2.
	--
	-- ITS Y IS CHOSEN, NOT INCIDENTAL. RitualService measures a 3-D distance from
	-- this part's Position to each crew member's HumanoidRootPart, so a zone
	-- centred at floor level would spend two or three studs of its radius on the
	-- height of a standing character and quietly shrink the circle. Centring it at
	-- root height makes the 12-stud radius the honest horizontal one.
	local zone = makePart(folder, "ConvergenceZone",
		Vector3.new(DIM.RitualZoneRadius * 2, 6, DIM.RitualZoneRadius * 2),
		CFrame.new(cx, baseY + 3, cz), MATERIALS.Plaster, PALETTE.TrimBrass,
		{ canCollide = false, castShadow = false, transparency = 1 })
	zone.CanQuery = false
	zone.CanTouch = false
	CollectionService:AddTag(zone, TAGS.ConvergenceZone)

	-- ---- Eight braziers ----
	-- CONTRACT (RitualService.lua), and it is checked child-by-child: the Brazier
	-- tag, a unique numeric BrazierIndex, and a child BasePart literally named
	-- "Flame" holding a PointLight and a Fire. setLit() flips the Flame's
	-- Transparency (0 lit / 1 unlit) and both instances' Enabled. EVERYTHING IS
	-- BUILT UNLIT: braziers light one per completed task, so a manor that opens
	-- with lit braziers is a manor whose ritual has already started.
	for i = 1, DIM.BrazierCount do
		-- HALF A STEP OFF THE CHAIRS. Braziers sit on the bearings BETWEEN the
		-- eight chairs rather than behind them, so from the Great Hall doorway the
		-- ring reads as eight separate standing lights instead of eight shapes
		-- hidden behind eight chair backs.
		local a = (i - 0.5) * 2 * math.pi / DIM.BrazierCount
		local px, pz = cx + math.cos(a) * DIM.RitualBrazierRadius, cz + math.sin(a) * DIM.RitualBrazierRadius

		-- 1.8 wide, not 2: the bowl's inner edge is what MeetingSystem's seat ring
		-- has to clear, and every tenth of a stud here is a tenth of clearance
		-- there. See DIM's ritual note.
		cylinderUp(folder, "BrazierFoot", px, baseY, pz, 1.8, 0.5, MATERIALS.Iron, PALETTE.Iron)
		cylinderUp(folder, "BrazierStem", px, baseY + 0.5, pz, 0.9, 3.1, MATERIALS.Iron, PALETTE.Iron)
		local bowl = cylinderUp(folder, "Brazier" .. i, px, baseY + 3.6, pz, 1.8, 1.1,
			MATERIALS.Trim, PALETTE.TrimBrass)
		bowl:SetAttribute("BrazierIndex", i)
		CollectionService:AddTag(bowl, TAGS.Brazier)

		local flame = sphereAt(bowl, "Flame", px, baseY + 5.1, pz, 1.7,
			MATERIALS.Bulb, PALETTE.Candlelight, { canCollide = false, castShadow = false })
		flame.Transparency = 1

		local light = Instance.new("PointLight")
		light.Name = "FlameLight"
		light.Color = PALETTE.Candlelight
		light.Brightness = DIM.BrazierBright
		light.Range = DIM.BrazierRange
		light.Shadows = false
		light.Enabled = false
		light.Parent = flame

		local fire = Instance.new("Fire")
		fire.Name = "FlameFire"
		fire.Color = PALETTE.Candlelight
		fire.SecondaryColor = PALETTE.TrimBrass
		fire.Heat = 6
		fire.Size = 5
		fire.Enabled = false
		fire.Parent = flame
	end
end

-- ============================================================
-- DRESSING BUILD PASSES. Each walks one PLAN table; the ONLY logic here is
-- looking up the kit, handing it the room's folder and floor, and - for stations
-- - applying the runtime contract to whatever part the kit hands back.
-- ============================================================

-- How far in front of a station a player stands to work it. One number, applied
-- along the station's own `face`, so every InteractPoint in the manor is the same
-- distance from its object and the animation pass has a consistent transform.
local STATION_STANDOFF = 3.2

local function runKitTable(ctx, list, label, warnings, apply)
	for _, entry in ipairs(list) do
		local room = ctx.rooms[entry.room]
		local kit = KITS[entry.kit]
		if not room then
			table.insert(warnings, string.format("%s entry names unknown room '%s'", label, tostring(entry.room)))
		elseif not kit then
			table.insert(warnings, string.format("%s entry in %s names unknown kit '%s'", label, entry.room, tostring(entry.kit)))
		else
			local built = kit(ctx, ctx.folders[room.name], entry, floorBaseY(room.floor))
			if apply then
				apply(entry, built, room, floorBaseY(room.floor), warnings)
			end
		end
	end
end

local function buildFurnishings(ctx, warnings)
	runKitTable(ctx, PLAN.Furnish, "furnish", warnings, nil)
end

local function buildLamps(ctx, warnings)
	runKitTable(ctx, PLAN.Lamps, "lamp", warnings, nil)
end

local function buildStations(ctx, warnings)
	runKitTable(ctx, PLAN.Stations, "station", warnings, function(spec, part, room, baseY)
		if not part then
			table.insert(warnings, string.format("station kit '%s' built no station part for %s", spec.kit, spec.name))
			return
		end
		-- THE CONTRACT, in one place - see PLAN.Stations for where each half of it
		-- was read from. The part's NAME is the task id; TaskType picks the
		-- minigame; the tag makes TaskStationHandler adopt it; the prompt is what
		-- it adopts. The handler configures the prompt, never this file.
		part.Name = spec.name
		part:SetAttribute("TaskType", spec.taskType)
		CollectionService:AddTag(part, TAGS.TaskStation)
		addPrompt(part)

		-- THE STATION-FACING RULE, applied by construction here rather than checked
		-- afterwards: `face` is BOTH the direction the object's front looks and the
		-- side the InteractPoint stands on, so a station cannot present its back to
		-- the person using it. What is NOT guaranteed by construction is that the
		-- front points at the way IN - that depends on where the room's doorway is,
		-- and checkStationFacing reports it.
		local dx, dz = faceDir(spec.face)
		local interactX = spec.at[1] + dx * STATION_STANDOFF
		local interactZ = spec.at[2] + dz * STATION_STANDOFF
		addInteractPoint(part, interactX, baseY + 0.1, interactZ, spec.at[1], spec.at[2])
		table.insert(ctx.stationFronts, {
			name = spec.name, room = room, at = spec.at, face = spec.face,
			interact = { interactX, interactZ },
		})
	end)
end

local function buildSabotageStations(ctx, warnings)
	runKitTable(ctx, PLAN.Sabotage, "sabotage", warnings, function(spec, part, room, baseY)
		if not part then
			table.insert(warnings, string.format("sabotage kit '%s' built no station part for %s", spec.kit, spec.name))
			return
		end
		part.Name = spec.name
		part:SetAttribute("SabotageType", spec.sabotageType)
		part:SetAttribute("FixId", spec.fixId)
		CollectionService:AddTag(part, TAGS.SabotageStation)
		addPrompt(part)

		-- THE STATION-FACING RULE, applied by construction here rather than checked
		-- afterwards: `face` is BOTH the direction the object's front looks and the
		-- side the InteractPoint stands on, so a station cannot present its back to
		-- the person using it. What is NOT guaranteed by construction is that the
		-- front points at the way IN - that depends on where the room's doorway is,
		-- and checkStationFacing reports it.
		local dx, dz = faceDir(spec.face)
		local interactX = spec.at[1] + dx * STATION_STANDOFF
		local interactZ = spec.at[2] + dz * STATION_STANDOFF
		addInteractPoint(part, interactX, baseY + 0.1, interactZ, spec.at[1], spec.at[2])
		table.insert(ctx.stationFronts, {
			name = spec.name, room = room, at = spec.at, face = spec.face,
			interact = { interactX, interactZ },
		})
	end)
end

local function buildSecrets(ctx, warnings)
	runKitTable(ctx, PLAN.Secrets, "secret", warnings, function(spec, part)
		if not part then
			table.insert(warnings, string.format("secret kit '%s' built no part for %s", spec.kit, spec.name))
			return
		end
		part.Name = spec.name
		-- RESERVATION ONLY. Nothing reads this tag or this attribute today; see
		-- the block comment on PLAN.Secrets before wiring anything to either.
		part:SetAttribute("RouteId", spec.routeId)
		CollectionService:AddTag(part, TAGS.SecretPassage)
	end)
end

-- ------------------------------------------------------------
-- THE SPAWN. One SpawnLocation, Neutral, on the Foyer rug - the manor's real
-- spawn and the first thing a player sees, which is why it is in the
-- double-height arrival hall looking down the Great Hall toward the Parlor.
--
-- Non-colliding and invisible: it is a spawn transform, not a plinth, and an
-- opaque pad on the rug would be the one obviously-fake object in the room.
-- Duration 0 kills the spawn ForceField - a bubble around a fresh arrival would
-- be visible evidence of who just joined.
-- ------------------------------------------------------------
local function buildSpawn(ctx, warnings)
	local foyer = ctx.rooms.GrandFoyer
	if not foyer then
		table.insert(warnings, "PLAN.Rooms has no GrandFoyer - no spawn was placed")
		return
	end
	local r = foyer.rects[1]
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "EstateSpawn"
	spawn.Anchored = true
	spawn.CanCollide = false
	spawn.CanQuery = false
	spawn.CastShadow = false
	spawn.Transparency = 1
	spawn.Size = Vector3.new(12, 0.4, 8)
	spawn.CFrame = CFrame.new((r[1] + r[3]) / 2, GROUND_Y + 0.5, (r[2] + r[4]) / 2)
	spawn.Neutral = true
	spawn.Enabled = true
	spawn.Duration = 0
	spawn.Parent = ctx.folders.GrandFoyer
	counters.parts = counters.parts + 1
end

-- ------------------------------------------------------------
-- PERIMETER CHECK. Walks every room edge at 1-stud resolution and confirms each
-- sample is either walled, an intentional opening, or an internal seam between
-- two rects of the same room. This validates the OUTPUT, not the input: it is
-- what catches a coordinate typo that leaves two rooms touching only at a corner
-- and the manor open to the sky along an edge nobody thought to look at.
-- ------------------------------------------------------------
local function checkPerimeter(ctx)
	local gaps = {}
	for floorName, entries in pairs(ctx.rectsByFloor) do
		for _, entry in ipairs(entries) do
			local r = entry.rect
			local edges = {
				{ axis = "Z", coord = r[2], span = { r[1], r[3] } },
				{ axis = "Z", coord = r[4], span = { r[1], r[3] } },
				{ axis = "X", coord = r[1], span = { r[2], r[4] } },
				{ axis = "X", coord = r[3], span = { r[2], r[4] } },
			}
			for _, edge in ipairs(edges) do
				local covered = ctx.coverage[floorName][edge.axis][edge.coord] or {}
				local seams = ctx.sameRoom[floorName][edge.axis][edge.coord] or {}
				local at = edge.span[1] + 0.5
				while at < edge.span[2] do
					if not spansContain(covered, at) and not spansContain(seams, at) then
						table.insert(gaps, string.format("%s %s %s=%.1f at %.1f",
							floorName, entry.room.name, edge.axis, edge.coord, at))
						break -- one report per edge is enough to find it
					end
					at = at + 1
				end
			end
		end
	end
	return gaps
end

-- ------------------------------------------------------------
-- BURIAL / PROTRUSION VALIDATOR. The cellar is supposed to be invisible from
-- everywhere a player can stand, and until this build it was not: vault lids
-- stood a stud proud of the lawn and cellar wall tops surfaced flush with it.
-- Neither is something the perimeter, stair, roof or double-height checks can
-- see - they all ask about enclosure, and a cellar that pokes out of the ground
-- is perfectly enclosed. So this asks the one remaining question directly, of
-- the parts that were actually built rather than of the plan:
--
--   INSIDE the manor footprint  - no cellar part's top may exceed the ground
--       floor slab's UNDERSIDE. The lid pieces that double as ground flooring
--       are the sole exception and only at exactly GROUND_Y; they are filed
--       under their GROUND room's folder anyway, so they are not even scanned.
--   OUTSIDE the ground-room footprint - no cellar part's top may exceed the
--       grass surface. Flush is legal (a wall on the footprint edge tops out at
--       the grass plane under the manor's own exterior wall); PROUD is not.
--
-- Every part this tool makes is axis-aligned and unrotated, so top and footprint
-- come straight off Position and Size - no spatial query needed. THE TARGET IS
-- ZERO; a nonzero count means the cellar is showing.
-- ------------------------------------------------------------
local function checkBurial(ctx)
	local slabUnderside = GROUND_Y - DIM.FloorThickness
	local grassTop = GROUND_Y - DIM.FloorThickness
	local lidAsFloorTop = GROUND_Y

	local groundRects = {}
	for _, entry in ipairs(ctx.rectsByFloor.Ground) do
		table.insert(groundRects, entry.rect)
	end

	local count, offenders = 0, {}
	for _, room in ipairs(PLAN.Rooms) do
		local folder = (room.floor == "Cellar") and ctx.folders[room.name] or nil
		if folder then
			for _, part in ipairs(folder:GetDescendants()) do
				if part:IsA("BasePart") then
					local p, s = part.Position, part.Size
					local top = p.Y + s.Y / 2
					local rect = { p.X - s.X / 2, p.Z - s.Z / 2, p.X + s.X / 2, p.Z + s.Z / 2 }

					local inside = false
					for _, ground in ipairs(groundRects) do
						if rectIntersect(rect, ground) then
							inside = true
							break
						end
					end
					local outside = #rectSubtractMany({ rect }, groundRects) > 0

					local problem
					if inside and top > slabUnderside + EPS then
						-- The lid-as-floor exception, honored ONLY at its exact height.
						local isLidAtFloorLevel = (part.Name == "Floor")
							and math.abs(top - lidAsFloorTop) < EPS
						if not isLidAtFloorLevel then
							problem = string.format("top %.2f is ABOVE the ground slab underside %.2f, inside the manor",
								top, slabUnderside)
						end
					end
					if not problem and outside and top > grassTop + EPS then
						problem = string.format("top %.2f is ABOVE the grass surface %.2f, outside the rooms above",
							top, grassTop)
					end

					if problem then
						count = count + 1
						if #offenders < 10 then
							table.insert(offenders, string.format("%s / %s  X[%.1f..%.1f] Z[%.1f..%.1f]  %s",
								room.name, part.Name, rect[1], rect[3], rect[2], rect[4], problem))
						end
					end
				end
			end
		end
	end

	-- ============================================================
	-- TURF EXPOSURE. The other half of the burial rule, and the half the height
	-- test above structurally cannot see: a turf cap can sit entirely below the
	-- lawn, pass every height check, and still be VISIBLE FROM INSIDE THE CELLAR
	-- because the ceiling steps down at the manor's footprint edge and the step's
	-- vertical face was made of grass.
	--
	-- So this asks the opposite question - does any grass reach into, or up to,
	-- the air a player standing in a cellar room can see? The interior volume is
	-- computed per sub-region because the ceiling is not flat: under the manor it
	-- is the ground slab's underside, past it the sunk vault lid. Grass is
	-- expected to sit ABOVE the sunk lid out there, which is legal; grass level
	-- with the taller interior is not.
	-- ============================================================
	local vaultUnderside = GROUND_Y - DIM.FloorThickness - DIM.VaultCover - DIM.FloorThickness
	local inset = DIM.WallThickness / 2

	for _, part in ipairs((ctx.groundsFolder and ctx.groundsFolder:GetDescendants()) or {}) do
		if part:IsA("BasePart") and part.Material == MATERIALS.Grass then
			local p, s = part.Position, part.Size
			local y1, y2 = p.Y - s.Y / 2, p.Y + s.Y / 2
			local rect = { p.X - s.X / 2, p.Z - s.Z / 2, p.X + s.X / 2, p.Z + s.Z / 2 }

			for _, entry in ipairs(ctx.rectsByFloor.Cellar or {}) do
				local r = entry.rect
				local interior = { r[1] + inset, r[2] + inset, r[3] - inset, r[4] - inset }
				local overlap = rectIntersect(rect, interior)
				if overlap then
					-- Under the manor the interior reaches the ground slab; past it
					-- only the sunk lid. Test each sub-region against its own ceiling.
					local covered = {}
					for _, ground in ipairs(groundRects) do
						local piece = rectIntersect(overlap, ground)
						if piece then
							table.insert(covered, piece)
						end
					end
					local buried = rectSubtractMany({ overlap }, groundRects)

					local function report(ceiling, where)
						if y2 > CELLAR_Y + EPS and y1 < ceiling - EPS then
							count = count + 1
							if #offenders < 10 then
								table.insert(offenders, string.format(
									"Grounds / %s  X[%.1f..%.1f] Z[%.1f..%.1f]  GRASS inside %s's airspace (%s, y %.2f..%.2f under a ceiling at %.2f)",
									part.Name, rect[1], rect[3], rect[2], rect[4], entry.room.name, where, y1, y2, ceiling))
							end
						end
					end

					if #covered > 0 then
						report(GROUND_Y - DIM.FloorThickness, "under the manor")
					end
					if #buried > 0 then
						report(vaultUnderside, "past the footprint")
					end
				end
			end
		end
	end

	return count, offenders
end

-- ------------------------------------------------------------
-- STATION FACING. INFORMATIONAL, NOT A FAILURE - and deliberately so.
--
-- The rule it reports on: a station object with an obvious front presents that
-- front toward its InteractPoint, and the InteractPoint sits on the APPROACH
-- side - between the room's doorway and the object - so you walk in and the thing
-- you came for is already facing you. The first half is guaranteed by
-- construction (buildStations derives the InteractPoint from the same `face` the
-- kit builds its front from); the second half is not, because it depends on where
-- the doorway landed, and that is what this measures.
--
-- WALL-MOUNTED STATIONS ARE EXEMPT. A panel, frame or cabinet fixed to a wall has
-- exactly one possible front and no choice to get wrong; only free-standing
-- objects - a piano, a chest, a valve on a boiler - can be turned the wrong way.
-- A station is taken to be wall-mounted when its anchor sits on one of its room's
-- own edges.
--
-- This REPORTS rather than fails because a valve is sometimes correctly on the
-- far side of the machine it belongs to. The line exists so that a station facing
-- away from the way in is a decision somebody made, not one nobody noticed.
-- ------------------------------------------------------------
local function checkStationFacing(ctx)
	local results = {}
	for _, station in ipairs(ctx.stationFronts) do
		local room = station.room
		local wallMounted = false
		for _, r in ipairs(room.rects) do
			local nearest = math.min(
				math.abs(station.at[1] - r[1]), math.abs(station.at[1] - r[3]),
				math.abs(station.at[2] - r[2]), math.abs(station.at[2] - r[4]))
			if nearest <= DIM.WallThickness then
				wallMounted = true
			end
		end

		if not wallMounted then
			-- The nearest doorway of this room, found the same way the door itself
			-- is placed so the two can never disagree.
			local best, bestDistance
			for _, pair in ipairs(PLAN.Doors) do
				local otherName = (pair[1] == room.name and pair[2])
					or (pair[2] == room.name and pair[1]) or nil
				local other = otherName and ctx.rooms[otherName]
				local shared = other and findSharedWall(room, other)
				if shared then
					local mid = (shared.span[1] + shared.span[2]) / 2
					local dx, dz
					if shared.axis == "X" then
						dx, dz = shared.coord, mid
					else
						dx, dz = mid, shared.coord
					end
					local distance = math.sqrt((dx - station.at[1]) ^ 2 + (dz - station.at[2]) ^ 2)
					if not bestDistance or distance < bestDistance then
						best, bestDistance = { dx, dz }, distance
					end
				end
			end

			if best then
				local toPointX = station.interact[1] - station.at[1]
				local toPointZ = station.interact[2] - station.at[2]
				-- 1. Is the InteractPoint on the object's FRONT side? This is
				--    guaranteed by construction - buildStations derives the point
				--    from the same `face` the kit builds its front from - so it is
				--    measured rather than assumed precisely because a future kit
				--    could quietly stop honouring `face`, which is exactly what the
				--    Reliquary did with its hardcoded clasp.
				local frontX, frontZ = faceDir(station.face)
				local frontAligned = (toPointX * frontX + toPointZ * frontZ) > 0
				-- 2. Is it on the APPROACH side - between the doorway and the
				--    object? Not guaranteed, because it depends where the doorway is.
				local toDoorX = best[1] - station.at[1]
				local toDoorZ = best[2] - station.at[2]
				table.insert(results, {
					name = station.name,
					room = room.name,
					frontAligned = frontAligned,
					onApproachSide = (toPointX * toDoorX + toPointZ * toDoorZ) > 0,
					face = station.face,
					doorAt = string.format("(%.1f, %.1f)", best[1], best[2]),
					interactAt = string.format("(%.1f, %.1f)", station.interact[1], station.interact[2]),
				})
			end
		end
	end
	return results
end

-- ------------------------------------------------------------
-- KIT CONTAINMENT VALIDATOR. General hardening, and the class it exists for is
-- the one every dressing pass produces: a run of furniture sized from a `len` in
-- the plan, and nobody checked whether that length fits between the walls. A
-- bookcase whose end pokes through into the next room, a counter run crossing a
-- doorway, a stair rail hanging outside its stairwell - all of them look fine in
-- the table and wrong the moment you walk in.
--
-- Every part in a ROOM's folder must lie within that room's own footprint, and
-- every part in the STAIRS folder within its stair's host room. The tolerance is
-- half a wall: props legitimately reach the room boundary, because that is where
-- the wall's centreline is, and a wall-mounted item lives in its own wall's near
-- face. Anything further has crossed the plane into somebody else's room.
--
-- Rotated parts are measured by their world AABB, which OVER-states their reach -
-- so this can only ever be pessimistic, never permissive.
-- ------------------------------------------------------------
local function partWorldRect(part)
	local cf, s = part.CFrame, part.Size
	-- Axis-aligned extent of an arbitrarily rotated box.
	local rx = math.abs(cf.RightVector.X) * s.X / 2 + math.abs(cf.UpVector.X) * s.Y / 2 + math.abs(cf.LookVector.X) * s.Z / 2
	local rz = math.abs(cf.RightVector.Z) * s.X / 2 + math.abs(cf.UpVector.Z) * s.Y / 2 + math.abs(cf.LookVector.Z) * s.Z / 2
	local p = cf.Position
	return { p.X - rx, p.Z - rz, p.X + rx, p.Z + rz }
end

local function checkContainment(ctx)
	local tolerance = DIM.WallThickness / 2
	local count, offenders = 0, {}

	local function scan(folder, rects, label)
		if not folder then
			return
		end
		local grown = {}
		for _, r in ipairs(rects) do
			table.insert(grown, { r[1] - tolerance, r[2] - tolerance, r[3] + tolerance, r[4] + tolerance })
		end
		for _, part in ipairs(folder:GetDescendants()) do
			-- InteractPoints are markers, not geometry, and the Convergence zone is
			-- a deliberately oversized trigger volume - neither is something a
			-- player can walk into.
			if part:IsA("BasePart") and part.Name ~= "InteractPoint" and part.Name ~= "ConvergenceZone" then
				local rect = partWorldRect(part)
				local escaped = rectSubtractMany({ rect }, grown)
				local area = 0
				for _, piece in ipairs(escaped) do
					area = area + (piece[3] - piece[1]) * (piece[4] - piece[2])
				end
				-- A hair of overhang is float noise, not a defect.
				if area > 0.05 then
					count = count + 1
					if #offenders < 10 then
						table.insert(offenders, string.format(
							"%s / %s  X[%.1f..%.1f] Z[%.1f..%.1f] reaches %.1f studs^2 outside %s",
							label, part.Name, rect[1], rect[3], rect[2], rect[4], area, label))
					end
				end
			end
		end
	end

	for _, room in ipairs(PLAN.Rooms) do
		scan(ctx.folders[room.name], room.rects, room.name)
	end
	for _, stair in ipairs(ctx.stairs) do
		local folder = ctx.stairFolder and ctx.stairFolder:FindFirstChild(stair.name)
		scan(folder, stair.host.rects, stair.name)
	end

	return count, offenders
end

-- ------------------------------------------------------------
-- GAMEPLAY MANIFEST VALIDATOR. Every other check in this file asks whether the
-- ARCHITECTURE is sound. This one asks the only question that decides whether a
-- match can actually be played on the map: did the build put out everything the
-- runtime is going to go looking for, wearing the tags and attributes it expects?
--
-- IT IS COUNTED OFF THE BUILT MODEL, NOT OFF THE PLAN. Counting PLAN.Stations
-- would prove only that the table has ten rows; this walks the model's
-- descendants and checks the tag the handler queries and the attribute the
-- handler reads, which is what would actually have been missing.
--
-- The failure modes it exists for are all silent ones: a TaskStation with no
-- TaskType falls back to the Generic minigame and the authored task is quietly
-- gone; a SabotageStation with a typo'd FixId is rejected by RegisterFixStation
-- and its fix prompt simply never appears mid-sabotage; a brazier with a
-- duplicate index is dropped by RitualService's registry, lowering the ritual's
-- ceiling by one with no visible sign. None of these throw. All of them ruin a
-- match. TARGETS: 10 / 3 / 8 (indices 1-8) / 1 / 1 / 1 / N lamps / 2.
-- ------------------------------------------------------------
local function checkManifest(ctx)
	local found = {
		tasks = {},      -- { name, taskType }
		sabotage = {},   -- { name, sabotageType, fixId }
		brazierIndex = {},
		zones = 0,
		buttons = 0,
		spawns = 0,
		lamps = 0,
		secrets = 0,
		unlit = {},      -- tagged RoomLamps with no Enabled light instance
		byRoom = {},     -- room name -> lamp count
		positions = {},  -- room name -> lamp positions, for the corridor gap test
		gaps = {},       -- corridor name -> largest unlit stretch
	}

	for _, inst in ipairs(ctx.model:GetDescendants()) do
		if inst:IsA("SpawnLocation") then
			found.spawns = found.spawns + 1
		end
		if inst:IsA("BasePart") then
			if CollectionService:HasTag(inst, TAGS.TaskStation) then
				table.insert(found.tasks, { name = inst.Name, taskType = inst:GetAttribute("TaskType") })
			end
			if CollectionService:HasTag(inst, TAGS.SabotageStation) then
				table.insert(found.sabotage, {
					name = inst.Name,
					sabotageType = inst:GetAttribute("SabotageType"),
					fixId = inst:GetAttribute("FixId"),
				})
			end
			if CollectionService:HasTag(inst, TAGS.Brazier) then
				table.insert(found.brazierIndex, { name = inst.Name, index = inst:GetAttribute("BrazierIndex") })
			end
			if CollectionService:HasTag(inst, TAGS.ConvergenceZone) then
				found.zones = found.zones + 1
			end
			if CollectionService:HasTag(inst, TAGS.EmergencyButton) then
				found.buttons = found.buttons + 1
			end
			if CollectionService:HasTag(inst, TAGS.RoomLamp) then
				found.lamps = found.lamps + 1
				-- A LAMP THAT EMITS NOTHING. LightsSystem's whole diegetic layer is
				-- "switch off every light instance under the tagged part" - so a
				-- tagged part with no Enabled light is a fixture that looks like a
				-- lamp, counts as a lamp, and does nothing when the manor goes dark
				-- because it was never doing anything to begin with. The Kitchen
				-- pendant was exactly that. It fails silently in both directions,
				-- which is why it is counted rather than trusted.
				local lit = false
				for _, desc in ipairs(inst:GetDescendants()) do
					if (desc:IsA("PointLight") or desc:IsA("SpotLight") or desc:IsA("SurfaceLight"))
						and desc.Enabled and desc.Brightness > 0 then
						lit = true
						break
					end
				end
				if not lit then
					table.insert(found.unlit, inst.Name)
				end
				-- Per-room tally, so a dark room is a number rather than something
				-- somebody has to walk into to discover.
				local roomFolder = inst:FindFirstAncestorWhichIsA("Folder")
				while roomFolder and roomFolder.Parent and roomFolder.Parent.Name ~= "Rooms" do
					roomFolder = roomFolder.Parent:IsA("Folder") and roomFolder.Parent or nil
				end
				if roomFolder then
					found.byRoom[roomFolder.Name] = (found.byRoom[roomFolder.Name] or 0) + 1
					found.positions[roomFolder.Name] = found.positions[roomFolder.Name] or {}
					table.insert(found.positions[roomFolder.Name], inst.Position)
				end
			end
			if CollectionService:HasTag(inst, TAGS.SecretPassage) then
				found.secrets = found.secrets + 1
			end
		end
	end

	local problems = {}
	local function expect(label, got, want)
		if got ~= want then
			table.insert(problems, string.format("%s: %d, expected %d", label, got, want))
		end
	end

	expect("TaskStations", #found.tasks, #PLAN.Stations)
	for _, station in ipairs(found.tasks) do
		if type(station.taskType) ~= "string" then
			table.insert(problems, string.format("TaskStation '%s' has NO TaskType attribute - it falls back to the Generic minigame", station.name))
		end
	end

	expect("SabotageStations", #found.sabotage, #PLAN.Sabotage)
	for _, station in ipairs(found.sabotage) do
		if type(station.sabotageType) ~= "string" then
			table.insert(problems, string.format("SabotageStation '%s' has NO SabotageType attribute - the handler skips it", station.name))
		end
		if type(station.fixId) ~= "string" then
			table.insert(problems, string.format("SabotageStation '%s' has NO FixId attribute - the handler skips it", station.name))
		end
	end

	expect("Braziers", #found.brazierIndex, DIM.BrazierCount)
	local seenIndex = {}
	for _, brazier in ipairs(found.brazierIndex) do
		local index = brazier.index
		if type(index) ~= "number" then
			table.insert(problems, string.format("Brazier '%s' has NO numeric BrazierIndex - RitualService will never light it", brazier.name))
		elseif seenIndex[index] then
			table.insert(problems, string.format("DUPLICATE BrazierIndex %d ('%s' and '%s') - only the first registers", index, seenIndex[index], brazier.name))
		else
			seenIndex[index] = brazier.name
		end
	end
	for i = 1, DIM.BrazierCount do
		if not seenIndex[i] then
			table.insert(problems, string.format("GAP in the brazier numbering: no brazier carries index %d", i))
		end
	end

	expect("ConvergenceZone", found.zones, 1)
	expect("EmergencyButton", found.buttons, 1)
	expect("SpawnLocation", found.spawns, 1)
	expect("SecretPassages", found.secrets, #PLAN.Secrets)
	-- RoomLamps have no target on purpose: one chandelier is six tagged bulbs, so
	-- the honest check is "are there any at all", and the count is reported for
	-- tuning rather than asserted. See PLAN.Lamps.
	if found.lamps == 0 then
		table.insert(problems, "RoomLamps: 0 - nothing in the manor responds to a Snuffing sabotage")
	end
	for _, name in ipairs(found.unlit) do
		table.insert(problems, string.format("RoomLamp '%s' contains NO enabled light - it is a fixture pretending to be a lamp", name))
	end

	-- Per-room coverage, and the corridor dark-patch test.
	for _, room in ipairs(PLAN.Rooms) do
		local n = found.byRoom[room.name] or 0
		if n == 0 then
			table.insert(problems, string.format("room '%s' has NO room lamps at all", room.name))
		end

		-- A CORRIDOR is derived, not listed: any room rect three times longer than
		-- it is wide is one, which catches the Gallery's legs and the Great Hall
		-- spine without a table anyone can forget to update. Lamps are projected
		-- onto the long axis and the largest stretch between them - INCLUDING the
		-- stretch from each end wall - is the dark patch a player walks through.
		for _, r in ipairs(room.rects) do
			local spanX, spanZ = r[3] - r[1], r[4] - r[2]
			local long = math.max(spanX, spanZ)
			local short = math.min(spanX, spanZ)
			if short > EPS and long / short >= 3 then
				local alongX = spanX > spanZ
				local lo, hi = alongX and r[1] or r[2], alongX and r[3] or r[4]
				local marks = {}
				for _, position in ipairs(found.positions[room.name] or {}) do
					local across = alongX and position.Z or position.X
					local along = alongX and position.X or position.Z
					local a1, a2 = alongX and r[2] or r[1], alongX and r[4] or r[3]
					if across >= a1 - 1 and across <= a2 + 1 and along >= lo - 1 and along <= hi + 1 then
						table.insert(marks, along)
					end
				end
				table.sort(marks)
				local worst, previous = 0, lo
				for _, mark in ipairs(marks) do
					worst = math.max(worst, mark - previous)
					previous = mark
				end
				worst = math.max(worst, hi - previous)
				local label = string.format("%s X[%.0f..%.0f] Z[%.0f..%.0f]", room.name, r[1], r[3], r[2], r[4])
				found.gaps[label] = worst
				if worst > DIM.SconceMaxGap + EPS then
					table.insert(problems, string.format(
						"corridor %s has a %.0f-stud unlit stretch (max %d) - %d lamps on a %.0f-stud run",
						label, worst, DIM.SconceMaxGap, #marks, long))
				end
			end
		end
	end

	return found, problems
end

-- ------------------------------------------------------------
-- CONTEXT. One pass over the PLAN that produces every index the geometry
-- passes read, so no builder function ever walks PLAN.Rooms looking for things.
-- ------------------------------------------------------------
local function emptyByFloor()
	return { Ground = { X = {}, Z = {} }, Cellar = { X = {}, Z = {} } }
end

local function prepare(model, warnings)
	local ctx = {
		model = model,
		rooms = {},
		rectsByFloor = { Ground = {}, Cellar = {} },
		folders = {},
		openings = emptyByFloor(),
		coverage = emptyByFloor(),
		sameRoom = emptyByFloor(),
		-- Spans where SOLID wall went up, as distinct from `coverage` which counts
		-- intentional holes too. checkStairs() needs the difference: a stair whose
		-- exit is behind an unbroken wall is sealed, one whose exit crosses a
		-- doorway is not.
		solid = emptyByFloor(),
		-- Ground-floor exterior runs, collected so the plinth skirt can follow the
		-- manor's real irregular outline instead of a bounding box.
		exteriorRuns = {},
		ceilingTops = {},
		-- Vault-lid rects the floor pass sank below the lawn, so buildGrounds knows
		-- exactly where to lay turf over them. See the burial rule.
		buriedRects = {},
		-- The boundary strips the floor pass closed with stone fascia; the turf is
		-- carved back off them so no grass reaches a cellar interior.
		fasciaRects = {},
		-- The derived stair assemblies (deriveStairs). PLAN.Stairs carries no
		-- geometry any more, so this is the only place a shaft rect exists.
		stairs = {},
		-- Every station's anchor, declared front and InteractPoint, recorded as it
		-- is built so checkStationFacing can ask whether the front points at the
		-- way in. See the station-facing rule.
		stationFronts = {},
	}

	local floorsFolder = Instance.new("Folder")
	floorsFolder.Name = "Rooms"
	floorsFolder.Parent = model
	ctx.stairFolder = Instance.new("Folder")
	ctx.stairFolder.Name = "Stairs"
	ctx.stairFolder.Parent = model

	-- ONE FOLDER PER ROOM inside the model. This is the organization the map
	-- team edits in: select a folder, you have selected exactly one room.
	for _, room in ipairs(PLAN.Rooms) do
		if ctx.rooms[room.name] then
			table.insert(warnings, "duplicate room name in PLAN.Rooms: " .. room.name)
		end
		ctx.rooms[room.name] = room
		local folder = Instance.new("Folder")
		folder.Name = room.name
		folder.Parent = floorsFolder
		ctx.folders[room.name] = folder
		for _, rect in ipairs(room.rects) do
			table.insert(ctx.rectsByFloor[room.floor], { rect = rect, room = room })
		end
	end

	ctx.planes = buildPlanes(ctx.rectsByFloor)

	-- Full ground footprint: reported in the summary and used to size the grounds
	-- slab. The roof no longer needs a bounding box of its own now that wings
	-- carry explicit rects.
	local function bounds(predicate)
		local minX, minZ, maxX, maxZ
		for _, entry in ipairs(ctx.rectsByFloor.Ground) do
			if predicate(entry.room) then
				local r = entry.rect
				minX = math.min(minX or r[1], r[1])
				minZ = math.min(minZ or r[2], r[2])
				maxX = math.max(maxX or r[3], r[3])
				maxZ = math.max(maxZ or r[4], r[4])
			end
		end
		return { minX, minZ, maxX, maxZ }
	end
	ctx.fullBounds = bounds(function()
		return true
	end)

	return ctx
end

-- ------------------------------------------------------------
-- DOORWAYS. Derived from PLAN.Doors adjacency, never hand-placed. A pair whose
-- rooms do not actually touch is REPORTED rather than skipped quietly - a
-- missing door means a sealed room, and a sealed room is not something anyone
-- should have to discover by walking into it.
-- ------------------------------------------------------------
local function placeDoors(ctx, warnings)
	for _, pair in ipairs(PLAN.Doors) do
		local a, b = ctx.rooms[pair[1]], ctx.rooms[pair[2]]
		local shared = (a and b) and findSharedWall(a, b) or nil
		local width = shared and (shared.span[2] - shared.span[1]) or 0

		if not a or not b then
			table.insert(warnings, string.format("door names an unknown room: %s <-> %s", tostring(pair[1]), tostring(pair[2])))
		elseif not shared then
			table.insert(warnings, string.format("NO SHARED WALL for door %s <-> %s - that room pair is sealed", a.name, b.name))
		elseif width < DIM.DoorWidth + 1 then
			table.insert(warnings, string.format("shared wall %s <-> %s is only %.1f wide; door needs %d", a.name, b.name, width, DIM.DoorWidth + 1))
		else
			local center = (shared.span[1] + shared.span[2]) / 2
			local height = math.min(roomHeight(a), roomHeight(b)) - 2
			addOpening(ctx.openings, a.floor, shared.axis, shared.coord,
				center - DIM.DoorWidth / 2, center + DIM.DoorWidth / 2,
				{ kind = "Door", sill = 0, head = math.min(DIM.DoorHeight, height), insideDir = 1 })
			counters.doors = counters.doors + 1
		end
	end
end

-- ------------------------------------------------------------
-- WINDOWS. Only ever placed on spans that resolve to EXTERIOR wall, so a listed
-- side that turns out to face another room costs nothing and is simply skipped.
-- ------------------------------------------------------------
local function placeWindows(ctx, skipped)
	for _, spec in ipairs(PLAN.Windows) do
		local room = ctx.rooms[spec.room]
		if room then
			local placedAny = false
			for _, sideName in ipairs(spec.sides) do
				for _, ex in ipairs(exteriorSpans(ctx.planes, room, sideName)) do
					-- EVERY exterior run is treated the same way, independently.
					-- There is no room-level budget to share out and no sorting by
					-- length, which is what removes both the mixed spacing and the
					-- corner clustering the review found on the Parlor.
					local length = ex.span[2] - ex.span[1]
					local margin = DIM.WindowCornerMargin
					local usable = length - margin * 2
					if usable >= DIM.WindowWidth then
						-- One per WindowPitch studs of run, capped at what fits
						-- while keeping a full pier between neighbours.
						local fits = math.floor(usable / (DIM.WindowWidth + margin))
						local wanted = math.floor(length / DIM.WindowPitch)
						local count = math.max(1, math.min(math.max(fits, 1), math.max(wanted, 1)))
						for i = 1, count do
							-- Centered in an equal share of the usable run, so
							-- spacing and both end margins come out even.
							local center = ex.span[1] + margin + usable * (i - 0.5) / count
							addOpening(ctx.openings, room.floor, ex.spec.axis, ex.coord,
								center - DIM.WindowWidth / 2, center + DIM.WindowWidth / 2,
								{ kind = "Window", sill = DIM.WindowSill, head = DIM.WindowHead, insideDir = ex.spec.insideDir })
							counters.windows = counters.windows + 1
							placedAny = true
						end
					end
				end
			end

			if not placedAny then
				table.insert(skipped, string.format("%s (%s)", spec.room, table.concat(spec.sides, "/")))
			end
		end
	end
end

-- ------------------------------------------------------------
-- LIGHTING BASELINE. Night, moonlit, and deliberately dim.
-- ------------------------------------------------------------
local function applyLighting()
	Lighting.ClockTime = 23.5
	Lighting.Ambient = Color3.fromRGB(32, 32, 38)
	Lighting.OutdoorAmbient = Color3.fromRGB(46, 46, 56)
	Lighting.Brightness = 1.2
	Lighting.FogEnd = 100000
end

-- ============================================================
-- BUILD - the only entry point. Run it from the Command Bar in EDIT mode.
-- ============================================================
function EstateBuilder.Build()
	-- The header's "never at runtime" rule, enforced rather than requested. A
	-- live server rebuilding the manor mid-round would delete the floor out from
	-- under everyone; refusing is strictly better than trusting the comment.
	if RunService:IsRunning() then
		error("[EstateBuilder] EDIT-TIME TOOL. Build() must not run in a live or Play-mode session. Stop the session and run it from the Command Bar in Edit mode.", 0)
	end

	-- IDEMPOTENCE: clear before building, so running this fifty times leaves one
	-- manor rather than fifty interpenetrating ones.
	local existing = Workspace:FindFirstChild(MODEL_NAME)
	if existing then
		existing:Destroy()
		print("[EstateBuilder] removed the previous " .. MODEL_NAME)
	end
	if DESTROY_TEST_MAP then
		local graybox = Workspace:FindFirstChild(TEST_MAP_NAME)
		if graybox then
			graybox:Destroy()
			print("[EstateBuilder] destroyed the retired graybox " .. TEST_MAP_NAME)
		end
	end

	counters = { parts = 0, doors = 0, windows = 0, stairs = 0, lights = 0 }

	local model = Instance.new("Model")
	model.Name = MODEL_NAME

	local warnings, skippedWindows = {}, {}
	local ctx = prepare(model, warnings)

	-- Stair orientation FIRST: the floor pass needs the derived shaft rects to cut
	-- its holes, and nothing about a stair is written down any more for it to read
	-- instead. See PLAN.Stairs.
	deriveStairs(ctx, warnings)

	-- Openings first: the wall pass has to know where the holes go before it
	-- decides what shape the wall segments are.
	placeDoors(ctx, warnings)
	placeWindows(ctx, skippedWindows)

	buildWalls(ctx, "Ground")
	buildWalls(ctx, "Cellar")
	buildFloorsAndCeilings(ctx)
	buildStairs(ctx)
	buildRoof(ctx)
	-- Grounds last of the SHELL: the plinth follows the exterior runs the wall
	-- pass collected.
	buildGrounds(ctx)

	-- ---- The dressing pass. Everything below stands ON the shell above. ----
	-- Ritual first, because the Parlor's floor is the one place where the order
	-- matters to a reader: the heart is the room, and the room's props (there are
	-- none, deliberately) come after it.
	buildRitual(ctx, warnings)
	buildFurnishings(ctx, warnings)
	buildStations(ctx, warnings)
	buildSabotageStations(ctx, warnings)
	buildSecrets(ctx, warnings)
	buildLamps(ctx, warnings)
	buildSpawn(ctx, warnings)

	model.Parent = Workspace
	applyLighting()

	local gaps = checkPerimeter(ctx)
	local stairResults = checkStairs(ctx)
	local exposedRoofs = checkRoofCoverage(ctx)
	local roofHits = checkRoofIntersections(ctx)
	local heightResults = checkDoubleHeight(ctx)
	local burialCount, burialOffenders = checkBurial(ctx)
	local manifest, manifestProblems = checkManifest(ctx)
	local containCount, containOffenders = checkContainment(ctx)
	local facingResults = checkStationFacing(ctx)

	-- ------------------------------------------------------------
	-- SUMMARY
	-- ------------------------------------------------------------
	local groundRooms, cellarRooms = 0, 0
	for _, room in ipairs(PLAN.Rooms) do
		if room.floor == "Cellar" then
			cellarRooms = cellarRooms + 1
		else
			groundRooms = groundRooms + 1
		end
	end

	local b = ctx.fullBounds
	local parlor = ctx.rooms.SeanceParlor.rects[1]
	local parlorX = (parlor[1] + parlor[3]) / 2
	local parlorZ = (parlor[2] + parlor[4]) / 2

	-- FIRST line of the summary, deliberately above the banner: if this does not
	-- match REVISION at the top of the file, Studio ran a stale module.
	print(string.format("[EstateBuilder] rev %s", REVISION))
	print("========================================================")
	print("[EstateBuilder] THE ESTATE - architectural shell built.")
	print(string.format("  Rooms:    %d ground, %d cellar (%d total)", groundRooms, cellarRooms, groundRooms + cellarRooms))
	print(string.format("  Openings: %d doorways, %d windows, %d stairs", counters.doors, counters.windows, counters.stairs))
	print(string.format("  Roofs:    %d wings pitched per-wing, plus the Conservatory's glass", #PLAN.Roofs))
	print(string.format("  Parts:    %d, including %d placeholder moonlights", counters.parts, counters.lights))
	print(string.format("  Footprint: %.0f x %.0f studs, X[%.0f..%.0f] Z[%.0f..%.0f]",
		b[3] - b[1], b[4] - b[2], b[1], b[3], b[2], b[4]))
	print("--------------------------------------------------------")
	print(string.format("  *** THE MEETING / RITUAL CENTER: (%.1f, %.1f, %.1f) ***", parlorX, GROUND_Y, parlorZ))
	print("      The Seance Parlor's floor center, and now everything is ON it:")
	print("      the seance table, the Convergence inlay and zone, the ring of")
	print("      eight braziers, the emergency button - and MeetingSystem's")
	print("      MEETING_TABLE_CENTER, which this build's companion edit moved to")
	print("      match. If those two ever disagree, meetings teleport players into")
	print("      an empty room and the map is at fault, not the meeting code.")
	print("--------------------------------------------------------")

	if #gaps == 0 then
		print("  Perimeter check:  PASS - no unwalled exterior edge found.")
	else
		warn(string.format("[EstateBuilder] Perimeter check: %d GAP(S) - the manor is open to the sky somewhere:", #gaps))
		for _, gap in ipairs(gaps) do
			warn("    " .. gap)
		end
	end

	-- Stair connectivity: the failure class the perimeter check cannot see.
	-- Stairs: connectivity AND the geometric facing test. The numbers are printed
	-- whether it passes or fails, because the whole point of replacing the old
	-- assertion is that the verdict must be checkable by eye against the geometry.
	local stairsOk = true
	for _, result in ipairs(stairResults) do
		local verdict = result.ok and "PASS" or "*** FAIL ***"
		local emit = result.ok and print or warn
		if not result.ok then
			stairsOk = false
		end
		emit(string.format("  Stair check:      %s - %s  [in %s]  top -> %s,  bottom -> %s",
			verdict, result.name, result.host, result.topRoom, result.bottomRoom))
		emit(string.format("        doorway %s on the %s wall   top step %s   gap %.1f / %d",
			result.doorAt, result.doorSide, result.topAt, result.topGap, DIM.StairTopProximity))
		emit(string.format("        required D %s   actual descent %s   alignment %.2f / 1.00   %d steps, rise %.2f, tread %.2f",
			result.requiredD, result.descent, result.alignment, result.steps, result.rise, result.run))
		for _, problem in ipairs(result.problems) do
			warn("      - " .. problem)
		end
	end
	if not stairsOk then
		warn("[EstateBuilder]   A failing stair is UNWALKABLE, is cutting a pit through a room that was never meant to hold one,")
		warn("[EstateBuilder]   or is TURNED THE WRONG WAY - its descent vector must EQUAL D, the direction you face coming through the door.")
		warn("[EstateBuilder]   Orientation is DERIVED (deriveStairs): fix the room's shape or its doorway, never a hand-written shaft.")
	end

	if #exposedRoofs == 0 then
		print("  Roof coverage:    PASS - every ground room's ceiling is under roof.")
	else
		warn(string.format("[EstateBuilder] Roof coverage: %d EXPOSED AREA(S):", #exposedRoofs))
		for _, area in ipairs(exposedRoofs) do
			warn("    " .. area)
		end
	end

	-- Roof INSIDE a room, the opposite question to coverage. Target is zero.
	if #roofHits == 0 then
		print("  Roof/interior:    PASS - 0 roof parts inside any room's interior volume.")
	else
		warn(string.format("[EstateBuilder] *** ROOF/INTERIOR FAIL *** %d roof part(s) intersecting room interiors:", #roofHits))
		for index, hit in ipairs(roofHits) do
			if index > 10 then
				warn(string.format("      ... and %d more", #roofHits - 10))
				break
			end
			warn(string.format("      - %s  contains  %s", hit.room, hit.part))
		end
		warn("[EstateBuilder]   A lower roof must DIE INTO a taller wall, never through it. Check edgeAbutsTaller() for the offending wing's edge.")
	end

	-- Burial: is any of the cellar showing? Target is zero, and zero is the only
	-- passing answer - a stud of vault lid in the lawn is as wrong as ten.
	if burialCount == 0 then
		print("  Burial check:     PASS - 0 cellar parts breaking the ground slab or the lawn.")
	else
		warn(string.format("[EstateBuilder] *** BURIAL CHECK FAIL *** %d cellar part(s) protruding:", burialCount))
		for _, offender in ipairs(burialOffenders) do
			warn("      - " .. offender)
		end
		if burialCount > #burialOffenders then
			warn(string.format("      ... and %d more", burialCount - #burialOffenders))
		end
		warn("[EstateBuilder]   Under the manor the cellar stops at the ground slab's UNDERSIDE; past it, below the grass.")
		warn("[EstateBuilder]   Check DIM.VaultCover, the VaultLid sinking in buildFloorsAndCeilings, and the cellar wall tops in buildWalls.")
	end

	-- Kit containment: is any furniture standing in somebody else's room?
	if containCount == 0 then
		print("  Kit containment:  PASS - 0 kit parts reaching through a wall out of their room.")
	else
		warn(string.format("[EstateBuilder] *** CONTAINMENT FAIL *** %d kit part(s) crossing a wall plane:", containCount))
		for _, offender in ipairs(containOffenders) do
			warn("      - " .. offender)
		end
		if containCount > #containOffenders then
			warn(string.format("      ... and %d more", containCount - #containOffenders))
		end
		warn("[EstateBuilder]   Usually a `len` in PLAN.Furnish that does not fit between the walls, or an `at` too near a corner.")
	end

	-- The gameplay manifest: what the RUNTIME will find when it goes looking.
	print("--------------------------------------------------------")
	print("  Gameplay manifest (counted off the built model, not the plan):")
	print(string.format("    Task stations:     %d / %d", #manifest.tasks, #PLAN.Stations))
	print(string.format("    Sabotage stations: %d / %d", #manifest.sabotage, #PLAN.Sabotage))
	print(string.format("    Braziers:          %d / %d", #manifest.brazierIndex, DIM.BrazierCount))
	print(string.format("    Convergence zone:  %d / 1", manifest.zones))
	print(string.format("    Emergency button:  %d / 1", manifest.buttons))
	print(string.format("    Spawn location:    %d / 1", manifest.spawns))
	print(string.format("    Secret passages:   %d / %d   (RESERVATIONS - no mechanism)", manifest.secrets, #PLAN.Secrets))
	print(string.format("    Room lamps:        %d      (no target - one chandelier is several tagged bulbs)", manifest.lamps))
	print(string.format("    Unlit lamps:       %d / 0   (tagged RoomLamp with no enabled light)", #manifest.unlit))
	-- Per-room lamp coverage and the corridor dark-patch measurement, printed
	-- every build so "it is dark in there" is a number somebody can act on.
	local roomLine = {}
	for _, room in ipairs(PLAN.Rooms) do
		table.insert(roomLine, string.format("%s %d", room.name, manifest.byRoom[room.name] or 0))
	end
	print("    Lamps per room:    " .. table.concat(roomLine, ", "))
	for label, gap in pairs(manifest.gaps) do
		print(string.format("    Corridor gap:      %.0f / %d max   %s", gap, DIM.SconceMaxGap, label))
	end
	-- Station facing: INFORMATIONAL. Wall-mounted stations are exempt and absent
	-- from this list entirely - see checkStationFacing.
	local aimed, offFront = 0, 0
	for _, r in ipairs(facingResults) do
		if r.onApproachSide then
			aimed = aimed + 1
		end
		if not r.frontAligned then
			offFront = offFront + 1
		end
	end
	print(string.format("    Station facing:    %d / %d free-standing stations present their front to the way in; %d with an InteractPoint off the front (informational)",
		aimed, #facingResults, offFront))
	for _, r in ipairs(facingResults) do
		if not r.frontAligned then
			print(string.format("      note: %s in %s declares front %s but its InteractPoint %s is NOT on that side",
				r.name, r.room, r.face, r.interactAt))
		elseif not r.onApproachSide then
			print(string.format("      note: %s in %s faces %s - its InteractPoint %s is on the far side from the doorway at %s",
				r.name, r.room, r.face, r.interactAt, r.doorAt))
		end
	end
	if #manifestProblems == 0 then
		print("  Manifest check:   PASS - every gameplay part the runtime looks for is present and wired.")
	else
		warn(string.format("[EstateBuilder] *** MANIFEST FAIL *** %d problem(s) - the map is missing or mis-wiring gameplay:", #manifestProblems))
		for index, problem in ipairs(manifestProblems) do
			if index > 10 then
				warn(string.format("      ... and %d more", #manifestProblems - 10))
				break
			end
			warn("      - " .. problem)
		end
		warn("[EstateBuilder]   Every one of these fails SILENTLY at runtime: a missing TaskType becomes the Generic minigame,")
		warn("[EstateBuilder]   a bad FixId means the fix prompt never appears, a duplicate BrazierIndex is dropped from the ritual.")
	end

	for _, result in ipairs(heightResults) do
		if result.ok then
			print(string.format("  Double height:    PASS - %s ceiling at Y=%.0f.", result.name, result.built))
		else
			warn(string.format("[EstateBuilder] Double height: FAIL - %s built at %s, expected %d.",
				result.name, tostring(result.built), GROUND_Y + DIM.DoubleHeight))
		end
	end

	if #skippedWindows > 0 then
		print("  Window sides skipped (resolved to interior wall): " .. table.concat(skippedWindows, ", "))
	end
	for _, message in ipairs(warnings) do
		warn("[EstateBuilder] " .. message)
	end

	print("--------------------------------------------------------")
	print("  DRESSED, AND DELIBERATELY DIM. The manor is furnished, lamped and")
	print("  wired: ten task stations, three fix stations, the seance heart and a")
	print("  spawn. It is still meant to read CANDLELIT - the lamps are tuned low")
	print("  on purpose (DIM's lamp note), so 'it is dark in here' is the intent")
	print("  and not a bug. Braziers are built UNLIT; they light one per completed")
	print("  task in a live match.")
	print("  The two SecretPassage parts are RESERVATIONS: no mechanism, nothing")
	print("  reads them, and the visible seam is a deliberate tease.")
	print("  Every InteractPoint is a RESERVED ANCHOR for the diegetic-task")
	print("  animation pass - repairs are meant to happen at those spots, in the")
	print("  world, rather than in a floating window. Do not delete them.")
	print("  Save the place to keep it.")
	print("========================================================")

	return model
end

-- ------------------------------------------------------------
-- ROOFS - one pitch PER WING, replacing the single floating slab the review
-- rejected.
--
-- WHY THIS IS DATA AND NOT DERIVED. The obvious approach - take each connected
-- mass of ground rooms and roof its bounding rect - does not survive an H-plan.
-- Every 14-stud room in this manor is transitively connected, so there is only
-- ONE such mass, and its bounding rect swallows the Foyer and the Parlor: a roof
-- seated at 15 would slice straight through their 28-stud walls. Grouping by
-- height does not help either, because the low mass still wraps around the tall
-- rooms. Wings are therefore listed explicitly, which also happens to be the
-- thing a map artist wants to adjust.
--
-- Nor can a wing's rect be derived from the rooms it shelters, for the same
-- reason one step down: the Gallery is L-shaped, and the bounding rect of its
-- two legs covers the Parlor. Each wing therefore carries its own explicit
-- `rect` and the `wallHeight` it seats on. `rect`s must not overlap each other -
-- adjacent wings share an edge and their overhangs meet in a valley.
--
-- The eave sits flush on the wall top (wall height plus the ceiling slab, so
-- there is no air gap), the ridge runs along the longer side unless `ridgeAxis`
-- overrides, and checkRoofCoverage() verifies on every build that no ground
-- room's ceiling is left under open sky.
-- ------------------------------------------------------------
PLAN.Roofs = {
	{ name = "WestWing",         rect = {-72, -76, -36, 14},  wallHeight = 14 },
	{ name = "GalleryWing",      rect = {-36, -76, -22, 70},  wallHeight = 14 },
	-- The roof itself is WAIVED this pass; these three lines are only the wing
	-- rects following the rooms that moved beneath them, so the stair fix does
	-- not open new holes over StairHall, the Gallery spur or ServiceStair. No
	-- roof geometry or logic changed.
	{ name = "GallerySpurWing",  rect = {-22, -26, -7, 40},   wallHeight = 14 },
	{ name = "StairHallWing",    rect = {-22, 40, -7, 56},    wallHeight = 14 },
	{ name = "ServiceStairWing", rect = {33, 40, 45, 56},     wallHeight = 14 },
	{ name = "SpineWing",        rect = {-7, -26, 7, 56},     wallHeight = 14 },
	{ name = "KitchenWing",      rect = {7, 14, 33, 56},      wallHeight = 14 },
	{ name = "DiningWing",       rect = {22, 56, 58, 84},     wallHeight = 14 },
	{ name = "MusicWing",        rect = {-44, 70, -22, 90},   wallHeight = 14 },
	-- The two double-height rooms carry their own taller roofs; they must never
	-- be merged with anything shorter or the eave drops through their walls.
	{ name = "FoyerWing",        rect = {-22, 56, 22, 90},    wallHeight = 28 },
	{ name = "ParlorWing",       rect = {-22, -70, 22, -26},  wallHeight = 28 },
	-- Conservatory is EXEMPT and absent by design - it keeps its glass pitch.
}

EstateBuilder.PLAN = PLAN
EstateBuilder.PALETTE = PALETTE
EstateBuilder.DIM = DIM

return EstateBuilder
