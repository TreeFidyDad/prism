addon.name      = 'prism'
addon.author    = 'Blake & Watney'
addon.version = '0.7.11'
addon.desc      = 'Prism — floating skill overlay. Tier-colored crystals, donuts, or pills. Tracks combat, defense, magic & craft skill progress per main job.'
addon.commands  = { '/prism', '/pr' }

require('common')
local chat     = require('chat')
local settings = require('settings')
local imgui    = require('imgui')
local struct   = require('struct')

----------------------------------------------------------------
-- config
----------------------------------------------------------------
local default_config = T{
    visible      = true,
    x            = 20,
    y            = 320,
    display_mode = 'crystals', -- 'crystals' | 'donuts' | 'pills'
    per_row      = 3,        -- 1..N (N = number of visible skills)
    scale        = 1.0,      -- 0.6..2.0 visual scale multiplier
    sort_mode    = 'default',-- 'default' | 'grade' | 'lowest' | 'progress'
    show_capped  = false,    -- hide skills that are already at cap for current level
    -- Category visibility — Prism shows ALL skills your main job has access to,
    -- grouped by category. Toggle a category off to hide its whole group.
    show_combat  = true,     -- weapons + ranged
    combat_only_equipped = false, -- when true, Combat shows only currently-equipped weapons
    show_defense = true,     -- Guard / Evasion / Shield / Parry
    show_magic   = true,     -- main-job casting schools only (not sub-job spillover)
    show_craft   = true,     -- crafting + fishing (only the ones you've trained)
    persist_frac = true,     -- save fractional skill progress to disk; survives /logout
    chat_skillups = false,   -- enhanced chat line on skillup
    -- FFXI chat color codes (0..255) for fractional skillup magnitude. Defaults
    -- form a subtle->loud ramp (cream->cyan->salmon->magenta) so big skillups
    -- grab your eye and tiny ones fade. Override via the swatch picker in
    -- /prism settings.
    chat_color_low  = 106,   -- color for 0.1 skillups (cream, subtle)
    chat_color_mid  = 6,     -- color for 0.2 skillups (cyan, noticeable)
    chat_color_high = 76,    -- color for 0.3 skillups (salmon, loud)
    chat_color_max  = 5,     -- color for 0.4+ skillups (magenta, jackpot)
    chat_color_tick = 6,     -- color for "level up" integer ticks (cyan, celebratory)
    -- Per-skill visibility, keyed by SID (string keys for stable serialization).
    -- nil/missing => visible by default. Legacy global table (pre-0.7.2);
    -- kept for back-compat as a fallback when no per-job entry exists.
    skills_hidden = T{},
    -- Per-job per-skill visibility map: { [job_id_str] = { [sid_str] = true } }.
    -- Lets you hide Throwing on DRK but keep it visible on RNG, etc. Writes
    -- here on toggle from the settings UI or /prism hide; reads fall back to
    -- the legacy global skills_hidden table when a per-job entry is missing.
    skills_hidden_by_job = T{},
    -- Persisted fractional skill progress (sid -> 0.0..0.9). Filled by packet
    -- 0x29 / chat capture, reset on integer tick. Persisted so a /logout in
    -- the middle of grinding doesn't throw away the 0.1-0.9 you already earned.
    skill_frac   = T{},
}
local config = settings.load(default_config)
-- normalize legacy/invalid values so a hand-edit can't wedge the overlay
local function normalize_config()
    -- v0.7.4: 'gems' was folded into 'crystals' (the FF hex shape is now the
    -- default crystal). Migrate any saved 'gems' value silently.
    if config.display_mode == 'gems' then
        config.display_mode = 'crystals'
    end
    if  config.display_mode ~= 'pills'
    and config.display_mode ~= 'donuts'
    and config.display_mode ~= 'crystals' then
        config.display_mode = 'crystals'
    end
    if type(config.per_row) ~= 'number' then config.per_row = 3 end
    config.per_row = math.max(0, math.min(24, math.floor(config.per_row)))  -- 0 = "All" (dynamic)
    if type(config.scale) ~= 'number' then config.scale = 1.0 end
    config.scale = math.max(0.6, math.min(2.0, config.scale))
    if  config.sort_mode ~= 'default'
    and config.sort_mode ~= 'grade'
    and config.sort_mode ~= 'lowest'
    and config.sort_mode ~= 'progress' then
        config.sort_mode = 'default'
    end
    if type(config.x) ~= 'number' then config.x = 20 end
    if type(config.y) ~= 'number' then config.y = 320 end
    if type(config.skills_hidden) ~= 'table' then config.skills_hidden = T{} end
    if type(config.skills_hidden_by_job) ~= 'table' then config.skills_hidden_by_job = T{} end
    if type(config.persist_frac) ~= 'boolean' then config.persist_frac = true end
    if type(config.skill_frac) ~= 'table' then config.skill_frac = T{} end
    if type(config.chat_skillups) ~= 'boolean' then config.chat_skillups = false end
    if type(config.show_combat)  ~= 'boolean' then config.show_combat  = true end
    if type(config.combat_only_equipped) ~= 'boolean' then config.combat_only_equipped = false end
    if type(config.show_defense) ~= 'boolean' then config.show_defense = true end
    if type(config.show_magic)   ~= 'boolean' then config.show_magic   = true end
    if type(config.show_craft)   ~= 'boolean' then config.show_craft   = true end
    local function _norm_color(k, dflt)
        local v = tonumber(config[k])
        if not v then config[k] = dflt; return end
        config[k] = math.max(0, math.min(255, math.floor(v)))
    end
    _norm_color('chat_color_low',  8)
    _norm_color('chat_color_mid',  106)
    _norm_color('chat_color_high', 6)
end
normalize_config()

local function save() settings.save() end

-- Per-job hide is the source of truth as of v0.7.2. Reads look up the
-- per-job map first; if no entry exists for this job+sid, fall back to the
-- legacy global table so existing /prism hide users don't lose state on
-- upgrade. Writes go to the per-job map only (legacy table is read-only).
local function is_skill_hidden(sid, job_id)
    local k = tostring(sid)
    if job_id ~= nil then
        local row = config.skills_hidden_by_job[tostring(job_id)]
        if row and row[k] ~= nil then return row[k] == true end
    end
    return config.skills_hidden[k] == true
end
local function set_skill_hidden(sid, hidden, job_id)
    local k = tostring(sid)
    if job_id == nil then
        -- callsite didn't know the job — fall back to legacy global so we
        -- don't silently no-op. (Settings UI and /prism hide both pass job_id.)
        if hidden then config.skills_hidden[k] = true
        else config.skills_hidden[k] = nil end
        return
    end
    local jk = tostring(job_id)
    local row = config.skills_hidden_by_job[jk]
    if not row then row = T{}; config.skills_hidden_by_job[jk] = row end
    if hidden then row[k] = true else row[k] = nil end
end

settings.register('settings', 'settings_update', function(s)
    if s then config = s end
    normalize_config()
end)

local function say(msg)
    print(chat.header(addon.name):append(chat.message(msg)))
end

----------------------------------------------------------------
-- skill metadata (lifted from huntpartner; kept self-contained
-- so prism can load on its own)
----------------------------------------------------------------
local SKILL_NAMES = {
    [1]='H2H', [2]='Dagger', [3]='Sword', [4]='GSword', [5]='Axe', [6]='GAxe',
    [7]='Scythe', [8]='Polearm', [9]='Katana', [10]='GKatana', [11]='Club',
    [12]='Staff', [25]='Archery', [26]='Marksmanship', [27]='Throwing',
    -- defensive (passive, leveled by being hit / blocking / parrying)
    [28]='Guard', [29]='Evasion', [30]='Shield', [31]='Parry',
    [32]='Divine', [33]='Healing', [34]='Enhancing', [35]='Enfeebling',
    [36]='Elemental', [37]='Dark', [38]='Summoning', [39]='Ninjutsu',
    [40]='Singing', [41]='String', [42]='Wind',
    -- crafting / gathering (chat-line only -- no rank table, cap from engine)
    [48]='Fishing', [49]='Wood', [50]='Smith', [51]='Gold', [52]='Cloth',
    [53]='Leather', [54]='Bone', [55]='Alchemy', [56]='Cooking',
}

local MAGIC_SKILL_IDS = { 33, 34, 35, 32, 36, 37, 38, 39, 40, 41, 42 }

-- Skill IDs grouped by the four overlay categories Prism shows.
-- combat:  weapons + ranged. Filtered by JOB_SKILL_RANK[job].
-- defense: passive blocks. Filtered by JOB_SKILL_RANK[job] (Evasion/Parry/Shield/Guard).
-- magic:   casting schools. Filtered by JOB_MAGIC_SKILL_RANK[job] (cast allowlist).
-- craft:   crafting + fishing. Not job-gated; shown only when trained (cur>0 or frac>0).
local SKILL_CATEGORIES = {
    combat  = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 25, 26, 27 },
    defense = { 28, 29, 30, 31 },
    magic   = { 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42 },
    craft   = { 48, 49, 50, 51, 52, 53, 54, 55, 56 },
}

-- Inverse lookup: sid -> category. Built lazily.
local SKILL_CATEGORY = {}
for cat, sids in pairs(SKILL_CATEGORIES) do
    for _, sid in ipairs(sids) do SKILL_CATEGORY[sid] = cat end
end

-- Crafts live in a separate IPlayer:GetCraftSkill(idx) array (idx 0..8),
-- not in GetCombatSkill. Map our sid space (48..56) to that array.
local CRAFT_SID_TO_IDX = {
    [48] = 0,  -- Fishing
    [49] = 1,  -- Woodworking
    [50] = 2,  -- Smithing
    [51] = 3,  -- Goldsmithing
    [52] = 4,  -- Clothcraft
    [53] = 5,  -- Leathercraft
    [54] = 6,  -- Bonecraft
    [55] = 7,  -- Alchemy
    [56] = 8,  -- Cooking
}

-- Job-id -> 3-letter abbreviation, for settings-panel labels.
local JOB_ABBR = {
    [1]='WAR', [2]='MNK', [3]='WHM', [4]='BLM', [5]='RDM', [6]='THF',
    [7]='PLD', [8]='DRK', [9]='BST', [10]='BRD', [11]='RNG', [12]='SAM',
    [13]='NIN', [14]='DRG', [15]='SMN',
}

-- FFXI chat color palette for the skillup-color picker. Each entry is a
-- single-byte color code that AshitaCore can render in chat (\30<code>), paired
-- with an approximate sRGB triple so we can draw clickable swatches in the
-- settings panel. Calibrated empirically against HorizonXI's renderer via
-- /prism colortest -- note that HorizonXI's palette diverges from retail
-- Ashita stdlib (e.g. code 81 renders as violet here, not the bracket-yellow
-- that libs/chat.lua suggests). Codes that render as plain white on HorizonXI
-- (102, 200, 121, 39, 65) are omitted.
local CHAT_PALETTE = {
    { code = 1,   name = 'white',   rgb = { 1.00, 1.00, 1.00 } },
    { code = 106, name = 'cream',   rgb = { 1.00, 0.92, 0.65 } },
    { code = 104, name = 'yellow',  rgb = { 1.00, 0.95, 0.35 } },
    { code = 8,   name = 'orange',  rgb = { 1.00, 0.60, 0.25 } },
    { code = 93,  name = 'red',     rgb = { 1.00, 0.20, 0.20 } },
    { code = 99,  name = 'blood',   rgb = { 0.60, 0.10, 0.10 } },
    { code = 76,  name = 'salmon',  rgb = { 1.00, 0.55, 0.55 } },
    { code = 68,  name = 'pink',    rgb = { 1.00, 0.55, 0.75 } },
    { code = 5,   name = 'magenta', rgb = { 1.00, 0.45, 1.00 } },
    { code = 81,  name = 'violet',  rgb = { 0.70, 0.50, 1.00 } },
    { code = 71,  name = 'blue',    rgb = { 0.40, 0.55, 1.00 } },
    { code = 6,   name = 'cyan',    rgb = { 0.40, 0.95, 1.00 } },
    { code = 2,   name = 'green',   rgb = { 0.35, 1.00, 0.35 } },
    { code = 91,  name = 'black',   rgb = { 0.10, 0.10, 0.10 } },
}

-- Cast-gated magic skills only get skillups from casting (self/party
-- targets). All offensive magic is mob-level-gated like weapons, so we
-- show "Lv N+" for them just like combat skills.
local SKILL_IS_CAST_GATED = { [33]=true, [34]=true, [40]=true, [41]=true, [42]=true }

local RANK_LETTERS = {
    [0]='A+', [1]='A', [2]='A-', [3]='B+', [4]='B', [5]='B-',
    [6]='C+', [7]='C', [8]='C-', [9]='D',  [10]='E', [11]='F', [12]='G',
}

local RANK_SLOPES = {
    [0]=3.98, [1]=3.90, [2]=3.82, [3]=3.67, [4]=3.53, [5]=3.39,
    [6]=3.24, [7]=3.08, [8]=2.92, [9]=2.69, [10]=2.47, [11]=2.24, [12]=2.02,
}

-- HorizonXI-calibrated cap reference: per-level (1..75) cap for every rank.
-- Source: Nerf's HorizonXI skill-cap spreadsheet (every value, no interp).
-- Index = rank (12-slot retail scheme; HX has no plain "A" so slot 1
-- mirrors slot 2). Array index = level (1..75).
local CAP_REF = {
    [0] = { 6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57,60,63,66,69,72,75,78,81,84,87,90,93,96,99,102,105,108,111,114,117,120,123,126,129,132,135,138,141,144,147,150,153,158,163,168,173,178,183,188,193,198,203,207,212,217,222,227,232,236,241,246,251,256,261,266,271,276 }, -- A+
    [1] = { 6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57,60,63,66,69,72,75,78,81,84,87,90,93,96,99,102,105,108,111,114,117,120,123,126,129,132,135,138,141,144,147,150,153,158,163,168,173,178,183,188,193,198,203,207,211,215,219,223,227,231,235,239,244,249,254,259,264,269 }, -- A (HX uses A-)
    [2] = { 6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57,60,63,66,69,72,75,78,81,84,87,90,93,96,99,102,105,108,111,114,117,120,123,126,129,132,135,138,141,144,147,150,153,158,163,168,173,178,183,188,193,198,203,207,211,215,219,223,227,231,235,239,244,249,254,259,264,269 }, -- A-
    [3] = { 5,7,10,13,16,19,22,25,28,31,34,36,39,42,45,48,51,54,57,60,63,65,68,71,74,77,80,83,86,89,92,94,97,100,103,106,109,112,115,118,121,123,126,129,132,135,138,141,144,147,151,156,161,166,171,176,181,186,191,196,199,203,207,210,214,218,221,225,229,233,237,241,246,251,256 }, -- B+
    [4] = { 5,7,10,13,16,19,22,25,28,31,34,36,39,42,45,48,51,54,57,60,63,65,68,71,74,77,80,83,86,89,92,94,97,100,103,106,109,112,115,118,121,123,126,129,132,135,138,141,144,147,151,156,161,166,171,176,181,186,191,196,199,202,205,208,212,215,218,221,225,228,232,236,240,245,250 }, -- B
    [5] = { 5,7,10,13,16,19,22,25,28,31,34,36,39,42,45,48,51,54,57,60,63,65,68,71,74,77,80,83,86,89,92,94,97,100,103,106,109,112,115,118,121,123,126,129,132,135,138,141,144,147,151,156,161,166,171,176,181,186,191,196,198,201,204,206,209,212,214,217,220,223,226,229,232,236,240 }, -- B-
    [6] = { 5,7,10,13,16,19,21,24,27,30,33,35,38,41,44,47,49,52,55,58,61,63,66,69,72,75,77,80,83,86,89,91,94,97,100,103,105,108,111,114,117,119,122,125,128,131,133,136,139,142,146,151,156,161,166,170,175,180,185,190,192,195,197,200,202,205,207,210,212,215,218,221,224,227,230 }, -- C+
    [7] = { 5,7,10,13,16,19,21,24,27,30,33,35,38,41,44,47,49,52,55,58,61,63,66,69,72,75,77,80,83,86,89,91,94,97,100,103,105,108,111,114,117,119,122,125,128,131,133,136,139,142,146,151,156,161,166,170,175,180,185,190,192,194,196,199,201,203,205,208,210,212,214,217,219,222,225 }, -- C
    [8] = { 5,7,10,13,16,19,21,24,27,30,33,35,38,41,44,47,49,52,55,58,61,63,66,69,72,75,77,80,83,86,89,91,94,97,100,103,105,108,111,114,117,119,122,125,128,131,133,136,139,142,146,151,156,161,166,170,175,180,185,190,192,194,196,198,200,202,204,206,208,210,212,214,216,218,220 }, -- C-
    [9] = { 4,6,9,12,14,17,20,22,25,28,31,33,36,39,41,44,47,49,52,55,58,60,63,66,68,71,74,76,79,82,85,87,90,93,95,98,101,103,106,109,112,114,117,120,122,125,128,130,133,136,140,145,150,154,159,164,168,173,178,183,184,186,188,190,192,194,195,197,199,201,203,205,207,208,210 }, -- D
    [10] = { 4,6,9,11,14,16,19,21,24,26,29,31,34,36,39,41,44,46,49,51,54,56,59,61,64,66,69,71,74,76,79,81,84,86,89,91,94,96,99,101,104,106,109,111,114,116,119,121,124,126,130,135,139,144,148,153,157,162,166,171,172,174,176,178,180,182,184,186,188,190,192,194,196,198,200 }, -- E
    [11] = { 4,6,8,10,13,15,17,20,22,24,27,29,31,33,36,38,40,43,45,47,50,52,54,56,59,61,63,66,68,70,73,75,77,79,82,84,86,89,91,93,96,98,100,102,105,107,109,112,114,116,120,124,128,133,137,141,146,150,154,159,161,163,165,167,169,171,173,175,177,179,181,183,185,187,189 }, -- F
}

-- Retail per-rank caps for levels 76..99. CAP_REF only tabulates the
-- HorizonXI 75-cap era (levels 1..75); on servers whose level cap is above
-- 75 we index this table instead of linearly projecting the 74->75 slope.
-- That projection badly under-reports at high level -- e.g. a rank-2 skill
-- (BLM Dark) read 389 at L99 instead of the real 417, and the cur>cap clamp
-- in prepare() then masked it by making the shown cap track current skill+1.
-- Source: BGWiki / LandSandBoat skill_caps (retail curve; continues each
-- CAP_REF row's own column with no discontinuity at the 75/76 boundary).
-- Index = same rank index as CAP_REF; array index = level - 75 (1..24).
local CAP_REF_76 = {
    [0]  = { 281,286,291,296,301,307,313,319,325,331,337,343,349,355,361,368,375,382,389,396,403,410,417,424 }, -- A+
    [1]  = { 274,279,284,289,294,300,306,312,318,324,330,336,342,348,354,361,368,375,382,389,396,403,410,417 }, -- A (HX uses A-)
    [2]  = { 274,279,284,289,294,300,306,312,318,324,330,336,342,348,354,361,368,375,382,389,396,403,410,417 }, -- A-
    [3]  = { 261,266,271,276,281,287,293,299,305,311,317,323,329,335,341,348,355,362,369,376,383,390,397,404 }, -- B+
    [4]  = { 255,260,265,270,275,281,287,293,299,305,311,317,323,329,335,342,349,356,363,370,377,384,391,398 }, -- B
    [5]  = { 245,250,255,260,265,271,277,283,289,295,301,307,313,319,325,332,339,346,353,360,367,374,381,388 }, -- B-
    [6]  = { 235,240,245,250,255,261,267,273,279,285,291,297,303,309,315,322,329,336,343,350,357,364,371,378 }, -- C+
    [7]  = { 230,235,240,245,250,256,262,268,274,280,286,292,298,304,310,317,324,331,338,345,352,359,366,373 }, -- C
    [8]  = { 225,230,235,240,245,251,257,263,269,275,281,287,293,299,305,312,319,326,333,340,347,354,361,368 }, -- C-
    [9]  = { 214,218,222,226,230,235,240,245,250,255,260,265,270,275,280,286,292,298,304,310,316,322,328,334 }, -- D
    [10] = { 203,206,209,212,215,219,223,227,231,235,239,243,247,251,255,260,265,270,275,280,285,290,295,300 }, -- E
    [11] = { 191,193,195,197,199,202,205,208,211,214,217,220,223,226,229,233,237,241,245,249,253,257,261,265 }, -- F
}

-- HorizonXI-calibrated job→skill ranks. Includes combat (1-12), ranged
-- (25-27) and defense (28-31) all in one table — these are the skills
-- the job has main-job access to. Missing entry = skill not granted by
-- this main job (e.g. DRK does not see Polearm/Katana/etc).
-- Source: HorizonXI server data, transcribed from /skill-caps reference.
-- Post-ToAU jobs (BLU/COR/PUP/DNC/SCH/GEO/RUN) are omitted; HX is 75-cap era.
-- HX quirk: NIN Katana & Throwing are A- here (rank 2), not retail's post-2014
-- A+. Verified vs the HorizonXI wiki JobSkills data (both cap 269 @ L75). Do
-- not "correct" these to A+ against a modern retail wiki.
local JOB_SKILL_RANK = {
    [1]  = { [6]=0, [5]=2, [4]=3, [7]=3, [12]=4, [3]=4, [11]=5, [2]=5, [8]=5, [1]=9, [25]=9, [26]=9, [27]=9, [30]=6, [29]=7, [31]=8 },  -- Warrior
    [2]  = { [1]=0, [12]=4, [11]=6, [27]=10, [28]=2, [29]=3, [31]=10 },                                                                  -- Monk
    [3]  = { [11]=3, [12]=6, [27]=10, [30]=9, [29]=10 },                                                                                  -- White Mage
    [4]  = { [12]=5, [11]=6, [2]=9, [7]=10, [27]=9, [29]=10 },                                                                            -- Black Mage
    [5]  = { [2]=4, [3]=4, [11]=9, [25]=9, [27]=11, [29]=9, [31]=10, [30]=11 },                                                           -- Red Mage
    [6]  = { [2]=2, [3]=9, [11]=10, [1]=10, [26]=6, [25]=8, [27]=9, [29]=0, [31]=2, [30]=11 },                                            -- Thief
    [7]  = { [3]=0, [11]=2, [12]=2, [4]=4, [2]=8, [8]=10, [30]=0, [29]=7, [31]=7 },                                                       -- Paladin
    [8]  = { [7]=0, [4]=2, [5]=5, [6]=5, [3]=5, [2]=7, [11]=8, [26]=10, [29]=7, [31]=10 },                                                -- Dark Knight
    [9]  = { [5]=2, [7]=5, [2]=6, [11]=9, [3]=10, [29]=7, [31]=7, [30]=10 },                                                              -- Beastmaster
    [10] = { [2]=5, [12]=6, [3]=8, [11]=9, [27]=10, [29]=9, [31]=10 },                                                                    -- Bard
    [11] = { [5]=5, [2]=5, [3]=9, [11]=10, [25]=2, [26]=2, [27]=8, [29]=10 },                                                             -- Ranger
    [12] = { [10]=0, [8]=5, [3]=6, [11]=10, [2]=10, [25]=6, [27]=6, [31]=2, [29]=3 },                                                     -- Samurai
    [13] = { [9]=2, [2]=6, [3]=7, [10]=8, [11]=10, [1]=10, [27]=2, [26]=7, [25]=10, [29]=2, [31]=2 },                                     -- Ninja
    [14] = { [8]=0, [12]=5, [3]=8, [11]=10, [2]=10, [31]=7, [29]=8 },                                                                     -- Dragoon
    [15] = { [12]=4, [11]=6, [2]=10, [29]=10 },                                                                                            -- Summoner
}

local JOB_MAGIC_SKILL_RANK = {
    -- Casting allowlist: only the magic schools each main job actively casts
    -- spells in. DRK has E-rank Divine/Healing/Enhancing latent in memory
    -- (from sub-job exposure), but doesn't cast them as main job, so they
    -- aren't included here -- otherwise they'd show as noise in the overlay.
    -- HorizonXI is 75-cap era; SCH/BLU/etc. omitted.
    [3]  = { [33]=0, [32]=2, [34]=6, [35]=7 },           -- White Mage: Hea/Div/Enh/Enf
    [4]  = { [36]=0, [37]=2, [35]=6, [34]=10 },          -- Black Mage: Ele/Dark/Enf/Enh
    [5]  = { [35]=0, [34]=3, [36]=6, [33]=8, [37]=10, [32]=10 }, -- Red Mage: Enf/Enh/Ele/Hea/Dark/Div
    [7]  = { [32]=3, [33]=7, [34]=9 },                   -- Paladin: Div/Hea/Enh
    [8]  = { [37]=2, [36]=3, [35]=7 },                   -- Dark Knight: Dark/Ele/Enf
    [10] = { [40]=7, [41]=7, [42]=7 },                     -- Bard: Singing/String/Wind (all C rank)
    [13] = { [39]=2 },                                    -- Ninja: Ninjutsu
    [15] = { [38]=2 },                                    -- Summoner: Summoning
}

local function rank_for_job_skill(job_id, skill_id)
    local row = JOB_SKILL_RANK[job_id]
    return row and row[skill_id]
end

local function rank_for_job_magic_skill(job_id, skill_id)
    local row = JOB_MAGIC_SKILL_RANK[job_id]
    return row and row[skill_id]
end

local function skill_cap_for(rank_idx, level)
    if not rank_idx or not level or level < 1 then return nil end
    local ref = CAP_REF[rank_idx]
    if ref then
        local L = math.floor(level)
        if L < 1 then L = 1 end
        if L <= 75 then
            local v = ref[L]
            if v and v > 0 then return v end
        else
            -- Past level 75 (servers whose cap exceeds the HorizonXI 75 era):
            -- read the tabulated retail 76..99 caps. Linearly projecting the
            -- 74->75 slope badly under-reports (e.g. an A-rank skill would
            -- read 389 at L99 instead of the real 417), so prefer the table.
            local post = CAP_REF_76[rank_idx]
            if post then
                local i = L - 75
                local v = post[i]
                if v and v > 0 then return v end
                -- Beyond the tabulated ceiling: extrapolate the last segment.
                local n = #post
                if n >= 2 and post[n] and post[n - 1] then
                    return post[n] + (post[n] - post[n - 1]) * (i - n)
                end
                if post[n] then return post[n] end
            end
            -- Fallback for any rank lacking a 76+ row: old linear projection.
            local v75 = ref[75]
            local v74 = ref[74]
            if v75 and v74 then
                local end_slope = v75 - v74
                return v75 + end_slope * (L - 75)
            end
            if v75 then return v75 end
        end
    end
    local slope = RANK_SLOPES[rank_idx]
    if not slope then return nil end
    return math.floor(5 + slope * (level - 1) + 0.5)
end

-- Smallest level L at which skill_cap_for(rank, L) >= cur.
-- Searches up to 99 to handle servers with level caps above 75.
local function effective_level_for(rank_idx, cur)
    if not rank_idx or not cur then return nil end
    for L = 1, 99 do
        local c = skill_cap_for(rank_idx, L)
        if c and c >= cur then return L end
    end
    return 99
end

-- Smallest mob level whose rank-curve cap exceeds cur. For combat skills
-- this is the minimum mob level you can still get skillups from. Returns
-- nil at the ceiling.
local function min_mob_level_for(rank_idx, cur)
    if not rank_idx or not cur then return nil end
    for L = 1, 99 do
        local c = skill_cap_for(rank_idx, L)
        if c and c > cur then return L end
    end
    return nil
end

----------------------------------------------------------------
-- player + skill readers
----------------------------------------------------------------

-- Read the skill IDs of the player's currently equipped weapons (main hand
-- and ranged). We show combat-skill rows for weapons that are actually
-- equipped so the overlay stays focused on what you're swinging right now.
-- Returns a list of skill IDs (may be empty, main always first when present).
local function get_equipped_weapon_skill_ids()
    local out = T{}
    pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory()
        for _, slot_idx in ipairs({ 0, 2 }) do  -- 0 = main hand, 2 = ranged
            local eq = inv:GetEquippedItem(slot_idx)
            if eq and eq.Index ~= 0 then
                local container = math.floor(eq.Index / 0x100)
                local slot = eq.Index % 0x100
                local item = inv:GetContainerItem(container, slot)
                if item and item.Id ~= 0 then
                    local res = AshitaCore:GetResourceManager():GetItemById(item.Id)
                    if res and res.Skill and res.Skill ~= 0 then
                        out:append(res.Skill)
                    end
                end
            end
        end
    end)
    return out
end

-- Backwards-compat shim for any callers that still want just the main hand.
local function get_main_weapon_skill_id()
    local sids = get_equipped_weapon_skill_ids()
    return sids[1]
end

-- Is this sid currently equipped as a weapon? Used so prepare() can show
-- a weapon you've sub-equipped even if your main job has no rank for it.
local function is_equipped_weapon_sid(sid)
    if not sid then return false end
    for _, s in ipairs(get_equipped_weapon_skill_ids()) do
        if s == sid then return true end
    end
    return false
end

-- Returns current value, rank index, and engine-reported cap for a combat
-- skill. The engine's cap is authoritative when present (it reflects the
-- exact server-side ranking, which can differ from our static tables).
-- Falls back to nil for fields the API doesn't expose so the caller can
-- compute from CAP_REF.
local function get_combat_skill(sid)
    if not sid then return nil, nil, nil end
    local ok, cur, rank, cap = pcall(function()
        local pl = AshitaCore:GetMemoryManager():GetPlayer()
        local s = pl:GetCombatSkill(sid)
        if not s then return nil, nil, nil end
        local raw_cur  = (type(s.GetSkill) == 'function') and s:GetSkill() or s.Skill
        local raw_rank = (type(s.GetRank)  == 'function') and s:GetRank()  or s.Rank
        local raw_cap  = (type(s.GetCap)   == 'function') and s:GetCap()   or s.Cap
        return raw_cur, raw_rank, raw_cap
    end)
    if ok then return cur, rank, cap end
    return nil, nil, nil
end

-- Returns current value, guild-rank index (0=Amateur..9=Veteran), and a
-- derived cap for a craft skill. Crafts use IPlayer:GetCraftSkill(idx) --
-- a different memory array from combat skills. The craft struct exposes
-- GetSkill / GetRank / IsCapped (no GetCap), so we derive the cap from
-- guild rank: each rank adds 10 to the ceiling (Amateur=10, Recruit=20,
-- ... Veteran=100). Key items can push beyond 100 by +5/+10 per craft;
-- we surface that by trusting IsCapped and clamping cap up to cur if
-- the engine flags us as capped but cur exceeds the rank ceiling.
-- Returns rank as nil downstream (combat-style A+/B-/etc. ranks don't
-- apply to crafts), so the renderer just shows the craft name + numbers.
local function get_craft_skill(sid)
    local idx = CRAFT_SID_TO_IDX[sid]
    if not idx then return nil, nil, nil end
    local ok, cur, grank, capped = pcall(function()
        local pl = AshitaCore:GetMemoryManager():GetPlayer()
        local s = pl:GetCraftSkill(idx)
        if not s then return nil, nil, nil end
        local raw_cur    = (type(s.GetSkill)  == 'function') and s:GetSkill()  or s.Skill
        local raw_rank   = (type(s.GetRank)   == 'function') and s:GetRank()   or s.Rank
        local raw_capped = (type(s.IsCapped)  == 'function') and s:IsCapped()  or s.Capped
        return raw_cur, raw_rank, raw_capped
    end)
    if not ok or not cur then return nil, nil, nil end
    local cap = nil
    if grank and grank >= 0 then
        cap = (grank + 1) * 10
        if cur > cap then cap = cur end           -- key-item raised ceiling
        if capped == true and cur > 0 then        -- engine confirms cap-hit
            cap = math.max(cap, cur)
        end
    end
    return cur, nil, cap
end

-- Fractional skill accumulator: filled by packet 0x29 (authoritative,
-- MessageNum 38=tenths delta, 53=integer tick) AND text_in (chat scrape
-- fallback). Cleared when the integer skill value ticks up.
-- Packet 0x29 path adapted from Jull256/skilluptracker (Mujihina original).
-- Stored in config.skill_frac so progress survives /logout when
-- config.persist_frac is true (default). Helpers below mutate it.
local skill_frac      = config.skill_frac
local _frac_dirty_at  = 0   -- os.clock() of last unsaved frac change; 0 = clean
local FRAC_SAVE_DEBOUNCE = 2.0  -- seconds; persist at most this often

local function frac_get(sid)
    return skill_frac[sid] or 0
end

local function frac_mark_dirty()
    if not config.persist_frac then return end
    -- Debounce disk writes; rapid skillups within FRAC_SAVE_DEBOUNCE coalesce.
    local now = os.clock()
    if _frac_dirty_at == 0 then _frac_dirty_at = now end
    if (now - _frac_dirty_at) >= FRAC_SAVE_DEBOUNCE then
        _frac_dirty_at = 0
        settings.save()
    end
end

local function frac_flush()
    if _frac_dirty_at ~= 0 and config.persist_frac then
        _frac_dirty_at = 0
        settings.save()
    end
end

-- sid -> { delta=number, at=clock } recording the most recent fractional
-- skillup. Renderers draw a floating "+0.X" overlay near each skill while
-- this entry is younger than FRAC_FLASH_LIFETIME, then clear it. Declared
-- before frac_add because frac_add writes to it on each fractional event.
local skill_frac_flash = T{}
local FRAC_FLASH_LIFETIME = 1.8

-- Add tenths/10 to the running fractional. Wraps to 0 on >=1.0 overflow
-- (the integer tick will arrive from memory).
local function frac_add(sid, delta)
    local nv = (skill_frac[sid] or 0) + delta
    if nv >= 1.0 then nv = 0 end
    -- Round to 1 decimal place to keep the persisted Lua table tidy.
    nv = math.floor(nv * 10 + 0.5) / 10
    skill_frac[sid] = nv
    -- Record the delta for the floating "+0.X" flash overlay. Picked up by
    -- renderers below; cleared after FRAC_FLASH_LIFETIME via lazy expire.
    if delta and delta > 0 then
        skill_frac_flash[sid] = { delta = delta, at = os.clock() }
    end
    frac_mark_dirty()
end

local function frac_reset(sid)
    if skill_frac[sid] ~= nil and skill_frac[sid] ~= 0 then
        skill_frac[sid] = 0
        frac_mark_dirty()
    end
end

local _skillup_pkt_at = T{}  -- sid -> os.clock() of last packet write; text_in dedupes

local CHAT_SKILL_NAMES = {
    ['hand-to-hand']=1,['dagger']=2,['sword']=3,['great sword']=4,['axe']=5,
    ['great axe']=6,['scythe']=7,['polearm']=8,['katana']=9,['great katana']=10,
    ['club']=11,['staff']=12,['archery']=25,['marksmanship']=26,['throwing']=27,
    ['guarding']=28, ['guard']=28, ['evasion']=29, ['shield']=30,
    ['parrying']=31, ['parry']=31,
    ['divine magic']=32, ['healing magic']=33, ['enhancing magic']=34,
    ['enfeebling magic']=35, ['elemental magic']=36, ['dark magic']=37,
    ['summoning magic']=38, ['ninjutsu']=39,
    ['singing']=40, ['stringed instrument']=41, ['string instrument']=41,
    ['wind instrument']=42,
    ['fishing']=48, ['woodworking']=49, ['smithing']=50, ['goldsmithing']=51,
    ['clothcraft']=52, ['leathercraft']=53, ['bonecraft']=54,
    ['alchemy']=55, ['cooking']=56,
}

----------------------------------------------------------------
-- animation state shared across renderers
----------------------------------------------------------------
-- sid -> { pct, last } eases displayed fill toward target over ~600ms
local skill_anim = T{}
-- sid -> os.clock() when integer skill last rose; renderers draw an
-- expanding halo while this is < 0.5s old, then clear the entry.
local skill_tick_burst = T{}
-- sid -> last integer skill value seen; used to detect ticks for burst
local skill_int_seen = T{}

-- Frame-rate-independent ease toward target pct. Decay constant 8.0
-- closes ~99% of the gap in 600ms; dt clamped so a stutter doesn't snap.
local function eased_pct(sid, pct)
    pct = math.max(0, math.min(1, pct or 0))
    local now = os.clock()
    local a = skill_anim[sid]
    if not a then
        a = { pct = pct, last = now }
        skill_anim[sid] = a
    else
        local dt = math.max(0, math.min(0.1, now - a.last))
        a.last = now
        local k = 1.0 - math.exp(-8.0 * dt)
        a.pct = a.pct + (pct - a.pct) * k
    end
    return a.pct, now
end

----------------------------------------------------------------
-- draw_frac_flash: floating "+0.X" overlay drawn near a skill when a
-- fractional skillup landed recently. Rises and fades over
-- FRAC_FLASH_LIFETIME seconds. Anchor point is the top-right of the
-- skill's visual cell. Each renderer calls this once per skill per frame.
----------------------------------------------------------------
local function draw_frac_flash(dl, sid, x_right, y_top, now)
    local f = skill_frac_flash[sid]
    if not f then return end
    local age = now - f.at
    if age >= FRAC_FLASH_LIFETIME then
        skill_frac_flash[sid] = nil
        return
    end
    local t = age / FRAC_FLASH_LIFETIME            -- 0..1
    local alpha = 1.0 - t * t                       -- ease-out fade
    local rise  = 14 * t                             -- pixels traveled up
    local txt = string.format('+%.1f', f.delta)
    local tw, th = imgui.CalcTextSize(txt)
    tw = tw or 22; th = th or 12
    local tx = math.floor(x_right - tw)
    local ty = math.floor(y_top - 2 - rise)
    local shadow = imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.85 * alpha })
    local green  = imgui.GetColorU32({ 0.55, 1.0, 0.55, alpha })
    dl:AddText({ tx + 1, ty + 1 }, shadow, txt)
    dl:AddText({ tx,     ty     }, green,  txt)
end

----------------------------------------------------------------
-- draw_arc: filled-quad arc for the donut ring. Each quad extends
-- slightly past its angular bounds so adjacent quads overlap and
-- anti-aliasing seams between them are invisible.
----------------------------------------------------------------
local function draw_arc(dl, cx, cy, r, a0, a1, color, thickness, segs)
    segs = segs or 64
    local span = a1 - a0
    local step = span / segs
    local r_in  = r - thickness * 0.5
    local r_out = r + thickness * 0.5
    local bleed = step * 0.2
    for i = 0, segs - 1 do
        local qa = a0 + step * i - bleed
        local qb = a0 + step * (i + 1) + bleed
        local cos_a, sin_a = math.cos(qa), math.sin(qa)
        local cos_b, sin_b = math.cos(qb), math.sin(qb)
        local p1 = { cx + r_in  * cos_a, cy + r_in  * sin_a }
        local p2 = { cx + r_out * cos_a, cy + r_out * sin_a }
        local p3 = { cx + r_out * cos_b, cy + r_out * sin_b }
        local p4 = { cx + r_in  * cos_b, cy + r_in  * sin_b }
        dl:AddTriangleFilled(p1, p2, p3, color)
        dl:AddTriangleFilled(p1, p3, p4, color)
    end
end

----------------------------------------------------------------
-- layout constants
----------------------------------------------------------------
local SKILL_PILL_WIDTH    = 220
local SKILL_PILL_HEIGHT   = 18

local SKILL_DONUT_RADIUS  = 26
local SKILL_DONUT_THICK   = 6
local SKILL_DONUT_CELL_W  = 78
local SKILL_DONUT_CELL_H  = 115

local SKILL_CRYSTAL_R     = 30        -- half-height
local SKILL_CRYSTAL_W     = 26        -- half-width (slight tall bias)
local SKILL_CRYSTAL_CELL_W = 78
local SKILL_CRYSTAL_CELL_H = 128

----------------------------------------------------------------
-- Geometry caches
--
-- The crystal and donut interiors are drawn as horizontal scanline
-- strips. The span geometry (where each strip starts/ends) is identical
-- every frame for a given scale -- only the colors and the fill height
-- change as a skill animates. Recomputing the hex edge intersections and
-- circle sqrt() for every strip, every skill, every frame was the bulk of
-- the render cost (the crystal view especially: 11 glow shells + body =
-- ~3000 edge tests per crystal). Precompute the strip offsets once per
-- scale and the per-frame work collapses to plain AddRectFilled calls.
----------------------------------------------------------------
local SKILL_CRYSTAL_GLOW_STEPS = 10

local crystal_geo_cache = {}
local function get_crystal_geo(sc)
    local key = ('%.4f'):format(sc)
    local cached = crystal_geo_cache[key]
    if cached then return cached end

    local r        = SKILL_CRYSTAL_R * sc
    local hw       = 18 * sc
    local shoulder = r * 0.62
    -- Hex centered on (0,0) so the spans are pure offsets from the live
    -- crystal center; the renderer just translates by (cx, cy).
    local v = {
        { 0,    -r        },   -- 1: top
        { hw,   -shoulder },    -- 2: upper-right
        { hw,    shoulder },    -- 3: lower-right
        { 0,     r        },   -- 4: bottom
        { -hw,   shoulder },    -- 5: lower-left
        { -hw,  -shoulder },    -- 6: upper-left
    }
    local function edge_x(a, b, yy)
        local dy = b[2] - a[2]
        if math.abs(dy) < 0.01 then return nil end
        local t = (yy - a[2]) / dy
        if t < -0.01 or t > 1.01 then return nil end
        return a[1] + math.max(0, math.min(1, t)) * (b[1] - a[1])
    end
    local function hex_lr(verts, yy)
        local lx = edge_x(verts[1], verts[6], yy) or edge_x(verts[6], verts[5], yy) or edge_x(verts[5], verts[4], yy)
        local rx = edge_x(verts[1], verts[2], yy) or edge_x(verts[2], verts[3], yy) or edge_x(verts[3], verts[4], yy)
        return lx, rx
    end
    local function inflate_hex(pad)
        local iv = {}
        for i = 1, 6 do
            local dx, dy = v[i][1], v[i][2]   -- center is (0,0)
            local d = math.sqrt(dx * dx + dy * dy)
            if d < 0.01 then d = 0.01 end
            iv[i] = { v[i][1] + dx * pad / d, v[i][2] + dy * pad / d }
        end
        return iv
    end

    -- Body scanline spans (1px rows), relative to center.
    local body = {}
    local y_top = math.floor(-r)
    local y_bot = math.ceil(r)
    for y = y_top, y_bot do
        local lx, rx = hex_lr(v, y + 0.5)
        if lx and rx then
            body[#body + 1] = { lx = lx, rx = rx }
        end
    end

    -- Glow shell scanline spans (2px rows), relative to center.
    local glow = {}
    local GLOW_PAD = 12 * sc
    for step = 0, SKILL_CRYSTAL_GLOW_STEPS do
        local t   = step / SKILL_CRYSTAL_GLOW_STEPS
        local pad = GLOW_PAD * (1 - t)
        local gv  = inflate_hex(pad)
        local gy_top = math.floor(gv[1][2])
        local gy_bot = math.ceil(gv[4][2])
        for y = gy_top, gy_bot, 2 do
            local lx, rx = hex_lr(gv, y + 1)
            if lx and rx then
                glow[#glow + 1] = { step = step, y = y, lx = lx, rx = rx }
            end
        end
    end

    cached = { r = r, body = body, glow = glow }
    crystal_geo_cache[key] = cached
    return cached
end

local donut_geo_cache = {}
local function get_donut_geo(sc)
    local key = ('%.4f'):format(sc)
    local cached = donut_geo_cache[key]
    if cached then return cached end

    local r     = SKILL_DONUT_RADIUS * sc
    local thick = SKILL_DONUT_THICK * sc
    local r_out = r + thick * 0.5
    local r_in  = r - thick * 0.5
    -- Trough uses slightly smaller radii so the outline covers it; fill
    -- uses slightly larger radii so the outline sits cleanly on top.
    local r_out_t = r_out - 0.5
    local r_in_t  = r_in + 0.5
    local r_out_f = r_out + 1
    local r_in_f  = math.max(0, r_in - 1)

    local rows = {}
    local y_top = math.floor(-r_out)
    local y_bot = math.ceil(r_out)
    for y = y_top, y_bot do
        local dy  = y + 0.5
        local dy2 = dy * dy
        if dy2 < r_out_f * r_out_f then
            rows[#rows + 1] = {
                dy   = dy,
                -- fill-mode spans
                xo   = math.sqrt(r_out_f * r_out_f - dy2),
                xi   = (dy2 < r_in_f * r_in_f) and math.sqrt(r_in_f * r_in_f - dy2) or 0,
                xo_t = (dy2 < r_out_t * r_out_t) and math.sqrt(r_out_t * r_out_t - dy2) or 0,
                xi_t = (dy2 < r_in_t * r_in_t) and math.sqrt(r_in_t * r_in_t - dy2) or 0,
                -- trough-only spans (nil outer = row outside the trough ring)
                t_xo = (dy2 < r_out_t * r_out_t) and math.sqrt(r_out_t * r_out_t - dy2) or nil,
                t_xi = (dy2 < r_in_t * r_in_t) and math.sqrt(r_in_t * r_in_t - dy2) or 0,
            }
        end
    end

    cached = { r_out = r_out, rows = rows }
    donut_geo_cache[key] = cached
    return cached
end

----------------------------------------------------------------
-- Crystal color is by RANK TIER (MMO-rarity vibe), not family.
--   A+/A/A-  -> gold
--   B+/B/B-  -> green
--   C+/C/C-  -> cyan
--   D        -> light blue
--   E/F/G    -> grey
----------------------------------------------------------------
local TIER_COLOR = {
    [0]  = { 1.00, 0.85, 0.25, 1.0 },   -- A+
    [1]  = { 1.00, 0.85, 0.25, 1.0 },   -- A
    [2]  = { 1.00, 0.85, 0.25, 1.0 },   -- A-
    [3]  = { 0.45, 0.95, 0.50, 1.0 },   -- B+
    [4]  = { 0.45, 0.95, 0.50, 1.0 },   -- B
    [5]  = { 0.45, 0.95, 0.50, 1.0 },   -- B-
    [6]  = { 0.45, 0.88, 0.98, 1.0 },   -- C+
    [7]  = { 0.45, 0.88, 0.98, 1.0 },   -- C
    [8]  = { 0.45, 0.88, 0.98, 1.0 },   -- C-
    [9]  = { 0.50, 0.70, 1.00, 1.0 },   -- D
    [10] = { 0.62, 0.65, 0.72, 1.0 },   -- E
    [11] = { 0.62, 0.65, 0.72, 1.0 },   -- F
    [12] = { 0.62, 0.65, 0.72, 1.0 },   -- G
}
local function tier_color_for(rank_idx)
    return TIER_COLOR[rank_idx] or { 0.70, 0.74, 0.80, 1.0 }
end

----------------------------------------------------------------
-- skill_pill: horizontal glass pill with eased fill, near-cap glow,
-- and a tick burst. Label is the whole "Name  cur/cap (rank) Lv N+"
-- string -- centered inside the pill.
----------------------------------------------------------------
local function skill_pill(sid, pct, color, label, forced_width, letter, pill_badge_w)
    local draw_pct, now = eased_pct(sid, pct)
    local sc = config.scale or 1.0
    local height = math.floor(14 * sc)
    if height < 12 then height = 12 end
    local width
    if forced_width then
        width = forced_width
    else
        width = math.floor(SKILL_PILL_WIDTH * sc)
        if label and label ~= '' then
            local tw0 = imgui.CalcTextSize(label) or 0
            local min_w = math.floor(tw0 + 16)
            if width < min_w then width = min_w end
        end
    end

    local pbw = pill_badge_w or 0

    local x0, y0 = imgui.GetCursorScreenPos()
    local bar_x = x0 + pbw
    local bar_w = width - pbw
    local dl = imgui.GetWindowDrawList()
    local rounding = math.floor(height * 0.5)

    -- Tick burst.
    local burst_t = skill_tick_burst[sid]
    if burst_t then
        local bdt = now - burst_t
        if bdt < 0.5 then
            local bt = bdt / 0.5
            local bc = imgui.GetColorU32({ color[1], color[2], color[3], (1 - bt) * 0.7 })
            dl:AddRect({ bar_x - 2, y0 - 2 },
                       { bar_x + bar_w + 2, y0 + height + 2 }, bc, rounding + 2, 15, 1.5)
        else
            skill_tick_burst[sid] = nil
        end
    end

    -- Trough.
    local bg_col = imgui.GetColorU32({ 0.05, 0.05, 0.08, 0.88 })
    dl:AddRectFilled({ bar_x, y0 }, { bar_x + bar_w, y0 + height }, bg_col, rounding, 15)

    -- Colored fill.
    if draw_pct > 0.0 then
        local cr, cg, cb = color[1], color[2], color[3]
        local ca = color[4] or 1.0
        local fx2 = bar_x + bar_w * draw_pct
        dl:AddRectFilled({ bar_x, y0 }, { fx2, y0 + height },
                         imgui.GetColorU32({ cr, cg, cb, ca }), rounding, 15)
        local light = imgui.GetColorU32({
            math.min(1, cr + 0.15),
            math.min(1, cg + 0.15),
            math.min(1, cb + 0.15), 0.25 })
        dl:AddRectFilled({ bar_x, y0 }, { fx2, y0 + math.floor(height * 0.5) },
                         light, rounding, 3)
    end

    -- Rank-colored outline.
    local ol = imgui.GetColorU32({ color[1], color[2], color[3], 0.85 })
    dl:AddRect({ bar_x, y0 }, { bar_x + bar_w, y0 + height }, ol, rounding, 15, 1.2)

    -- Text label centered in bar.
    if label and label ~= '' then
        local tw, th = imgui.CalcTextSize(label)
        tw = tw or 0; th = th or 0
        local tx = bar_x + (bar_w - tw) * 0.5
        local ty = y0 + (height - th) * 0.5
        local shadow = imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.85 })
        local white  = imgui.GetColorU32({ 1.0, 1.0, 1.0, 1.0 })
        dl:AddText({ tx + 1, ty + 1 }, shadow, label)
        dl:AddText({ tx,     ty     }, white,  label)
    end

    -- Rank pill badge on the left (fixed width from pill_badge_w, matches bar height).
    if letter and letter ~= '' and pbw > 0 then
        local lw, lh = imgui.CalcTextSize(letter)
        lw = lw or 0; lh = lh or 10
        local gap = math.floor(3 * sc)
        local pw = pbw - gap
        local ph = height
        local px = x0
        local py = y0
        local pillbg = imgui.GetColorU32({ 0.07, 0.08, 0.11, 0.95 })
        local pillb  = imgui.GetColorU32({ color[1], color[2], color[3], 0.95 })
        dl:AddRectFilled({ px, py }, { px + pw, py + ph }, pillbg, 3, 15)
        dl:AddRect({ px, py }, { px + pw, py + ph }, pillb, 3, 15, 1.2)
        local pill_shadow = imgui.GetColorU32({ 0, 0, 0, 0.85 })
        local txtcol = imgui.GetColorU32({ 0.95, 0.97, 1.0, 1.0 })
        local ltx = px + (pw - lw) * 0.5
        local lty = py + (ph - lh) * 0.5
        dl:AddText({ ltx + 1, lty + 1 }, pill_shadow, letter)
        dl:AddText({ ltx,     lty     }, txtcol, letter)
    end

    imgui.Dummy({ width, height })

    -- Floating "+0.X" overlay (drawn last so it sits on top of everything).
    draw_frac_flash(dl, sid, x0 + width, y0, now)
end

----------------------------------------------------------------
-- skill_donut: radial gauge with OSRS-style interior.
--   - thick rank-colored arc fills clockwise from 12 o'clock
--   - small dim rank letter near the top
--   - big bright effective level number centered
--   - caption: skill name / cur/cap / "Lv N+" or "cast" hint
----------------------------------------------------------------
local function skill_donut(sid, pct, color, label, cur_str, cap_str, letter, eff_lvl, min_mob_lvl, is_cast_gated)
    local draw_pct, now = eased_pct(sid, pct)

    local x0, y0 = imgui.GetCursorScreenPos()
    local sc     = config.scale or 1.0
    local r      = SKILL_DONUT_RADIUS * sc
    local thick  = SKILL_DONUT_THICK * sc
    local r_out  = r + thick * 0.5
    local r_in   = r - thick * 0.5
    local top_pad = math.ceil(thick * 0.5) + 29
    local cw     = math.max(SKILL_DONUT_CELL_W * sc, 2 * r_out + 16)
    local text_block_h = 62
    local ch     = top_pad + 2 * r_out + 4 + text_block_h
    local cx     = x0 + cw * 0.5
    local cy     = y0 + r_out + top_pad
    local dl     = imgui.GetWindowDrawList()

    -- Tick burst behind the donut.
    local burst_t = skill_tick_burst[sid]
    if burst_t then
        local bdt = now - burst_t
        if bdt < 0.5 then
            local s = 1 - bdt / 0.5
            local bc = imgui.GetColorU32({ color[1], color[2], color[3], 0.7 * s })
            local bpad = bdt * 14
            dl:AddCircle({ cx, cy }, r_out + bpad, bc, 48, 1.5)
        else
            skill_tick_burst[sid] = nil
        end
    end

    -- Donut ring: scanline strips for both trough and fill (guaranteed
    -- gap-free, same technique as the crystal renderer). AA circles on
    -- outer/inner edges smooth the curve stairstepping.
    local TWO_PI    = math.pi * 2
    local a0        = -math.pi * 0.5
    local fill_span = TWO_PI * draw_pct
    local has_fill  = draw_pct > 0.005
    local a1        = a0 + fill_span

    local trough_col = imgui.GetColorU32({ 0.08, 0.08, 0.10, 0.95 })
    local fc         = imgui.GetColorU32({ color[1], color[2], color[3], 0.98 })

    local function is_filled(theta)
        local diff = (theta - a0) % TWO_PI
        return diff <= fill_span
    end
    local function boundary_x(a, dy)
        local sa = math.sin(a)
        if math.abs(sa) < 0.001 then return nil end
        local t = dy / sa
        if t < 0 then return nil end
        return cx + t * math.cos(a)
    end

    local geo    = get_donut_geo(sc)
    local rows   = geo.rows
    local base_y = math.floor(cy - r_out)

    for i = 1, #rows do
        local row = rows[i]
        local y   = base_y + (i - 1)
        local dy  = row.dy

        if not has_fill then
            if row.t_xo then
                local xo = row.t_xo
                local xi = row.t_xi
                if xi > 0.5 then
                    dl:AddRectFilled({ cx - xo, y }, { cx - xi, y + 1 }, trough_col)
                    dl:AddRectFilled({ cx + xi, y }, { cx + xo, y + 1 }, trough_col)
                else
                    dl:AddRectFilled({ cx - xo, y }, { cx + xo, y + 1 }, trough_col)
                end
            end
        else
            local xo, xi     = row.xo, row.xi
            local xo_t, xi_t = row.xo_t, row.xi_t

            local strips
            if xi > 0.5 then
                strips = { { cx - xo, cx - xi }, { cx + xi, cx + xo } }
            else
                strips = { { cx - xo, cx + xo } }
            end

            local bx0 = boundary_x(a0, dy)
            local bx1 = boundary_x(a1, dy)

            for _, s in ipairs(strips) do
                local sl, sr = s[1], s[2]
                local cuts = { sl }
                if bx0 and bx0 > sl + 0.5 and bx0 < sr - 0.5 then cuts[#cuts + 1] = bx0 end
                if bx1 and bx1 ~= bx0 and bx1 > sl + 0.5 and bx1 < sr - 0.5 then cuts[#cuts + 1] = bx1 end
                cuts[#cuts + 1] = sr
                table.sort(cuts)

                for ci = 1, #cuts - 1 do
                    local cl, cr = cuts[ci], cuts[ci + 1]
                    if cr - cl > 0.1 then
                        local mx = (cl + cr) * 0.5
                        local theta = math.atan2(dy, mx - cx)
                        if is_filled(theta) then
                            dl:AddRectFilled({ cl, y }, { cr, y + 1 }, fc)
                        else
                            local tl = math.max(cl, cx - xo_t)
                            local tr = math.min(cr, cx + xo_t)
                            if xi_t > 0.5 then
                                if tl < cx - xi_t then
                                    dl:AddRectFilled({ tl, y }, { math.min(tr, cx - xi_t), y + 1 }, trough_col)
                                end
                                if tr > cx + xi_t then
                                    dl:AddRectFilled({ math.max(tl, cx + xi_t), y }, { tr, y + 1 }, trough_col)
                                end
                            elseif tr > tl then
                                dl:AddRectFilled({ tl, y }, { tr, y + 1 }, trough_col)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Tier-colored outlines on outer/inner edges. These AA circles cover
    -- the scanline stairstepping on both the trough and fill, giving the
    -- donut clean smooth edges.
    local outline_col = imgui.GetColorU32({ color[1], color[2], color[3], 0.90 })
    dl:AddCircle({ cx, cy }, r_out, outline_col, 64, 1.5)
    dl:AddCircle({ cx, cy }, r_in,  outline_col, 64, 1.5)


    local shadow = imgui.GetColorU32({ 0, 0, 0, 0.85 })
    local white  = imgui.GetColorU32({ 1, 1, 1, 1.0 })
    local dim    = imgui.GetColorU32({ 0.65, 0.68, 0.74, 1.0 })

    -- Rank pill badge at the top of the donut (same style as crystals).
    if letter and letter ~= '' then
        local lw, lh = imgui.CalcTextSize(letter)
        lw = lw or 0; lh = lh or 10
        local pw, ph = math.floor((lw + 12) * sc), math.floor((lh + 4) * sc)
        local px = cx - pw * 0.5
        local py = (cy - r_out) - ph * 0.5 - 15
        local pillbg = imgui.GetColorU32({ 0.07, 0.08, 0.11, 0.95 })
        local pillb  = imgui.GetColorU32({ color[1], color[2], color[3], 0.95 })
        dl:AddRectFilled({ px, py }, { px + pw, py + ph }, pillbg, math.floor(3 * sc), 15)
        dl:AddRect({ px, py }, { px + pw, py + ph }, pillb, math.floor(3 * sc), 15, 1.6)
        local txtcol = imgui.GetColorU32({ 0.95, 0.97, 1.0, 1.0 })
        local tx = px + (pw - lw) * 0.5
        local ty = py + (ph - lh) * 0.5
        dl:AddText({ tx + 1, ty + 1 }, shadow, letter)
        dl:AddText({ tx,     ty     }, txtcol, letter)
    end

    -- Big effective level number centered.
    if eff_lvl then
        local s = tostring(eff_lvl)
        local nw, nh = imgui.CalcTextSize(s)
        nw = nw or 0; nh = nh or 12
        local nx = cx - nw * 0.5
        local ny = cy - nh * 0.5 + 2
        dl:AddText({ nx + 1, ny + 1 }, shadow, s)
        dl:AddText({ nx,     ny     }, white,  s)
    end

    -- Caption: name, cur/cap, hint.
    local cap_y = cy + r + 14
    if label then
        local maxw = cw - 4
        local lstr = label
        local lw   = imgui.CalcTextSize(lstr) or 0
        while lw > maxw and #lstr > 1 do
            lstr = lstr:sub(1, -2)
            lw   = imgui.CalcTextSize(lstr) or 0
        end
        local lh
        lw, lh = imgui.CalcTextSize(lstr)
        lw = lw or 0; lh = lh or 12
        local lx = x0 + (cw - lw) * 0.5
        dl:AddText({ lx + 1, cap_y + 1 }, shadow, lstr)
        dl:AddText({ lx,     cap_y     }, white,  lstr)
        cap_y = cap_y + lh + 1
    end
    if cur_str then
        local sub = cap_str and (cur_str .. '/' .. cap_str) or cur_str
        local sw, sh = imgui.CalcTextSize(sub)
        sw = sw or 0; sh = sh or 12
        local sx = x0 + (cw - sw) * 0.5
        dl:AddText({ sx + 1, cap_y + 1 }, shadow, sub)
        dl:AddText({ sx,     cap_y     }, dim,    sub)
        cap_y = cap_y + sh + 1
    end
    local hint
    if is_cast_gated then
        hint = 'cast'
    elseif min_mob_lvl then
        hint = ('Lv %d+'):format(min_mob_lvl)
    end
    if hint then
        local hw, hh = imgui.CalcTextSize(hint)
        hw = hw or 0; hh = hh or 12
        local hx = x0 + (cw - hw) * 0.5
        local accent
        if is_cast_gated then
            accent = imgui.GetColorU32({ 0.55, 0.70, 0.95, 0.95 })
        else
            accent = imgui.GetColorU32({ 0.95, 0.82, 0.45, 0.95 })
        end
        dl:AddText({ hx + 1, cap_y + 1 }, shadow, hint)
        dl:AddText({ hx,     cap_y     }, accent, hint)
    end

    imgui.Dummy({ cw, ch })

    -- Floating "+0.X" overlay anchored near the top-right of the donut.
    draw_frac_flash(dl, sid, cx + r_out + 6, cy - r_out - 6, now)
end

----------------------------------------------------------------
-- skill_crystal: FF-style tall hexagonal crystal. Scanline-rendered
-- interior (no triangle fans, no ghost lines, no clipping artifacts).
--   - Colored glow halo + soft backlight in tier color
--   - Dark crystal body filled by scanline strips
--   - Gradient fill rises from bottom (bright/white base → tier color)
--   - Facet lines, highlight stripe, sparkles (all AddLine-safe)
--   - Colored outline, rank pill on top, caption below
----------------------------------------------------------------
local function skill_crystal(sid, pct, color, label, cur_str, cap_str, letter, eff_lvl, min_mob_lvl, is_cast_gated)
    local draw_pct, now = eased_pct(sid, pct)

    local x0, y0 = imgui.GetCursorScreenPos()
    local sc     = config.scale or 1.0
    local r      = SKILL_CRYSTAL_R * sc
    local hw     = 18 * sc
    local cw     = math.max(SKILL_CRYSTAL_CELL_W * sc, hw * 2 + 16)
    local text_block_h = 62
    local top_pad = 34
    local ch     = top_pad + 2 * r + 6 + text_block_h
    local cx     = x0 + cw * 0.5
    local cy     = y0 + r + top_pad
    local dl     = imgui.GetWindowDrawList()

    local shoulder = r * 0.62
    local v = {
        { cx,      cy - r        },   -- 1: top
        { cx + hw, cy - shoulder },    -- 2: upper-right
        { cx + hw, cy + shoulder },    -- 3: lower-right
        { cx,      cy + r        },   -- 4: bottom
        { cx - hw, cy + shoulder },    -- 5: lower-left
        { cx - hw, cy - shoulder },    -- 6: upper-left
    }

    -- Static scanline geometry (glow shells + body spans) for this scale.
    local geo = get_crystal_geo(sc)

    -- Tick burst: expanding hex outline fading over 500ms.
    local burst_t = skill_tick_burst[sid]
    if burst_t then
        local bdt = now - burst_t
        if bdt < 0.5 then
            local s   = 1 - bdt / 0.5
            local bc  = imgui.GetColorU32({ color[1], color[2], color[3], 0.7 * s })
            local pad = bdt * 12
            for i = 1, 6 do
                local a = v[i]
                local b = v[(i % 6) + 1]
                local ax = a[1] + (a[1] - cx) * (pad / r)
                local ay = a[2] + (a[2] - cy) * (pad / r)
                local bx = b[1] + (b[1] - cx) * (pad / r)
                local by = b[2] + (b[2] - cy) * (pad / r)
                dl:AddLine({ ax, ay }, { bx, by }, bc, 1.5)
            end
        else
            skill_tick_burst[sid] = nil
        end
    end

    -- Hex-shaped gradient glow: many concentric inflated hex shells drawn
    -- outer-to-inner with smoothly increasing alpha, creating a seamless
    -- gradient that follows the crystal shape. Shell spans are precomputed
    -- (see get_crystal_geo); only the per-tier colors are built here.
    local GLOW_STEPS = SKILL_CRYSTAL_GLOW_STEPS
    local glow_colors = {}
    for step = 0, GLOW_STEPS do
        local t = step / GLOW_STEPS
        local alpha = 0.03 + t * 0.15
        glow_colors[step] = imgui.GetColorU32({ color[1], color[2], color[3], alpha })
    end
    local gspans = geo.glow
    for i = 1, #gspans do
        local g = gspans[i]
        dl:AddRectFilled({ cx + g.lx, cy + g.y }, { cx + g.rx, cy + g.y + 2 }, glow_colors[g.step])
    end

    -- Crystal body: trough + fill rendered as horizontal scanline strips.
    -- Each strip is a single AddRectFilled — zero triangle fans, zero
    -- ghost lines, zero clipping math. Spans are precomputed per scale.
    local body   = geo.body
    local nrows  = #body
    local y_top  = math.floor(cy - r)
    local y_bot  = y_top + (nrows - 1)
    local trough_col = imgui.GetColorU32({ 0.06, 0.07, 0.10, 1.0 })

    -- Precompute fill gradient bands (bright/white at bottom → tier color
    -- at top of fill, like light gathering inside the crystal).
    local fill_y = (draw_pct > 0.005) and (cy + r - (2 * r) * draw_pct) or (y_bot + 1)
    local fill_top_y = math.max(y_top, math.floor(fill_y))
    local fill_range = math.max(1, y_bot - fill_top_y)
    local NUM_BANDS = 12
    local bands = {}
    if draw_pct > 0.005 then
        for b = 0, NUM_BANDS do
            local t = b / NUM_BANDS
            local wb = (1 - t) * 0.45
            bands[b] = imgui.GetColorU32({
                math.min(1, color[1] + (1 - color[1]) * wb),
                math.min(1, color[2] + (1 - color[2]) * wb),
                math.min(1, color[3] + (1 - color[3]) * wb), 1.0 })
        end
    end

    for i = 1, nrows do
        local e  = body[i]
        local y  = y_top + (i - 1)
        local lx = cx + e.lx
        local rx = cx + e.rx
        if y >= fill_top_y and draw_pct > 0.005 then
            local progress = math.max(0, math.min(1, (y_bot - y) / fill_range))
            local bi = math.min(NUM_BANDS, math.floor(progress * NUM_BANDS + 0.5))
            dl:AddRectFilled({ lx, y }, { rx, y + 1 }, bands[bi])
        else
            dl:AddRectFilled({ lx, y }, { rx, y + 1 }, trough_col)
        end
    end

    -- Near-cap outer glow (last 10% of fill).
    if draw_pct > 0.9 then
        local t = (draw_pct - 0.9) * 10
        local nc = imgui.GetColorU32({ color[1], color[2], color[3], t * 0.45 })
        for i = 1, 6 do
            local a, b = v[i], v[(i % 6) + 1]
            local ax = a[1] + (a[1] - cx) * (3 / r)
            local ay = a[2] + (a[2] - cy) * (3 / r)
            local bx = b[1] + (b[1] - cx) * (3 / r)
            local by = b[2] + (b[2] - cy) * (3 / r)
            dl:AddLine({ ax, ay }, { bx, by }, nc, 2 * sc)
        end
    end

    -- Facet lines (AddLine only — always artifact-free). Dual pass:
    -- light for dark areas, dark for bright areas.
    local facet_light = imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.14 })
    local facet_dark  = imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.18 })
    local facets = { { v[1], v[3] }, { v[1], v[5] }, { v[4], v[2] }, { v[4], v[6] },
                     { { cx, cy - r }, { cx, cy + r } } }
    for _, f in ipairs(facets) do
        dl:AddLine(f[1], f[2], facet_light, 1.0)
        dl:AddLine(f[1], f[2], facet_dark, 1.0)
    end

    -- Colored outline.
    local outline = imgui.GetColorU32({ color[1], color[2], color[3], 0.95 })
    for i = 1, 6 do
        dl:AddLine(v[i], v[(i % 6) + 1], outline, 2.0)
    end

    -- Highlight stripe on upper-left face + softer echo on upper-right.
    local hi_strong = imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.30 })
    local hi_soft   = imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.12 })
    dl:AddLine(
        { v[1][1] + (v[6][1] - v[1][1]) * 0.18, v[1][2] + (v[6][2] - v[1][2]) * 0.18 },
        { v[1][1] + (v[6][1] - v[1][1]) * 0.85, v[1][2] + (v[6][2] - v[1][2]) * 0.85 },
        hi_strong, 1.5)
    dl:AddLine(
        { v[1][1] + (v[2][1] - v[1][1]) * 0.25, v[1][2] + (v[2][2] - v[1][2]) * 0.25 },
        { v[1][1] + (v[2][1] - v[1][1]) * 0.75, v[1][2] + (v[2][2] - v[1][2]) * 0.75 },
        hi_soft, 1.0)

    -- Sparkle accents.
    local spark = imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.60 })
    dl:AddCircleFilled({ cx - hw * 0.30, cy - r * 0.55 }, 1.4 * sc, spark)
    dl:AddCircleFilled({ cx + hw * 0.40, cy - r * 0.20 }, 1.0 * sc, spark)

    -- Rank pill drawn last (on top of everything).
    if letter and letter ~= '' then
        local lw, lh = imgui.CalcTextSize(letter)
        lw = lw or 0; lh = lh or 10
        local pw, ph = math.floor((lw + 12) * sc), math.floor((lh + 4) * sc)
        local px = cx - pw * 0.5
        local py = (cy - r) - ph * 0.5 - 10
        local pillbg = imgui.GetColorU32({ 0.07, 0.08, 0.11, 0.95 })
        local pillb  = imgui.GetColorU32({ color[1], color[2], color[3], 0.95 })
        dl:AddRectFilled({ px, py }, { px + pw, py + ph }, pillbg, math.floor(3 * sc), 15)
        dl:AddRect({ px, py }, { px + pw, py + ph }, pillb, math.floor(3 * sc), 15, 1.6)
        local pill_shadow = imgui.GetColorU32({ 0, 0, 0, 0.85 })
        local txtcol = imgui.GetColorU32({ 0.95, 0.97, 1.0, 1.0 })
        local tx = px + (pw - lw) * 0.5
        local ty = py + (ph - lh) * 0.5
        dl:AddText({ tx + 1, ty + 1 }, pill_shadow, letter)
        dl:AddText({ tx,     ty     }, txtcol, letter)
    end

    local shadow = imgui.GetColorU32({ 0, 0, 0, 0.85 })
    local white  = imgui.GetColorU32({ 1, 1, 1, 1.0 })
    local dim    = imgui.GetColorU32({ 0.70, 0.74, 0.80, 1.0 })

    -- Effective level centered inside the crystal.
    if eff_lvl then
        local s = tostring(eff_lvl)
        local nw, nh = imgui.CalcTextSize(s)
        nw = nw or 0; nh = nh or 12
        local nx = cx - nw * 0.5
        local ny = cy - nh * 0.5
        dl:AddText({ nx + 1, ny + 1 }, shadow, s)
        dl:AddText({ nx,     ny     }, white,  s)
    end

    -- Caption: name / cur/cap / hint, below the crystal.
    local cap_yt = cy + r + 9
    if label then
        local maxw = cw - 4
        local lstr = label
        local lw   = imgui.CalcTextSize(lstr) or 0
        while lw > maxw and #lstr > 1 do
            lstr = lstr:sub(1, -2)
            lw   = imgui.CalcTextSize(lstr) or 0
        end
        local lh
        lw, lh = imgui.CalcTextSize(lstr)
        lw = lw or 0; lh = lh or 12
        local lx = x0 + (cw - lw) * 0.5
        dl:AddText({ lx + 1, cap_yt + 1 }, shadow, lstr)
        dl:AddText({ lx,     cap_yt     }, white,  lstr)
        cap_yt = cap_yt + lh + 1
    end
    if cur_str then
        local sub = cap_str and (cur_str .. '/' .. cap_str) or cur_str
        local sw, sh = imgui.CalcTextSize(sub)
        sw = sw or 0; sh = sh or 12
        local sx = x0 + (cw - sw) * 0.5
        dl:AddText({ sx + 1, cap_yt + 1 }, shadow, sub)
        dl:AddText({ sx,     cap_yt     }, dim,    sub)
        cap_yt = cap_yt + sh + 1
    end
    local hint
    if is_cast_gated then hint = 'cast'
    elseif min_mob_lvl then hint = ('Lv %d+'):format(min_mob_lvl) end
    if hint then
        local hw2, hh = imgui.CalcTextSize(hint)
        hw2 = hw2 or 0; hh = hh or 12
        local hx = x0 + (cw - hw2) * 0.5
        local accent = is_cast_gated
            and imgui.GetColorU32({ 0.55, 0.70, 0.95, 0.95 })
            or  imgui.GetColorU32({ 0.95, 0.82, 0.45, 0.95 })
        dl:AddText({ hx + 1, cap_yt + 1 }, shadow, hint)
        dl:AddText({ hx,     cap_yt     }, accent, hint)
    end

    imgui.Dummy({ cw, ch })

    -- Floating "+0.X" overlay anchored near the top-right of the crystal.
    draw_frac_flash(dl, sid, cx + hw + 6, cy - r - 6, now)
end

----------------------------------------------------------------
-- prepare: build a renderable item table for one skill, or return nil
-- if the skill shouldn't be shown for this job/category (no rank, not
-- yet trained for crafts, already at cap with show_capped off, etc.).
----------------------------------------------------------------
local function prepare(sid, category, job_id, mjl)
    if not sid then return nil end
    local cur, rank, engine_cap
    if category == 'craft' then
        cur, rank, engine_cap = get_craft_skill(sid)
    else
        cur, rank, engine_cap = get_combat_skill(sid)
    end
    if not cur then return nil end

    -- Detect integer-tick rises for the burst halo + reset fractional.
    local last = skill_int_seen[sid]
    if last and cur > last then
        skill_tick_burst[sid] = os.clock()
        frac_reset(sid)
    end
    skill_int_seen[sid] = cur

    -- Per-category eligibility:
    --   combat/defense: must be in JOB_SKILL_RANK[job] (main-job allowlist)
    --                   OR equipped (e.g. a weapon you can use via sub-job).
    --   magic:          must be in JOB_MAGIC_SKILL_RANK[job] (cast allowlist).
    --   craft:          no rank tables exist; show only when trained
    --                   (cur>0 OR frac>0) and rely on the engine cap.
    local fallback_rank
    if category == 'magic' then
        fallback_rank = rank_for_job_magic_skill(job_id, sid)
        if not fallback_rank then return nil end
    elseif category == 'craft' then
        if cur <= 0 and frac_get(sid) <= 0 then return nil end
        -- rank stays nil for crafts; cap comes from engine.
    else
        -- combat or defense
        fallback_rank = rank_for_job_skill(job_id, sid)
        if not fallback_rank then
            -- Allow equipped combat weapons even if the job has no rank.
            if category == 'combat' and is_equipped_weapon_sid(sid) then
                -- leave rank nil; cap from engine if available
            else
                return nil
            end
        end
    end
    -- HX-calibrated tables are authoritative. The engine's GetRank() can
    -- return retail-canonical ranks that differ from HorizonXI (e.g. DRK
    -- GAxe is B- on HX but the engine may report B+), so prefer the table
    -- rank whenever we have one. Fall back to engine rank only for skills
    -- the table doesn't cover (e.g. an equipped off-job weapon).
    rank = fallback_rank or rank

    -- Prefer the engine-reported cap when it's a sane positive value -- it
    -- matches what FFXI shows in /checkparam and avoids drift from our
    -- static tables when a server (e.g. HorizonXI) ranks a skill differently
    -- than retail canonical.
    local using_engine_cap = (engine_cap and engine_cap > 0)
    local cap = using_engine_cap and engine_cap or skill_cap_for(rank, mjl)

    -- If we're using the fallback table cap and the skill already exceeds it,
    -- the table is likely outdated (merit points, server-specific adjustments,
    -- or level > 75 extrapolation inaccuracy). Bump cap up so we don't
    -- falsely flag the skill as capped.
    if cap and not using_engine_cap and cur > cap then
        cap = cur + 1
    end

    local letter  = RANK_LETTERS[rank]
    if cap and cur >= cap and not config.show_capped then return nil end

    -- Display value: integer from memory + any fractional points we've
    -- seen accumulate from chat since the last integer tick. Clamp the
    -- frac at 0.9 — if it ever reaches 1.0 the integer should have ticked.
    local frac    = math.min(0.9, frac_get(sid))
    local cur_eff = cur + frac

    local color   = tier_color_for(rank)
    local cur_str = (frac > 0) and string.format('%.1f', cur_eff) or tostring(cur)
    local label   = SKILL_NAMES[sid] or ('Skill#'..sid)
    local eff_lvl = effective_level_for(rank, cur)
    local eff_str = eff_lvl and (' L%d'):format(eff_lvl) or ''

    -- Defense and craft don't have meaningful "what mob can give skillups"
    -- math, so suppress those hints — they apply to combat/magic only.
    local is_cast_gated = SKILL_IS_CAST_GATED[sid] == true
    local min_mob_lvl   = nil
    if (category == 'combat' or category == 'magic')
       and not is_cast_gated and cap and cur < cap then
        min_mob_lvl = min_mob_level_for(rank, cur)
    end

    local pct = (cap and cap > 0) and math.max(0, math.min(1, cur_eff / cap)) or 0
    return {
        sid           = sid,
        category      = category,
        rank          = rank,
        cur           = cur_eff,
        pct           = pct,
        color         = color,
        label         = label,
        cur_str       = cur_str,
        cap           = cap,
        letter        = letter,
        eff_lvl       = eff_lvl,
        eff_str       = eff_str,
        min_mob_lvl   = min_mob_lvl,
        is_cast_gated = is_cast_gated,
    }
end

----------------------------------------------------------------
-- frame: build items list, then render per current display_mode
-- and per_row layout.
----------------------------------------------------------------
local function build_pill_label(item)
    local hint = ''
    if item.cap then
        if item.is_cast_gated then
            hint = '  cast'
        elseif item.min_mob_lvl then
            hint = ('  Lv %d+'):format(item.min_mob_lvl)
        end
    end
    if item.cap then
        return ('%s  %s/%d%s%s'):format(
            item.label, item.cur_str, item.cap, item.eff_str, hint)
    else
        return ('%s  %s'):format(item.label, item.cur_str)
    end
end

local function render_pill_line(item, forced_width, pill_badge_w)
    local line = build_pill_label(item)
    skill_pill(item.sid, item.pct, item.color, line, forced_width, item.letter, pill_badge_w)
end

local last_item_count = 6

local function draw_frame()
    local pl
    pcall(function() pl = AshitaCore:GetMemoryManager():GetPlayer() end)
    if not pl then return end
    local mjl = (pcall(function() return pl:GetMainJobLevel() end) and pl:GetMainJobLevel()) or 0
    if mjl <= 0 then return end
    local job_id = pl:GetMainJob()

    local items = T{}
    local seen  = T{}
    local equipped = T{}
    for _, wsid in ipairs(get_equipped_weapon_skill_ids()) do equipped[wsid] = true end

    local function add_category(cat, sids)
        local equipped_only = (cat == 'combat') and config.combat_only_equipped
        for _, sid in ipairs(sids) do
            if not seen[sid] and not is_skill_hidden(sid, job_id) then
                if not equipped_only or equipped[sid] then
                    seen[sid] = true
                    local it = prepare(sid, cat, job_id, mjl)
                    if it then
                        it.equipped = equipped[sid] == true
                        items:append(it)
                    end
                end
            end
        end
    end

    if config.show_combat  then add_category('combat',  SKILL_CATEGORIES.combat)  end
    if config.show_defense then add_category('defense', SKILL_CATEGORIES.defense) end
    if config.show_magic   then add_category('magic',   SKILL_CATEGORIES.magic)   end
    if config.show_craft   then add_category('craft',   SKILL_CATEGORIES.craft)   end

    local mode = config.display_mode

    -- Default sort: equipped first, then by category order (combat→defense→
    -- magic→craft), then by sid within category. User sort modes override.
    local CAT_ORDER = { combat = 1, defense = 2, magic = 3, craft = 4 }
    local sm = config.sort_mode
    if sm == 'grade' then
        table.sort(items, function(a, b)
            local ra, rb = a.rank or 99, b.rank or 99
            if ra ~= rb then return ra < rb end
            return (a.sid or 0) < (b.sid or 0)
        end)
    elseif sm == 'lowest' then
        table.sort(items, function(a, b)
            local ca, cb = a.cur or 0, b.cur or 0
            if ca ~= cb then return ca < cb end
            return (a.sid or 0) < (b.sid or 0)
        end)
    elseif sm == 'progress' then
        table.sort(items, function(a, b)
            local pa, pb = a.pct or 0, b.pct or 0
            if pa ~= pb then return pa > pb end
            return (a.sid or 0) < (b.sid or 0)
        end)
    else
        table.sort(items, function(a, b)
            if a.equipped ~= b.equipped then return a.equipped end
            local ca = CAT_ORDER[a.category] or 9
            local cb = CAT_ORDER[b.category] or 9
            if ca ~= cb then return ca < cb end
            return (a.sid or 0) < (b.sid or 0)
        end)
    end

    if mode == 'donuts' then
        local per_row = (config.per_row == 0) and #items or config.per_row
        for i, item in ipairs(items) do
            local cap_str = item.cap and tostring(item.cap) or nil
            skill_donut(item.sid, item.pct, item.color, item.label,
                        item.cur_str, cap_str, item.letter, item.eff_lvl,
                        item.min_mob_lvl, item.is_cast_gated)
            if per_row > 1 and i % per_row ~= 0 and i < #items then
                imgui.SameLine(0, 4)
            end
        end
    elseif mode == 'crystals' then
        local per_row = (config.per_row == 0) and #items or config.per_row
        for i, item in ipairs(items) do
            local cap_str = item.cap and tostring(item.cap) or nil
            skill_crystal(item.sid, item.pct, item.color, item.label,
                          item.cur_str, cap_str, item.letter, item.eff_lvl,
                          item.min_mob_lvl, item.is_cast_gated)
            if per_row > 1 and i % per_row ~= 0 and i < #items then
                imgui.SameLine(0, 4)
            end
        end
    else
        local sc = config.scale or 1.0
        local pad = math.ceil(4 * sc)
        local max_tw = 0
        local max_badge_w = 0
        for _, item in ipairs(items) do
            local lbl = build_pill_label(item)
            local tw = imgui.CalcTextSize(lbl) or 0
            if tw > max_tw then max_tw = tw end
            if item.letter and item.letter ~= '' then
                local lw = imgui.CalcTextSize(item.letter) or 0
                local bw = lw + 10 + 3
                if bw > max_badge_w then max_badge_w = bw end
            end
        end
        local uniform_w = math.floor((max_tw + 36 + max_badge_w) * sc)
        local spacing = math.max(1, math.floor(2 * sc))
        imgui.Dummy({ 0, pad })
        imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 4, spacing })
        for _, item in ipairs(items) do
            imgui.SetCursorPosX(imgui.GetCursorPosX() + pad)
            render_pill_line(item, uniform_w, math.floor(max_badge_w * sc))
        end
        imgui.PopStyleVar()
        imgui.Dummy({ uniform_w + pad * 2, pad })
    end
    last_item_count = math.max(1, #items)
end

----------------------------------------------------------------
-- window chrome + settings panel
----------------------------------------------------------------
local settings_open = { false }

local function draw_window()
    if not config.visible then return end

    imgui.SetNextWindowPos({ config.x, config.y }, ImGuiCond_FirstUseEver)

    local flags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBackground,
        ImGuiWindowFlags_NoBringToFrontOnFocus)

    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
    if imgui.Begin('Prism##pr_main', true, flags) then
        draw_frame()
        local px, py = imgui.GetWindowPos()
        if px ~= config.x or py ~= config.y then
            config.x = px; config.y = py; save()
        end
    end
    imgui.End()
    imgui.PopStyleVar()
end

local function draw_settings()
    if not settings_open[1] then return end
    -- Theme: dark black window + cyan accent in place of Ashita's default red.
    imgui.PushStyleColor(ImGuiCol_WindowBg,        { 0.04, 0.05, 0.07, 0.96 })
    imgui.PushStyleColor(ImGuiCol_TitleBg,         { 0.06, 0.08, 0.11, 1.00 })
    imgui.PushStyleColor(ImGuiCol_TitleBgActive,   { 0.10, 0.14, 0.20, 1.00 })
    imgui.PushStyleColor(ImGuiCol_TitleBgCollapsed,{ 0.04, 0.05, 0.07, 0.85 })
    imgui.PushStyleColor(ImGuiCol_Border,          { 0.25, 0.30, 0.38, 0.55 })
    imgui.PushStyleColor(ImGuiCol_FrameBg,         { 0.10, 0.12, 0.16, 1.00 })
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered,  { 0.16, 0.22, 0.30, 1.00 })
    imgui.PushStyleColor(ImGuiCol_FrameBgActive,   { 0.20, 0.28, 0.38, 1.00 })
    imgui.PushStyleColor(ImGuiCol_CheckMark,       { 0.45, 0.85, 0.95, 1.00 })
    imgui.PushStyleColor(ImGuiCol_SliderGrab,      { 0.45, 0.85, 0.95, 0.85 })
    imgui.PushStyleColor(ImGuiCol_SliderGrabActive,{ 0.55, 0.95, 1.00, 1.00 })
    imgui.PushStyleColor(ImGuiCol_Button,          { 0.12, 0.16, 0.22, 1.00 })
    imgui.PushStyleColor(ImGuiCol_ButtonHovered,   { 0.20, 0.28, 0.40, 1.00 })
    imgui.PushStyleColor(ImGuiCol_ButtonActive,    { 0.28, 0.40, 0.55, 1.00 })
    imgui.PushStyleColor(ImGuiCol_Header,          { 0.16, 0.22, 0.30, 1.00 })
    imgui.PushStyleColor(ImGuiCol_HeaderHovered,   { 0.22, 0.30, 0.40, 1.00 })
    imgui.PushStyleColor(ImGuiCol_HeaderActive,    { 0.28, 0.38, 0.50, 1.00 })
    imgui.PushStyleColor(ImGuiCol_Separator,       { 0.25, 0.30, 0.38, 0.55 })
    imgui.PushStyleColor(ImGuiCol_Text,            { 0.92, 0.95, 0.98, 1.00 })

    if imgui.Begin('Prism settings##pr_set', settings_open) then
        -- Ashita's imgui.Checkbox binding expects a {bool} ref table, not a
        -- raw bool. Same shape as the settings_open `{ false }` we pass to
        -- Begin. The returned `changed` is true on the frame the user
        -- toggled; the new value lives in ref[1].
        local v_ref = { config.visible }
        if imgui.Checkbox('Show overlay', v_ref) then
            config.visible = v_ref[1]; save()
        end

        imgui.Separator()
        imgui.Text('Display Mode')
        if imgui.RadioButton('Crystals##sp_mode_c', config.display_mode == 'crystals') then
            config.display_mode = 'crystals'; save()
        end
        imgui.SameLine()
        if imgui.RadioButton('Donuts##sp_mode_d', config.display_mode == 'donuts') then
            config.display_mode = 'donuts'; save()
        end
        imgui.SameLine()
        if imgui.RadioButton('Pills##sp_mode_p', config.display_mode == 'pills') then
            config.display_mode = 'pills'; save()
        end

        imgui.Separator()
        imgui.Text('Items per row')
        local pr_max = math.max(1, last_item_count)
        local is_all = (config.per_row == 0)
        if not is_all and config.per_row > pr_max then
            config.per_row = pr_max; save()
        end
        if is_all then
            imgui.PushItemWidth(160)
            local dummy_ref = { pr_max }
            imgui.SliderInt('##sp_perrow', dummy_ref, 1, pr_max)
            imgui.PopItemWidth()
            imgui.SameLine()
            imgui.TextDisabled(('(All = %d)'):format(pr_max))
        else
            local pr_ref = { config.per_row }
            imgui.PushItemWidth(160)
            if imgui.SliderInt('##sp_perrow', pr_ref, 1, pr_max) then
                config.per_row = math.max(1, math.min(pr_max, math.floor(pr_ref[1])))
                save()
            end
            imgui.PopItemWidth()
            imgui.SameLine()
            imgui.TextDisabled(('(%d of %d)'):format(config.per_row, pr_max))
        end
        if imgui.SmallButton('1##sp_pr1') then config.per_row = 1; save() end
        imgui.SameLine()
        if imgui.SmallButton('2##sp_pr2') then config.per_row = math.min(2, pr_max); save() end
        imgui.SameLine()
        if imgui.SmallButton('3##sp_pr3') then config.per_row = math.min(3, pr_max); save() end
        imgui.SameLine()
        if imgui.SmallButton('All##sp_prall') then config.per_row = 0; save() end

        imgui.Separator()
        imgui.Text('Scale')
        local sc_ref = { config.scale }
        imgui.PushItemWidth(160)
        -- SliderFloat: { value }, min, max, format
        if imgui.SliderFloat('##sp_scale', sc_ref, 0.6, 2.0, '%.2fx') then
            config.scale = math.max(0.6, math.min(2.0, sc_ref[1]))
            save()
        end
        imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.SmallButton('Reset##sp_scale_reset') then
            config.scale = 1.0; save()
        end

        imgui.Separator()
        imgui.Text('Sort')
        if imgui.RadioButton('Default##sp_sort_d', config.sort_mode == 'default') then
            config.sort_mode = 'default'; save()
        end
        imgui.SameLine()
        if imgui.RadioButton('By Grade##sp_sort_g', config.sort_mode == 'grade') then
            config.sort_mode = 'grade'; save()
        end
        imgui.SameLine()
        if imgui.RadioButton('Progress##sp_sort_p', config.sort_mode == 'progress') then
            config.sort_mode = 'progress'; save()
        end
        if imgui.RadioButton('Lowest##sp_sort_lo', config.sort_mode == 'lowest') then
            config.sort_mode = 'lowest'; save()
        end

        imgui.Separator()
        imgui.Text('Show categories')
        local function cat_check(label, key)
            local r = { config[key] }
            if imgui.Checkbox(label .. '##sp_cat_' .. key, r) then
                config[key] = r[1]; save()
            end
        end
        cat_check('Combat',  'show_combat');  imgui.SameLine()
        cat_check('Defense', 'show_defense'); imgui.SameLine()
        cat_check('Magic',   'show_magic');   imgui.SameLine()
        cat_check('Craft',   'show_craft')
        if config.show_combat then
            imgui.Indent(16)
            local eq_ref = { config.combat_only_equipped }
            if imgui.Checkbox('Only show currently-equipped weapons##sp_cat_eq', eq_ref) then
                config.combat_only_equipped = eq_ref[1]; save()
            end
            imgui.Unindent(16)
        end
        imgui.TextDisabled('Magic and combat are filtered by your main job.')
        imgui.TextDisabled('Defense shows only blocks your job has access to. Craft shows only skills you have trained.')

        imgui.Separator()
        local c_ref = { config.show_capped }
        if imgui.Checkbox('Show capped skills', c_ref) then
            config.show_capped = c_ref[1]; save()
        end
        local pf_ref = { config.persist_frac }
        if imgui.Checkbox('Persist fractional progress (survives /logout)', pf_ref) then
            config.persist_frac = pf_ref[1]
            -- If user just turned persistence OFF, drop any stored frac so it
            -- doesn't reload stale values on next login.
            if not config.persist_frac then
                for k, _ in pairs(config.skill_frac) do config.skill_frac[k] = nil end
            end
            save()
        end
        local cs_ref = { config.chat_skillups }
        if imgui.Checkbox('Enhanced chat skillup messages', cs_ref) then
            config.chat_skillups = cs_ref[1]; save()
        end
        if config.chat_skillups then
            imgui.Indent(16)
            imgui.TextDisabled('Pick a color for each skillup magnitude. /prism chattest to preview.')
            local function color_row(label, cfg_key)
                imgui.Text(label)
                imgui.SameLine(60)
                local current = config[cfg_key]
                local selected_name = '?'
                for i, sw in ipairs(CHAT_PALETTE) do
                    local rgba = { sw.rgb[1], sw.rgb[2], sw.rgb[3], 1.0 }
                    -- ImGuiColorEditFlags_NoTooltip = 1<<8 (256)
                    if imgui.ColorButton('##sp_' .. cfg_key .. '_' .. i, rgba, 256, { 18, 18 }) then
                        config[cfg_key] = sw.code; save()
                    end
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip(('%s (code %d)'):format(sw.name, sw.code))
                    end
                    if sw.code == current then selected_name = sw.name end
                    imgui.SameLine()
                end
                -- Numeric escape hatch: type any 0..255 chat code directly.
                -- Use this with /prism colorsweep when no swatch matches.
                local code_ref = { current }
                imgui.PushItemWidth(50)
                if imgui.InputInt('##sp_' .. cfg_key .. '_code', code_ref, 0, 0) then
                    local v = math.max(0, math.min(255, math.floor(code_ref[1] or 0)))
                    config[cfg_key] = v; save()
                end
                imgui.PopItemWidth()
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Type any 0..255 chat code. Use /prism colorsweep to find one.')
                end
                imgui.SameLine()
                imgui.TextDisabled(('  %s'):format(selected_name))
            end
            color_row('0.1',  'chat_color_low')
            color_row('0.2',  'chat_color_mid')
            color_row('0.3',  'chat_color_high')
            color_row('0.4+', 'chat_color_max')
            color_row('+1',   'chat_color_tick')
            imgui.Unindent(16)
        end

        imgui.Separator()
        -- Per-job, per-skill visibility. Sections populated dynamically from
        -- the current job's rank tables so RDM sees a different list than
        -- DRK. Selections are persisted per-job (see skills_hidden_by_job).
        local sp_pl
        pcall(function() sp_pl = AshitaCore:GetMemoryManager():GetPlayer() end)
        local sp_job = sp_pl and sp_pl:GetMainJob() or nil
        local sp_job_name = (sp_job and JOB_ABBR and JOB_ABBR[sp_job]) or ('Job#' .. tostring(sp_job or '?'))
        imgui.Text('Skills to show')
        imgui.SameLine()
        imgui.TextDisabled('(' .. sp_job_name .. ' -- saved per job)')

        local function skill_check(sid, label)
            local hidden = is_skill_hidden(sid, sp_job)
            local r = { not hidden }
            if imgui.Checkbox(label .. '##sp_sk_' .. tostring(sid), r) then
                set_skill_hidden(sid, not r[1], sp_job)
                save()
            end
        end
        -- Render a category section: header line + up-to-3-columns of checkboxes
        -- for the sids the current job actually has access to.
        local function category_section(label, sids)
            if #sids == 0 then return end
            imgui.TextDisabled(label)
            local col = 1
            for _, sid in ipairs(sids) do
                if col > 1 then imgui.SameLine() end
                skill_check(sid, SKILL_NAMES[sid] or ('Skill#' .. sid))
                col = col + 1
                if col > 3 then col = 1 end
            end
        end

        if sp_job then
            -- Combat: only weapons/ranged this job has a rank for.
            if config.show_combat then
                local combat_sids = {}
                for _, sid in ipairs(SKILL_CATEGORIES.combat) do
                    if rank_for_job_skill(sp_job, sid) then combat_sids[#combat_sids+1] = sid end
                end
                category_section('Combat', combat_sids)
            end
            -- Defense: only the blocks this job has a rank for.
            if config.show_defense then
                local def_sids = {}
                for _, sid in ipairs(SKILL_CATEGORIES.defense) do
                    if rank_for_job_skill(sp_job, sid) then def_sids[#def_sids+1] = sid end
                end
                category_section('Defense', def_sids)
            end
            -- Magic: only the schools this job casts as main (cast allowlist).
            if config.show_magic then
                local mag_sids = {}
                for _, sid in ipairs(SKILL_CATEGORIES.magic) do
                    if rank_for_job_magic_skill(sp_job, sid) then mag_sids[#mag_sids+1] = sid end
                end
                category_section('Magic', mag_sids)
            end
            -- Craft: only ones you've trained (cur > 0 or stored frac > 0).
            if config.show_craft then
                local craft_sids = {}
                for _, sid in ipairs(SKILL_CATEGORIES.craft) do
                    local cur = get_combat_skill(sid)
                    if (cur and cur > 0) or frac_get(sid) > 0 then
                        craft_sids[#craft_sids+1] = sid
                    end
                end
                category_section('Craft', craft_sids)
            end
        else
            imgui.TextDisabled('Log in to see per-job skill list.')
        end
    end
    imgui.End()
    imgui.PopStyleColor(19)
end
ashita.events.register('d3d_present', 'sp_present', function()
    draw_window()
    draw_settings()
end)

----------------------------------------------------------------
-- chat skillup messages (opt-in via config.chat_skillups). Format
-- adapted from Jull256/skilluptracker (Mujihina original). Default
-- OFF so we don't double-print for users running skilluptracker too.
----------------------------------------------------------------
local function _cap_for_sid(sid)
    -- Crafts/gathering (48+) live in a separate memory array (GetCraftSkill)
    -- with no static rank tables, so read their cap from the craft accessor.
    -- GetCombatSkill doesn't know about them and would leave the cap as '?'.
    if CRAFT_SID_TO_IDX[sid] then
        local _, _, craft_cap = get_craft_skill(sid)
        return craft_cap
    end
    -- Prefer the engine's reported cap (covers defensive 28-31; also covers
    -- HorizonXI rank divergence from retail). Static rank+CAP_REF math is the
    -- fallback for skills the engine doesn't expose a cap for.
    local _, _, engine_cap = get_combat_skill(sid)
    if engine_cap and engine_cap > 0 then return engine_cap end
    local pl = AshitaCore:GetMemoryManager():GetPlayer()
    if not pl then return nil end
    local job_id = pl:GetMainJob()
    local mjl    = pl:GetMainJobLevel()
    local rank
    if sid >= 32 and sid <= 39 then
        rank = rank_for_job_magic_skill(job_id, sid)
    else
        rank = rank_for_job_skill(job_id, sid)
    end
    if not rank then return nil end
    return skill_cap_for(rank, mjl)
end

-- Read current integer skill from memory. Combat skills 1..47 come from
-- GetCombatSkill; crafts/gathering (48+) live in the separate GetCraftSkill
-- array, so route those through get_craft_skill or they'd read as 0.
local function _cur_int_for_sid(sid)
    if CRAFT_SID_TO_IDX[sid] then
        local cur = get_craft_skill(sid)
        return cur or 0
    end
    local ok, v = pcall(function()
        local pl = AshitaCore:GetMemoryManager():GetPlayer()
        local sk = pl and pl:GetCombatSkill(sid)
        return sk and sk:GetSkill() or 0
    end)
    return ok and v or 0
end

-- Emit one enhanced skillup line. kind='frac' (delta in tenths 1..9)
-- or kind='tick' (new integer value). Silent if chat_skillups is off.
local function emit_skillup_chat(sid, kind, value)
    if not config.chat_skillups then return end
    local name = SKILL_NAMES[sid] or ('Skill#' .. sid)
    local cap  = _cap_for_sid(sid)
    local cap_str = cap and tostring(cap) or '?'
    local cm = AshitaCore and AshitaCore:GetChatManager()
    if not cm then return end
    -- Build directly with FFXI color bytes (\x1E + color + text + \x1E\x01).
    -- AddChatMessage(mode, indexed=false, msg) bypasses text_in so external
    -- filters (including our own anti-double-print) cannot eat our output.
    local CC = function(color, text) return string.char(0x1E, color) .. text .. string.char(0x1E, 0x01) end
    local header = CC(102, '[' .. addon.name .. ']') .. ' '
    if kind == 'frac' then
        local cur_eff = _cur_int_for_sid(sid) + math.min(0.9, frac_get(sid))
        local capped  = cap and cur_eff >= cap
        -- Bucket color by magnitude: 0.1 = low, 0.2 = mid, 0.3 = high, 0.4+ = max.
        local frac_color = config.chat_color_mid
        if value <= 1 then
            frac_color = config.chat_color_low
        elseif value == 3 then
            frac_color = config.chat_color_high
        elseif value >= 4 then
            frac_color = config.chat_color_max
        end
        local msg = header
            .. CC(106, name)
            .. ' '
            .. CC(frac_color, ('+0.%d'):format(value))
            .. ' ('
            .. CC(capped and 8 or 106, ('%.1f/%s'):format(cur_eff, cap_str))
            .. ')'
        cm:AddChatMessage(1, false, msg)
    elseif kind == 'tick' then
        local capped = cap and value >= cap
        local msg = header
            .. CC(106, name)
            .. ' '
            .. CC(config.chat_color_tick or 6, 'level up')
            .. ' ('
            .. CC(capped and 8 or 106, ('%d/%s'):format(value, cap_str))
            .. ')'
        cm:AddChatMessage(1, false, msg)
    end
end

----------------------------------------------------------------
-- packet_in: authoritative skillup capture (0x29 MessageNum 38/53).
-- Adapted from Jull256/skilluptracker (Mujihina original).
--   msgnum 38: fractional skillup. Data=skillID, Data2=delta in tenths.
--   msgnum 53: integer skillup tick. Clear fractional accumulator.
----------------------------------------------------------------
ashita.events.register('packet_in', 'sp_packet_cb', function(e)
    if e.id ~= 0x0029 then return end
    local ok, raw_msgnum = pcall(struct.unpack, 'H', e.data, 0x18 + 0x01)
    if not ok or not raw_msgnum then return end
    -- Bit 15 is a flag (battle-message marker); the actual MessageNum is the
    -- lower 15 bits. simplelog masks with %2^15 for the same reason. Without
    -- this mask, msgnum reads as 32806 instead of 38 when the flag is set.
    local msgnum = raw_msgnum % 32768
    if msgnum == 38 then
        local sid    = struct.unpack('L', e.data, 0x0C + 0x01)
        local tenths = struct.unpack('L', e.data, 0x10 + 0x01)
        if sid and tenths and sid > 0 and sid <= 56 then
            frac_add(sid, (tenths or 0) / 10)
            _skillup_pkt_at[sid] = os.clock()
            -- Only emit + suppress for skills we have a label for. Unknown
            -- skill IDs fall through so the game's native message still shows.
            if config.chat_skillups and SKILL_NAMES[sid] then
                emit_skillup_chat(sid, 'frac', tenths)
                e.blocked = true
            end
        end
    elseif msgnum == 53 then
        local sid    = struct.unpack('L', e.data, 0x0C + 0x01)
        local newint = struct.unpack('L', e.data, 0x10 + 0x01)
        if sid and sid > 0 and sid <= 56 then
            frac_reset(sid)
            _skillup_pkt_at[sid] = os.clock()
            if config.chat_skillups and SKILL_NAMES[sid] then
                emit_skillup_chat(sid, 'tick', newint or 0)
                e.blocked = true
            end
        end
    end
end)

----------------------------------------------------------------
-- text_in: chat-scrape fallback for fractional skillups. Packet 0x29
-- normally beats us to it; we dedupe via _skillup_pkt_at within 1.5s.
-- Matches "Your <Skill> skill rises 0.X points." and the bare-name and
-- "rises by 0.X" variants.
----------------------------------------------------------------
ashita.events.register('text_in', 'sp_text_in', function(e)
    local s = e and e.message or ''
    if s == '' then return end
    -- Fractional capture (fallback if packet_in didn't fire). Dedupes via _skillup_pkt_at.
    local emitted_replacement = false
    local name, frac = s:match('([%a%-]+[%a%- ]*)%s*skill rises[%s%a]*0%.(%d)')
    if name and frac then
        local sid = CHAT_SKILL_NAMES[name:lower():gsub('^your%s+',''):gsub('%s+$','')]
        if sid then
            local fresh_pkt = _skillup_pkt_at[sid] and (os.clock() - _skillup_pkt_at[sid]) < 1.5
            if not fresh_pkt then
                local delta = tonumber('0.' .. frac) or 0
                frac_add(sid, delta)
                -- packet_in didn't beat us to it; emit the enhanced line ourselves.
                if config.chat_skillups then
                    emit_skillup_chat(sid, 'frac', tonumber(frac) or 0)
                    emitted_replacement = true
                end
            else
                -- packet path already emitted; we still need to suppress the
                -- native chat line that follows so it isn't double-printed.
                emitted_replacement = config.chat_skillups
            end
        end
    end
    -- Only suppress the game's native "skill rises / reaches" line when we
    -- actually emitted (or are about to emit, via the packet path) a
    -- replacement. Skills we don't recognize -- e.g. an unmapped craft or a
    -- new skill ID -- pass through unaltered so the user still sees them.
    -- Never block our own emitted lines or the addon eats itself.
    if config.chat_skillups
        and emitted_replacement
        and (s:match('skill rises') or s:match('skill reaches'))
        and not s:find('[' .. addon.name .. ']', 1, true) then
        e.blocked = true
    end
end)

----------------------------------------------------------------
-- slash commands
----------------------------------------------------------------
ashita.events.register('command', 'sp_command', function(e)
    local args = e.command:args()
    local head = args[1] and args[1]:lower() or ''
    if head ~= '/prism' and head ~= '/pr' then return end
    e.blocked = true

    local sub = args[2] and args[2]:lower() or 'settings'
    if sub == 'on' then
        config.visible = true; save(); say('overlay ON')
    elseif sub == 'off' then
        config.visible = false; save(); say('overlay OFF')
    elseif sub == 'toggle' then
        config.visible = not config.visible; save()
        say('overlay ' .. (config.visible and 'ON' or 'OFF'))
    elseif sub == 'mode' then
        local m = args[3] and args[3]:lower()
        if m == 'pills' or m == 'donuts' or m == 'crystals' then
            config.display_mode = m; save(); say('mode = ' .. m)
        else
            say('usage: /prism mode crystals|donuts|pills (current: ' .. config.display_mode .. ')')
        end
    elseif sub == 'perrow' or sub == 'per_row' or sub == 'pr' then
        local n = tonumber(args[3])
        if n and n >= 1 and n <= 24 then
            config.per_row = math.floor(n); save()
            say(('per_row = %d'):format(config.per_row))
        else
            say('usage: /prism perrow 1..24 (current: ' .. tostring(config.per_row) .. ')')
        end
    elseif sub == 'reset' then
        config.x = 20; config.y = 320; save(); say('position reset')
    elseif sub == 'settings' or sub == 'config' then
        settings_open[1] = not settings_open[1]
        say('settings ' .. (settings_open[1] and 'OPEN' or 'closed'))
    elseif sub == 'capped' then
        config.show_capped = not config.show_capped; save()
        say('show_capped ' .. (config.show_capped and 'ON' or 'OFF'))
    elseif sub == 'persistfrac' or sub == 'persist' then
        local arg = (args[3] or 'toggle'):lower()
        if arg == 'on' then
            config.persist_frac = true
        elseif arg == 'off' then
            config.persist_frac = false
            for k, _ in pairs(config.skill_frac) do config.skill_frac[k] = nil end
        else
            config.persist_frac = not config.persist_frac
            if not config.persist_frac then
                for k, _ in pairs(config.skill_frac) do config.skill_frac[k] = nil end
            end
        end
        save()
        say('persist_frac ' .. (config.persist_frac and 'ON' or 'OFF'))
    elseif sub == 'chat' or sub == 'chatskillups' then
        local arg = (args[3] or 'toggle'):lower()
        if arg == 'on' then
            config.chat_skillups = true
        elseif arg == 'off' then
            config.chat_skillups = false
        else
            config.chat_skillups = not config.chat_skillups
        end
        save()
        say('chat_skillups ' .. (config.chat_skillups and 'ON' or 'OFF'))
    elseif sub == 'chattest' then
        -- Diagnostic: emit one of each magnitude (0.1, 0.2, 0.3, 0.4) plus a tick,
        -- so the user can see all four color buckets at once for tuning.
        local was = config.chat_skillups
        config.chat_skillups = true
        emit_skillup_chat(3, 'frac', 1)
        emit_skillup_chat(3, 'frac', 2)
        emit_skillup_chat(3, 'frac', 3)
        emit_skillup_chat(3, 'frac', 4)
        emit_skillup_chat(3, 'tick', 96)
        config.chat_skillups = was
        say('chattest: emitted 0.1/0.2/0.3/0.4 + tick samples (state preserved)')
    elseif sub == 'colortest' then
        -- Dump every palette swatch as a labeled sample line so you can see
        -- exactly how each FFXI chat color code actually renders, and compare
        -- against the swatches in /prism settings to calibrate.
        local cm = AshitaCore and AshitaCore:GetChatManager()
        if not cm then return end
        local CC = function(color, text) return string.char(0x1E, color) .. text .. string.char(0x1E, 0x01) end
        local header = CC(102, '[' .. addon.name .. ']') .. ' '
        for _, sw in ipairs(CHAT_PALETTE) do
            local body = ('code %3d  %s   '):format(sw.code, sw.name)
                .. CC(sw.code, ('Your Sword skill rises 0.3 points (this is %s)'):format(sw.name))
            cm:AddChatMessage(1, false, header .. body)
        end
        say('colortest: dumped ' .. tostring(#CHAT_PALETTE) .. ' palette codes')
    elseif sub == 'colorsweep' then
        -- Calibration: emit every chat color code in a range as a labeled
        -- sample line, so unknown codes can be found empirically. Usage:
        --   /prism colorsweep            -> sweeps 1..127
        --   /prism colorsweep 30 80      -> sweeps 30..80 (inclusive)
        local cm = AshitaCore and AshitaCore:GetChatManager()
        if not cm then return end
        local lo = tonumber(args[3]) or 1
        local hi = tonumber(args[4]) or 127
        if lo < 1 then lo = 1 end
        if hi > 255 then hi = 255 end
        if hi < lo then hi = lo end
        local CC = function(color, text) return string.char(0x1E, color) .. text .. string.char(0x1E, 0x01) end
        local header = CC(102, '[' .. addon.name .. ']') .. ' '
        for code = lo, hi do
            local body = ('code %3d   '):format(code)
                .. CC(code, ('this is color %d  +0.3 / level up'):format(code))
            cm:AddChatMessage(1, false, header .. body)
        end
        say(('colorsweep: dumped codes %d..%d'):format(lo, hi))
    elseif sub == 'diag' then
        -- Diagnostic: for every defined SKILL_NAMES sid, dump engine vs.
        -- table values so we can spot where cap math is going wrong. Use
        -- when a skill displays the wrong cap or rank letter.
        local pl = AshitaCore:GetMemoryManager():GetPlayer()
        if not pl then say('diag: no player'); return end
        local job_id = pl:GetMainJob()
        local mjl    = pl:GetMainJobLevel()
        say(('diag: job=%d mjl=%d'):format(job_id, mjl))
        local sids = {}
        for sid, _ in pairs(SKILL_NAMES) do sids[#sids+1] = sid end
        table.sort(sids)
        for _, sid in ipairs(sids) do
            local cur, rank, ecap = get_combat_skill(sid)
            if cur and (cur > 0 or ecap and ecap > 0) then
                local tbl_rank = rank_for_job_skill(job_id, sid)
                              or rank_for_job_magic_skill(job_id, sid)
                local tbl_cap  = tbl_rank and skill_cap_for(tbl_rank, mjl) or nil
                say(('  %-12s sid=%2d  cur=%-4s  eng:rank=%-4s cap=%-4s  tbl:rank=%-4s cap=%-4s'):format(
                    SKILL_NAMES[sid] or '?',
                    sid,
                    tostring(cur),
                    tostring(rank or '-'),
                    tostring(ecap or '-'),
                    tostring(tbl_rank or '-'),
                    tostring(tbl_cap or '-')
                ))
            end
        end
    elseif sub == 'equippedonly' or sub == 'equipped' then
        local v = (args[3] or 'toggle'):lower()
        if v == 'on' then config.combat_only_equipped = true
        elseif v == 'off' then config.combat_only_equipped = false
        else config.combat_only_equipped = not config.combat_only_equipped end
        save()
        say('combat_only_equipped ' .. (config.combat_only_equipped and 'ON' or 'OFF'))
    elseif sub == 'category' or sub == 'cat' then
        -- /prism category combat|defense|magic|craft [on|off|toggle]
        local which = (args[3] or ''):lower()
        local key
        if which == 'combat'  then key = 'show_combat'
        elseif which == 'defense' or which == 'def' then key = 'show_defense'
        elseif which == 'magic'   or which == 'mag' then key = 'show_magic'
        elseif which == 'craft'   or which == 'crafts' then key = 'show_craft'
        end
        if not key then
            say('usage: /prism category combat|defense|magic|craft [on|off|toggle]')
            say(('  combat=%s defense=%s magic=%s craft=%s'):format(
                tostring(config.show_combat), tostring(config.show_defense),
                tostring(config.show_magic),  tostring(config.show_craft)))
        else
            local v = (args[4] or 'toggle'):lower()
            if v == 'on' then config[key] = true
            elseif v == 'off' then config[key] = false
            else config[key] = not config[key] end
            save()
            say(key .. ' ' .. (config[key] and 'ON' or 'OFF'))
        end
    elseif sub == 'show' or sub == 'hide' then
        -- /prism show <name>  /prism hide <name>  -- toggle per-skill visibility by name match
        local target = (args[3] or ''):lower()
        if target == '' then
            say('usage: /prism ' .. sub .. ' <skill name>')
        else
            local hit
            for sid, nm in pairs(SKILL_NAMES) do
                if nm:lower() == target then hit = sid; break end
            end
            if not hit then
                for sid, nm in pairs(SKILL_NAMES) do
                    if nm:lower():find(target, 1, true) then hit = sid; break end
                end
            end
            if hit then
                local cur_job
                pcall(function() cur_job = AshitaCore:GetMemoryManager():GetPlayer():GetMainJob() end)
                set_skill_hidden(hit, sub == 'hide', cur_job)
                save()
                say(SKILL_NAMES[hit] .. ' ' .. (sub == 'hide' and 'HIDDEN' or 'SHOWN') .. ' on this job')
            else
                say('no skill matched "' .. target .. '"')
            end
        end
    else
        say('commands:')
        say('  /prism on|off|toggle              -- show/hide overlay')
        say('  /prism settings                   -- open settings panel')
        say('  /prism mode crystals|donuts|pills -- display style')
        say('  /prism perrow 1..24               -- items per row')
        say('  /prism capped                     -- toggle showing capped skills')
        say('  /prism persistfrac on|off|toggle  -- persist fractional skill progress')
        say('  /prism chat on|off|toggle         -- enhanced chat skillup messages')
        say('  /prism chattest                   -- emit 2 sample chat lines (diagnostic)')
        say('  /prism colortest                  -- preview every palette swatch (calibration)')
        say('  /prism colorsweep [lo] [hi]       -- dump raw code range to find new colors')
        say('  /prism diag                       -- dump engine vs. table caps per skill')
        say('  /prism category <name> [on|off]   -- toggle combat|defense|magic|craft category')
        say('  /prism equippedonly [on|off]      -- Combat: only show currently-equipped weapons')
        say('  /prism show <name>                -- show a specific skill (e.g. Elemental)')
        say('  /prism hide <name>                -- hide a specific skill')
        say('  /prism reset                      -- reset window position')
    end
end)

ashita.events.register('load', 'prism_load', function()
    say(('loaded v%s -- /prism settings to configure'):format(addon.version))
end)

-- Flush any debounced fractional progress on unload/zone/logout so we don't
-- lose the last 0.1-0.9 of work to the 2-second save window.
ashita.events.register('unload', 'prism_unload', function()
    frac_flush()
end)

