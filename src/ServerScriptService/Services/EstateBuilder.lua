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

	SCOPE OF THIS PASS - the ARCHITECTURAL SHELL ONLY (docs/DESIGN.md sections
	1-2). Rooms, corridors, cellar, stairs, doorways, windows, ceilings, per-wing
	roofs, the grounds the manor sits in, and the night lighting rig. Build() also
	runs four validators - perimeter, stair connectivity, roof coverage and the
	double-height assertion - and prints their verdicts. There is deliberately NO furniture, NO task
	stations, NO braziers, NO séance table, NO spawn point and NO tagged
	gameplay parts. Those land in the NEXT prompt, gated on a review of this
	shell. The manor will look DARK and EMPTY. That is the deliverable, not a bug.

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
local REVISION = "68R4"

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

	StairRise        = 1,    -- 11 rises from Y=0 down to the cellar floor at Y=-11
	RailHeight       = 3.5,
	RailThickness    = 0.4,

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
	PlinthProud      = 0.6,
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
-- and not a teleport. `shaft` is the hole cut through the ground slab.
--
-- `descend` IS LOAD-BEARING and is the fix for the review's dead-end stair. It
-- names which way the flight runs DOWN, and it must point so the BOTTOM step
-- ends at the side where the cellar continues - otherwise the flight arrives
-- facing a wall and the only way out is back up the way you came. The shaft is
-- also deliberately SHORTER than the room it sits in, so there is standing floor
-- at the top to step from and at the bottom to step onto. checkStairs() verifies
-- both ends on every build; see the validator for why this cannot be eyeballed.
-- ------------------------------------------------------------
-- `room` NAMES THE GROUND ROOM THE SHAFT MUST LIE INSIDE, and it is checked.
-- The previous revision had no such field: the east flight simply declared
-- `from = "Kitchen"` and cut its shaft straight through the Kitchen floor, and
-- nothing in the builder objected. checkStairs() now verifies the shaft rect is
-- contained by this room and touches no other, so a stair can never again be
-- punched through a room that was not built to hold one.
PLAN.Stairs = {
	{
		name = "HallStair", room = "StairHall", to = "CellarHall",
		shaft = {-20, 40, -13, 52}, descend = "-Z",
		-- Inside StairHall {-22,40,-7,56}: 2 studs of pier west, 6 studs of
		-- walking floor east (the side the Great Hall door opens onto), and the
		-- 4-stud head landing at Z=52..56. Runs down toward -Z so the bottom step
		-- lands at Z=40 and opens north into the Cellar Hall's main spine.
		purpose = "The west flight, entirely inside StairHall.",
	},
	{
		name = "ServiceStair", room = "ServiceStair", to = "CellarLandingEast",
		shaft = {35, 44, 43, 56}, descend = "+Z",
		-- Inside ServiceStair {33,40,45,56}: 2 studs of pier each side and the
		-- 4-stud head landing at Z=40..44. Runs down toward +Z so the bottom step
		-- lands at Z=56 with CellarLandingEast's floor continuing south to Z=62.
		purpose = "The east flight, entirely inside ServiceStair - no longer a pit in the Kitchen floor.",
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
						if wantsGlass then
							emitGlassBand(folder, axis, coord, solid[1], solid[2], baseY, top)
						else
							emitWallBand(folder, axis, coord, solid[1], solid[2], baseY, top, baseY, style, "Wall")
						end
						table.insert(solidTable[coord], { solid[1], solid[2] })
					end

					-- The plinth follows exterior ground walls only, openings
					-- included: a doorway still meets the earth at its threshold.
					if isExterior and floorName == "Ground" then
						table.insert(ctx.exteriorRuns, { axis = axis, coord = coord, a = piece[1], b = piece[2] })
					end

					for _, opening in ipairs(mine) do
						if opening.sill > EPS then
							emitWallBand(folder, axis, coord, opening.a, opening.b,
								baseY, baseY + opening.sill, baseY, style, "Under" .. opening.kind)
						end
						if opening.head < height - EPS then
							emitWallBand(folder, axis, coord, opening.a, opening.b,
								baseY + opening.head, top, baseY, style, "Over" .. opening.kind)
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
local function buildFloorsAndCeilings(ctx)
	local shafts = {}
	for _, stair in ipairs(PLAN.Stairs) do
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
			-- Whatever the manor does not stand on is a buried vault top. Cellars
			-- reaching past the walls under the grounds is normal for a house this
			-- age; these read as terrace/ground from outside.
			local groundRects = {}
			for _, ground in ipairs(groundEntries) do
				table.insert(groundRects, ground.rect)
			end
			for _, buried in ipairs(rectSubtractMany({ lid }, groundRects)) do
				box(cellarFolder, "VaultLid", buried[1], GROUND_Y - DIM.FloorThickness, buried[2],
					buried[3], GROUND_Y, buried[4], MATERIALS.CellarStone, PALETTE.Stone)
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
-- STAIRS. Real stepped parts, one part per tread, inside the CellarHall alcoves
-- - so the enclosing walls come free from the ordinary cellar wall pass and the
-- stairwell is a room feature rather than a special case.
-- ------------------------------------------------------------
local function buildStairs(ctx)
	for _, stair in ipairs(PLAN.Stairs) do
		local folder = Instance.new("Folder")
		folder.Name = stair.name
		folder.Parent = ctx.stairFolder

		local x1, z1, x2, z2 = stair.shaft[1], stair.shaft[2], stair.shaft[3], stair.shaft[4]
		local drop = GROUND_Y - CELLAR_Y
		local steps = math.floor(drop / DIM.StairRise + 0.5)
		local run = (z2 - z1) / steps
		local downPlusZ = (stair.descend ~= "-Z")

		-- Tread i counts DOWN from the entry edge toward the exit edge, so which
		-- end of the shaft is the top depends entirely on `descend`. Getting this
		-- backwards is exactly the dead-end the shell review caught.
		for i = 1, steps do
			local za
			if downPlusZ then
				za = z1 + run * (i - 1)
			else
				za = z2 - run * i
			end
			local topY = GROUND_Y - DIM.StairRise * i
			box(folder, "Step", x1, topY - DIM.StairRise, za, x2, topY, za + run,
				MATERIALS.Timber, PALETTE.DarkWood)
		end

		-- SHAFT ENCLOSURE. Walls from the cellar floor up to the underside of the
		-- ground slab on the two long sides and the entry end, leaving only the
		-- EXIT end open. Built here rather than relying on cellar room boundaries,
		-- so the stairwell is enclosed by construction wherever the shaft happens
		-- to sit and cannot spill open into the room below.
		local wallTop = GROUND_Y - DIM.FloorThickness
		local w = DIM.WallThickness
		box(folder, "ShaftWall", x1 - w, CELLAR_Y, z1, x1, wallTop, z2,
			MATERIALS.CellarStone, PALETTE.Stone)
		box(folder, "ShaftWall", x2, CELLAR_Y, z1, x2 + w, wallTop, z2,
			MATERIALS.CellarStone, PALETTE.Stone)
		if downPlusZ then
			box(folder, "ShaftWall", x1 - w, CELLAR_Y, z1 - w, x2 + w, wallTop, z1,
				MATERIALS.CellarStone, PALETTE.Stone)
		else
			box(folder, "ShaftWall", x1 - w, CELLAR_Y, z2, x2 + w, wallTop, z2 + w,
				MATERIALS.CellarStone, PALETTE.Stone)
		end

		-- Brass rails around three edges of the hole at ground level, INSIDE the
		-- stair room only; the entry edge is left clear so there is a way in.
		local railTop = GROUND_Y + DIM.RailHeight
		local t = DIM.RailThickness
		local farZ = downPlusZ and z2 or z1
		box(folder, "Rail", x1 - t, GROUND_Y, z1, x1 + t, railTop, z2, MATERIALS.Trim, PALETTE.TrimBrass)
		box(folder, "Rail", x2 - t, GROUND_Y, z1, x2 + t, railTop, z2, MATERIALS.Trim, PALETTE.TrimBrass)
		box(folder, "Rail", x1, GROUND_Y, farZ - t, x2, railTop, farZ + t, MATERIALS.Trim, PALETTE.TrimBrass)

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
local function roomAtPoint(ctx, floorName, x, z)
	for _, entry in ipairs(ctx.rectsByFloor[floorName] or {}) do
		local r = entry.rect
		if x > r[1] + EPS and x < r[3] - EPS and z > r[2] + EPS and z < r[4] - EPS then
			return entry.room
		end
	end
	return nil
end

local function checkStairs(ctx)
	local results = {}
	for _, stair in ipairs(PLAN.Stairs) do
		local x1, z1, x2, z2 = stair.shaft[1], stair.shaft[2], stair.shaft[3], stair.shaft[4]
		local centerX = (x1 + x2) / 2
		local downPlusZ = (stair.descend ~= "-Z")
		local topEdge = downPlusZ and z1 or z2
		local bottomEdge = downPlusZ and z2 or z1
		local topProbe = topEdge + (downPlusZ and -1 or 1)
		local bottomProbe = bottomEdge + (downPlusZ and 1 or -1)

		local topRoom = roomAtPoint(ctx, "Ground", centerX, topProbe)
		local bottomRoom = roomAtPoint(ctx, "Cellar", centerX, bottomProbe)
		local topBlocked = spansContain(ctx.solid.Ground.Z[topEdge] or {}, centerX)
		local bottomBlocked = spansContain(ctx.solid.Cellar.Z[bottomEdge] or {}, centerX)

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
		local host = ctx.rooms[stair.room]
		if not host then
			table.insert(problems, "declares room '" .. tostring(stair.room) .. "', which is not in PLAN.Rooms")
		else
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
		end

		local destination = ctx.rooms[stair.to]
		if destination and bottomRoom and bottomRoom ~= destination then
			table.insert(problems, string.format("bottom step opens into %s, not the declared %s", bottomRoom.name, destination.name))
		end

		table.insert(results, {
			name = stair.name,
			ok = #problems == 0,
			host = stair.room,
			topRoom = topRoom and topRoom.name or "-",
			bottomRoom = bottomRoom and bottomRoom.name or "-",
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
-- ------------------------------------------------------------
local function buildGrounds(ctx)
	local folder = Instance.new("Folder")
	folder.Name = "Grounds"
	folder.Parent = ctx.model

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

	-- Plinth skirt, following the real exterior outline collected by the wall
	-- pass. Stands slightly proud of the wall face on both sides, which is what
	-- makes it read as a base course rather than a stripe painted on the wall.
	local half = DIM.WallThickness / 2 + DIM.PlinthProud
	for _, run in ipairs(ctx.exteriorRuns) do
		if run.axis == "X" then
			box(folder, "Plinth", run.coord - half, grassTop, run.a,
				run.coord + half, grassTop + DIM.PlinthHeight, run.b,
				MATERIALS.Plinth, PALETTE.Stone)
		else
			box(folder, "Plinth", run.a, grassTop, run.coord - half,
				run.b, grassTop + DIM.PlinthHeight, run.coord + half,
				MATERIALS.Plinth, PALETTE.Stone)
		end
	end
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

	-- Openings first: the wall pass has to know where the holes go before it
	-- decides what shape the wall segments are.
	placeDoors(ctx, warnings)
	placeWindows(ctx, skippedWindows)

	buildWalls(ctx, "Ground")
	buildWalls(ctx, "Cellar")
	buildFloorsAndCeilings(ctx)
	buildStairs(ctx)
	buildRoof(ctx)
	-- Grounds last: the plinth follows the exterior runs the wall pass collected.
	buildGrounds(ctx)

	model.Parent = Workspace
	applyLighting()

	local gaps = checkPerimeter(ctx)
	local stairResults = checkStairs(ctx)
	local exposedRoofs = checkRoofCoverage(ctx)
	local roofHits = checkRoofIntersections(ctx)
	local heightResults = checkDoubleHeight(ctx)

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
	print("      The Seance Parlor's floor center. NEXT PROMPT aligns to it:")
	print("      the seance table and MeetingSystem's MEETING_TABLE_CENTER (today")
	print("      still Vector3.new(0, 0, 0)), the brazier ring, and the")
	print("      Convergence circle. Nothing reads this constant yet.")
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
	local stairsOk = true
	for _, result in ipairs(stairResults) do
		if result.ok then
			print(string.format("  Stair check:      PASS - %s  [in %s]  top -> %s,  bottom -> %s",
				result.name, result.host, result.topRoom, result.bottomRoom))
		else
			stairsOk = false
			warn(string.format("[EstateBuilder] *** STAIR CHECK FAIL *** %s  [in %s]  top -> %s,  bottom -> %s",
				result.name, tostring(result.host), result.topRoom, result.bottomRoom))
			for _, problem in ipairs(result.problems) do
				warn("      - " .. problem)
			end
		end
	end
	if not stairsOk then
		warn("[EstateBuilder]   A failing stair is UNWALKABLE, or is cutting a pit through a room that was never meant to hold one.")
		warn("[EstateBuilder]   Stairs live ONLY inside their own dedicated room: fix PLAN.Stairs `shaft`/`room`/`descend`, not the room it broke into.")
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
	print("  UNFURNISHED BY DESIGN. No furniture, no task stations, no")
	print("  braziers, no seance table, no spawn point, no tagged parts - those")
	print("  are the NEXT prompt, gated on a review of this shell. Interiors are")
	print("  lit only by placeholder moonlight, so the manor WILL look dark until")
	print("  RoomLamps land. Both are expected; neither is a bug to report.")
	print("  The manor now sits in a grass slab that buries the cellar; the")
	print("  Grounds folder is scenery only and holds nothing gameplay reads.")
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
