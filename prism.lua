addon.name      = 'prism'
addon.author    = 'Blake & Watney'
addon.version = '0.5.4'
addon.desc      = 'Prism — floating skill overlay. Tier-colored crystals, donuts, or pills. Tracks combat & magic skill progress with effective level and min mob hints.'
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
    persist_frac = true,     -- save fractional skill progress to disk; survives /logout
    chat_skillups = false,   -- enhanced chat line on skillup
    -- FFXI chat color codes (0..255) for fractional skillup magnitude. Defaults
    -- form a subtle->loud ramp (cream->cyan->bright red) so 0.3s grab your eye
    -- and 0.1s fade. Override via the swatch picker in /prism settings.
    chat_color_low  = 106,   -- color for 0.1 skillups (cream, subtle)
    chat_color_mid  = 6,     -- color for 0.2 skillups (cyan, noticeable)
    chat_color_high = 76,    -- color for 0.3+ skillups (bright red, loud)
    -- Per-skill visibility, keyed by SID (string keys for stable serialization).
    -- nil/missing => visible by default.
    skills_hidden = T{},
    -- Persisted fractional skill progress (sid -> 0.0..0.9). Filled by packet
    -- 0x29 / chat capture, reset on integer tick. Persisted so a /logout in
    -- the middle of grinding doesn't throw away the 0.1-0.9 you already earned.
    skill_frac   = T{},
}
local config = settings.load(default_config)
-- normalize legacy/invalid values so a hand-edit can't wedge the overlay
local function normalize_config()
    if  config.display_mode ~= 'pills'
    and config.display_mode ~= 'donuts'
    and config.display_mode ~= 'crystals' then
        config.display_mode = 'crystals'
    end
    if type(config.per_row) ~= 'number' then config.per_row = 3 end
    config.per_row = math.max(1, math.min(24, math.floor(config.per_row)))
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
    if type(config.persist_frac) ~= 'boolean' then config.persist_frac = true end
    if type(config.skill_frac) ~= 'table' then config.skill_frac = T{} end
    if type(config.chat_skillups) ~= 'boolean' then config.chat_skillups = false end
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

local function is_skill_hidden(sid)
    return config.skills_hidden[tostring(sid)] == true
end
local function set_skill_hidden(sid, hidden)
    local k = tostring(sid)
    if hidden then
        config.skills_hidden[k] = true
    else
        config.skills_hidden[k] = nil
    end
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
    [32]='Divine', [33]='Healing', [34]='Enhancing', [35]='Enfeebling',
    [36]='Elemental', [37]='Dark', [38]='Summoning', [39]='Ninjutsu',
}

local MAGIC_SKILL_IDS = { 33, 34, 35, 32, 36, 37, 38, 39 }

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
    { code = 76,  name = 'salmon',  rgb = { 1.00, 0.55, 0.55 } },
    { code = 68,  name = 'pink',    rgb = { 1.00, 0.55, 0.75 } },
    { code = 5,   name = 'magenta', rgb = { 1.00, 0.45, 1.00 } },
    { code = 81,  name = 'violet',  rgb = { 0.70, 0.50, 1.00 } },
    { code = 6,   name = 'cyan',    rgb = { 0.40, 0.95, 1.00 } },
    { code = 2,   name = 'green',   rgb = { 0.35, 1.00, 0.35 } },
}

-- Cast-gated magic skills only get skillups from casting (self/party
-- targets). All offensive magic is mob-level-gated like weapons, so we
-- show "Lv N+" for them just like combat skills.
local SKILL_IS_CAST_GATED = { [33]=true, [34]=true }

local RANK_LETTERS = {
    [0]='A+', [1]='A', [2]='A-', [3]='B+', [4]='B', [5]='B-',
    [6]='C+', [7]='C', [8]='C-', [9]='D',  [10]='E', [11]='F', [12]='G',
}

local RANK_SLOPES = {
    [0]=3.98, [1]=3.90, [2]=3.82, [3]=3.67, [4]=3.53, [5]=3.39,
    [6]=3.24, [7]=3.08, [8]=2.92, [9]=2.69, [10]=2.47, [11]=2.24, [12]=2.02,
}

local CAP_REF = {
    [0]  = {{1,6},{2,9}, {5,18},{10,39},{15,56},{20,74},{25,92},{30,111},{35,130},{40,148},{45,165},{50,200},{60,230},{75,276}}, -- A+
    [1]  = {{1,6},{2,8}, {5,18},{10,37},{15,53},{20,70},{25,87},{30,104},{35,122},{40,140},{45,158},{50,196},{60,225},{75,272}}, -- A
    [2]  = {{1,6},{2,8}, {5,18},{10,33},{15,48},{20,63},{25,78},{30,93},{35,108},{40,123},{45,138},{50,153},{55,178},{60,203},{65,223},{70,244},{75,269}}, -- A-
    [3]  = {{1,5},{2,7}, {5,17},{10,34},{15,48},{20,64},{25,80},{30,96}, {35,112},{40,130},{45,148},{50,185},{60,213},{75,261}}, -- B+
    [4]  = {{1,5},{2,7}, {5,16},{10,33},{15,46},{20,61},{25,77},{30,92}, {35,108},{40,124},{45,142},{50,178},{60,205},{75,252}}, -- B
    [5]  = {{1,5},{2,7}, {5,16},{10,31},{15,44},{20,58},{25,74},{30,88}, {35,104},{40,119},{45,138},{50,171},{60,197},{75,243}}, -- B-
    [6]  = {{1,5},{2,7}, {5,16},{10,30},{15,42},{20,56},{25,70},{30,85}, {35,99}, {40,114},{45,132},{50,164},{60,189},{75,234}}, -- C+
    [7]  = {{1,5},{2,7}, {5,15},{10,29},{15,40},{20,53},{25,67},{30,81}, {35,95}, {40,108},{45,124},{50,156},{60,180},{75,225}}, -- C
    [8]  = {{1,5},{2,7}, {5,15},{10,27},{15,38},{20,51},{25,64},{30,77}, {35,90}, {40,102},{45,118},{50,148},{60,170},{75,215}}, -- C-
    [9]  = {{1,5},{2,6}, {5,14},{10,25},{15,35},{20,46},{25,58},{30,70}, {35,82}, {40,93}, {45,108},{50,137},{60,158},{75,200}}, -- D
    [10] = {{1,5},{2,6}, {5,13},{10,23},{15,31},{20,41},{25,52},{30,63}, {35,74}, {40,84}, {45,98}, {50,126},{60,145},{75,182}}, -- E
    [11] = {{1,5},{2,6}, {5,12},{10,21},{15,28},{20,37},{25,47},{30,57}, {35,67}, {40,76}, {45,89}, {50,115},{60,133},{75,167}}, -- F
}

local JOB_SKILL_RANK = {
    [1]  = { [1]=9,  [2]=10, [3]=4,  [4]=1,  [5]=3,  [6]=2,  [7]=9,  [8]=3,  [9]=10, [10]=10, [11]=9,  [12]=9  }, -- WAR
    [2]  = { [1]=0,  [2]=10, [3]=10, [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=9,  [12]=4  }, -- MNK
    [3]  = { [1]=9,  [2]=10, [3]=10, [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=4,  [12]=3  }, -- WHM
    [4]  = { [1]=10, [2]=10, [3]=10, [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=9,  [12]=2  }, -- BLM
    [5]  = { [1]=10, [2]=4,  [3]=4,  [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=9,  [12]=4  }, -- RDM
    [6]  = { [1]=9,  [2]=2,  [3]=6,  [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=10, [12]=10 }, -- THF
    [7]  = { [1]=10, [2]=4,  [3]=1,  [4]=9,  [5]=9,  [6]=10, [7]=10, [8]=9,  [9]=10, [10]=10, [11]=9,  [12]=10 }, -- PLD
    [8]  = { [1]=9,  [2]=5,  [3]=5,  [4]=1,  [5]=9,  [6]=10, [7]=2,  [8]=10, [9]=10, [10]=10, [11]=10, [12]=10 }, -- DRK
    [9]  = { [1]=6,  [2]=9,  [3]=9,  [4]=9,  [5]=5,  [6]=9,  [7]=9,  [8]=9,  [9]=10, [10]=10, [11]=9,  [12]=9  }, -- BST
    [10] = { [1]=10, [2]=7,  [3]=5,  [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=9,  [12]=9  }, -- BRD
    [11] = { [1]=10, [2]=9,  [3]=9,  [4]=9,  [5]=4,  [6]=9,  [7]=9,  [8]=9,  [9]=10, [10]=10, [11]=9,  [12]=9  }, -- RNG
    [12] = { [1]=10, [2]=9,  [3]=3,  [4]=9,  [5]=10, [6]=10, [7]=10, [8]=3,  [9]=2,  [10]=1,  [11]=10, [12]=9  }, -- SAM
    [13] = { [1]=9,  [2]=3,  [3]=6,  [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=2,  [10]=10, [11]=10, [12]=10 }, -- NIN
    [14] = { [1]=10, [2]=9,  [3]=6,  [4]=9,  [5]=9,  [6]=10, [7]=9,  [8]=1,  [9]=10, [10]=10, [11]=10, [12]=9  }, -- DRG
    [15] = { [1]=10, [2]=10, [3]=10, [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=9,  [12]=5  }, -- SMN
    [16] = { [1]=6,  [2]=6,  [3]=6,  [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=9,  [12]=9  }, -- BLU
    [17] = { [1]=10, [2]=3,  [3]=4,  [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=9,  [12]=9  }, -- COR
    [18] = { [1]=2,  [2]=10, [3]=10, [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=10, [12]=9  }, -- PUP
    [19] = { [1]=9,  [2]=2,  [3]=9,  [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=9,  [12]=9  }, -- DNC
    [20] = { [1]=9,  [2]=10, [3]=10, [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=4,  [12]=3  }, -- SCH
    [21] = { [1]=10, [2]=10, [3]=10, [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=10, [12]=2  }, -- GEO
    [22] = { [1]=9,  [2]=9,  [3]=4,  [4]=10, [5]=10, [6]=10, [7]=10, [8]=10, [9]=10, [10]=10, [11]=10, [12]=9  }, -- RUN
}

local JOB_MAGIC_SKILL_RANK = {
    [3]  = { [33]=0, [34]=3, [35]=5, [32]=3 }, -- WHM
    [5]  = { [35]=0, [34]=3, [36]=6, [33]=8, [32]=10, [37]=10 }, -- RDM
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
        if level <= ref[1][1] then return ref[1][2] end
        if level >= ref[#ref][1] then return ref[#ref][2] end
        for i = 1, #ref - 1 do
            local lo, hi = ref[i], ref[i+1]
            if level >= lo[1] and level <= hi[1] then
                local t = (level - lo[1]) / (hi[1] - lo[1])
                return math.floor(lo[2] + (hi[2] - lo[2]) * t + 0.5)
            end
        end
    end
    local slope = RANK_SLOPES[rank_idx]
    if not slope then return nil end
    return math.floor(5 + slope * (level - 1) + 0.5)
end

-- Smallest level L (1..75) at which skill_cap_for(rank, L) >= cur.
local function effective_level_for(rank_idx, cur)
    if not rank_idx or not cur then return nil end
    for L = 1, 75 do
        local c = skill_cap_for(rank_idx, L)
        if c and c >= cur then return L end
    end
    return 75
end

-- Smallest mob level whose rank-curve cap exceeds cur. For combat skills
-- this is the minimum mob level you can still get skillups from. Returns
-- nil at the 75 ceiling.
local function min_mob_level_for(rank_idx, cur)
    if not rank_idx or not cur then return nil end
    for L = 1, 75 do
        local c = skill_cap_for(rank_idx, L)
        if c and c > cur then return L end
    end
    return nil
end

----------------------------------------------------------------
-- player + skill readers
----------------------------------------------------------------
local function get_main_weapon_skill_id()
    local ok, sid = pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory()
        local eq = inv:GetEquippedItem(0)
        if not eq or eq.Index == 0 then return nil end
        local container = math.floor(eq.Index / 0x100)
        local slot = eq.Index % 0x100
        local item = inv:GetContainerItem(container, slot)
        if not item or item.Id == 0 then return nil end
        local res = AshitaCore:GetResourceManager():GetItemById(item.Id)
        if not res or not res.Skill then return nil end
        return res.Skill
    end)
    if ok then return sid end
    return nil
end

local function get_combat_skill(sid)
    if not sid then return nil, nil end
    local ok, cur, rank = pcall(function()
        local pl = AshitaCore:GetMemoryManager():GetPlayer()
        local s = pl:GetCombatSkill(sid)
        if not s then return nil, nil end
        local raw_cur  = (type(s.GetSkill) == 'function') and s:GetSkill() or s.Skill
        local raw_rank = (type(s.GetRank)  == 'function') and s:GetRank()  or s.Rank
        return raw_cur, raw_rank
    end)
    if ok then return cur, rank end
    return nil, nil
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

-- Add tenths/10 to the running fractional. Wraps to 0 on >=1.0 overflow
-- (the integer tick will arrive from memory).
local function frac_add(sid, delta)
    local nv = (skill_frac[sid] or 0) + delta
    if nv >= 1.0 then nv = 0 end
    -- Round to 1 decimal place to keep the persisted Lua table tidy.
    nv = math.floor(nv * 10 + 0.5) / 10
    skill_frac[sid] = nv
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
    ['divine magic']=32, ['healing magic']=33, ['enhancing magic']=34,
    ['enfeebling magic']=35, ['elemental magic']=36, ['dark magic']=37,
    ['summoning magic']=38, ['ninjutsu']=39,
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
-- draw_arc: polyline-segment arc for the donut ring. AshitaImGui
-- doesn't expose PathArcTo, so we sample N points and emit AddLine
-- segments. N=48 gives smooth 360° rings at the radii we care about.
----------------------------------------------------------------
local function draw_arc(dl, cx, cy, r, a0, a1, color, thickness, segs)
    segs = segs or 48
    local span = a1 - a0
    local step = span / segs
    local prev_x = cx + r * math.cos(a0)
    local prev_y = cy + r * math.sin(a0)
    for i = 1, segs do
        local a = a0 + step * i
        local nx = cx + r * math.cos(a)
        local ny = cy + r * math.sin(a)
        dl:AddLine({ prev_x, prev_y }, { nx, ny }, color, thickness)
        prev_x, prev_y = nx, ny
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
local function skill_pill(sid, pct, color, label)
    local draw_pct, now = eased_pct(sid, pct)
    -- Scale only the width — pill height is fixed by font row.
    local sc = config.scale or 1.0
    local width, height = math.floor(SKILL_PILL_WIDTH * sc), SKILL_PILL_HEIGHT
    -- Never shrink narrower than the label needs — text stays readable at any scale.
    if label and label ~= '' then
        local tw0 = imgui.CalcTextSize(label) or 0
        local min_w = math.floor(tw0 + height + 8)
        if width < min_w then width = min_w end
    end

    local x0, y0 = imgui.GetCursorScreenPos()
    local p1 = { x0,         y0 }
    local p2 = { x0 + width, y0 + height }
    local dl = imgui.GetWindowDrawList()
    local rounding = height * 0.5

    -- Tick burst: expanding capsule outline that fades over 500ms.
    local burst_t = skill_tick_burst[sid]
    if burst_t then
        local bdt = now - burst_t
        if bdt < 0.5 then
            local bt = bdt / 0.5
            local bc = imgui.GetColorU32({ color[1], color[2], color[3], (1 - bt) * 0.7 })
            local pad = bt * 6
            dl:AddRect({ p1[1] - pad, p1[2] - pad },
                       { p2[1] + pad, p2[2] + pad }, bc, rounding + pad, 15, 2)
        else
            skill_tick_burst[sid] = nil
        end
    end

    -- Trough.
    local bg_col = imgui.GetColorU32({ 0.05, 0.05, 0.08, 0.86 })
    dl:AddRectFilled(p1, p2, bg_col, rounding, 15)

    -- Near-cap outer glow ramps in over the last 10% of fill.
    if draw_pct > 0.9 then
        local t = (draw_pct - 0.9) * 10
        local glow = imgui.GetColorU32({ color[1], color[2], color[3], t * 0.55 })
        dl:AddRect({ p1[1] - 2, p1[2] - 2 }, { p2[1] + 2, p2[2] + 2 },
                   glow, rounding + 2, 15, 2)
    end

    -- Colored fill body + top-half lighter overlay for glass feel.
    if draw_pct > 0.0 then
        local r, g, b = color[1], color[2], color[3]
        local a = color[4] or 1.0
        local fx2 = x0 + width * draw_pct
        dl:AddRectFilled(p1, { fx2, y0 + height },
                         imgui.GetColorU32({ r, g, b, a }), rounding, 15)
        local light = imgui.GetColorU32({
            math.min(1, r + 0.18),
            math.min(1, g + 0.18),
            math.min(1, b + 0.18), 0.32 })
        dl:AddRectFilled(p1, { fx2, y0 + math.floor(height * 0.5) },
                         light, rounding, 3)
    end

    -- Rim light + inner shadow.
    local rim_inset = rounding * 0.5
    local rim_col   = imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.20 })
    local sh_col    = imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.40 })
    dl:AddLine({ x0 + rim_inset,         y0 + 1 },
               { x0 + width - rim_inset, y0 + 1 }, rim_col, 1)
    dl:AddLine({ x0 + rim_inset,         y0 + height - 1 },
               { x0 + width - rim_inset, y0 + height - 1 }, sh_col, 1)

    -- Outer border.
    dl:AddRect(p1, p2, imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.15 }),
               rounding, 15, 1)

    if label and label ~= '' then
        local tw, th = imgui.CalcTextSize(label)
        tw = tw or 0; th = th or 0
        local tx = x0 + (width - tw) * 0.5
        local ty = y0 + (height - th) * 0.5
        local shadow = imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.85 })
        local white  = imgui.GetColorU32({ 1.0, 1.0, 1.0, 1.0 })
        dl:AddText({ tx + 1, ty + 1 }, shadow, label)
        dl:AddText({ tx,     ty     }, white,  label)
    end

    imgui.Dummy({ width, height })
end

----------------------------------------------------------------
-- skill_donut: radial gauge with OSRS-style interior.
--   - small dim rank letter near the top
--   - big bright effective level number centered
--   - caption: skill name / cur/cap / "Lv N+" or "cast" hint
----------------------------------------------------------------
local function skill_donut(sid, pct, color, label, cur_str, cap_str, letter, eff_lvl, min_mob_lvl, is_cast_gated)
    local draw_pct, now = eased_pct(sid, pct)

    local x0, y0 = imgui.GetCursorScreenPos()
    local sc     = config.scale or 1.0
    local r      = SKILL_DONUT_RADIUS * sc
    local cw     = math.max(SKILL_DONUT_CELL_W * sc, 2 * r + 16)
    -- Reserve a constant text block (font doesn't scale with sc).
    local text_block_h = 52
    local ch     = 2 * r + 8 + text_block_h
    local cx     = x0 + cw * 0.5
    local cy     = y0 + r + 4
    local dl     = imgui.GetWindowDrawList()

    -- Tick burst behind the donut.
    local burst_t = skill_tick_burst[sid]
    if burst_t then
        local bdt = now - burst_t
        if bdt < 0.5 then
            local s = 1 - bdt / 0.5
            local bc = imgui.GetColorU32({ color[1], color[2], color[3], 0.7 * s })
            local pad = bdt * 14
            dl:AddCircle({ cx, cy }, r + pad, bc, 32, 1.5)
        else
            skill_tick_burst[sid] = nil
        end
    end

    local thick  = SKILL_DONUT_THICK * sc
    -- Trough ring.
    local trough = imgui.GetColorU32({ 0.10, 0.11, 0.14, 0.92 })
    draw_arc(dl, cx, cy, r, 0, math.pi * 2, trough, thick, 48)

    -- Near-cap soft outer halo.
    if draw_pct > 0.9 then
        local s = (draw_pct - 0.9) * 10
        local halo = imgui.GetColorU32({ color[1], color[2], color[3], s * 0.45 })
        draw_arc(dl, cx, cy, r + 3 * sc, 0, math.pi * 2, halo, 2 * sc, 48)
    end

    -- Filled arc clockwise from 12 o'clock (-pi/2).
    if draw_pct > 0.01 then
        local a0 = -math.pi * 0.5
        local a1 = a0 + math.pi * 2 * draw_pct
        local fc = imgui.GetColorU32({ color[1], color[2], color[3], 0.98 })
        draw_arc(dl, cx, cy, r, a0, a1, fc, thick, 48)
    end

    local shadow = imgui.GetColorU32({ 0, 0, 0, 0.85 })
    local white  = imgui.GetColorU32({ 1, 1, 1, 1.0 })
    local dim    = imgui.GetColorU32({ 0.65, 0.68, 0.74, 1.0 })

    -- Rank letter near the top, dim accent.
    if letter and letter ~= '' then
        local lw, lh = imgui.CalcTextSize(letter)
        lw = lw or 0; lh = lh or 10
        local lx = cx - lw * 0.5
        local ly = cy - r * 0.45 - lh * 0.5
        local accent = imgui.GetColorU32({ 0.82, 0.85, 0.92, 0.85 })
        dl:AddText({ lx + 1, ly + 1 }, shadow, letter)
        dl:AddText({ lx,     ly     }, accent, letter)
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
    local cap_y = cy + r + 4
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
end

----------------------------------------------------------------
-- skill_crystal: FF-style 4-point diamond gem.
--   - Diamond outline (top/right/bottom/left) with X facet lines
--   - Fill rises from the bottom based on pct (clipped to diamond polygon)
--   - Small rank-letter pill above the gem
--   - Big effective level centered inside, name/cur/cap/hint below
----------------------------------------------------------------
local function skill_crystal(sid, pct, color, label, cur_str, cap_str, letter, eff_lvl, min_mob_lvl, is_cast_gated)
    local draw_pct, now = eased_pct(sid, pct)

    local x0, y0 = imgui.GetCursorScreenPos()
    local sc     = config.scale or 1.0
    local r      = SKILL_CRYSTAL_R * sc
    local hw     = SKILL_CRYSTAL_W * sc
    -- Width scales with the diamond, but stays wide enough for typical labels.
    local cw     = math.max(SKILL_CRYSTAL_CELL_W * sc, hw * 2 + 16)
    -- Height: pill band (16) + diamond (2r) + a fixed text block (font is
    -- not scaled by config.scale, so reserve a constant ~50px for 3 caption
    -- lines + bottom padding). This stops captions getting clipped when
    -- sc < 1.0.
    local text_block_h = 52
    local ch     = 16 + 2 * r + 6 + text_block_h
    local cx     = x0 + cw * 0.5
    -- Top band reserves space for the rank pill that sits atop the gem.
    local cy     = y0 + r + 16
    local dl     = imgui.GetWindowDrawList()

    -- Rank pill straddling the top vertex (so it visually integrates with
    -- the diamond like the old crystal look Blake's anchored on).
    if letter and letter ~= '' then
        local lw, lh = imgui.CalcTextSize(letter)
        lw = lw or 0; lh = lh or 10
        local pw = lw + 12
        local ph = lh + 4
        local px = cx - pw * 0.5
        -- Pill sits directly on top of the diamond's top vertex (touching).
        local py = (cy - r) - ph + 2
        local pillbg = imgui.GetColorU32({ 0.07, 0.08, 0.11, 0.95 })
        local pillb  = imgui.GetColorU32({ color[1], color[2], color[3], 0.95 })
        dl:AddRectFilled({ px, py }, { px + pw, py + ph }, pillbg, 3, 15)
        dl:AddRect({ px, py }, { px + pw, py + ph }, pillb, 3, 15, 1.6)
        local shadow = imgui.GetColorU32({ 0, 0, 0, 0.85 })
        local txtcol = imgui.GetColorU32({ 0.95, 0.97, 1.0, 1.0 })
        dl:AddText({ px + 6 + 1, py + 2 + 1 }, shadow, letter)
        dl:AddText({ px + 6,     py + 2     }, txtcol, letter)
    end

    -- 4-point diamond: top, right, bottom, left.
    local v = {
        { cx,      cy - r }, -- 1 top
        { cx + hw, cy     }, -- 2 right
        { cx,      cy + r }, -- 3 bottom
        { cx - hw, cy     }, -- 4 left
    }

    -- Tick burst: expanding diamond outline fading over 500ms.
    local burst_t = skill_tick_burst[sid]
    if burst_t then
        local bdt = now - burst_t
        if bdt < 0.5 then
            local s   = 1 - bdt / 0.5
            local bc  = imgui.GetColorU32({ color[1], color[2], color[3], 0.7 * s })
            local pad = bdt * 12
            for i = 1, 4 do
                local a = v[i]
                local b = v[(i % 4) + 1]
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

    -- Trough: dark diamond, fan from center.
    local trough = imgui.GetColorU32({ 0.06, 0.07, 0.10, 0.98 })
    for i = 1, 4 do
        dl:AddTriangleFilled({ cx, cy }, v[i], v[(i % 4) + 1], trough)
    end

    -- Fill rising from the bottom: clip diamond against horizontal line y=cap_y.
    if draw_pct > 0.01 then
        local cap_y = cy + r - (2 * r) * draw_pct
        local poly = {}
        for i = 1, 4 do
            local a = v[i]
            local b = v[(i % 4) + 1]
            local a_in = a[2] >= cap_y
            local b_in = b[2] >= cap_y
            if a_in then poly[#poly + 1] = a end
            if a_in ~= b_in then
                local dy = b[2] - a[2]
                if dy ~= 0 then
                    local t = (cap_y - a[2]) / dy
                    poly[#poly + 1] = { a[1] + t * (b[1] - a[1]), cap_y }
                end
            end
        end
        if #poly >= 3 then
            local fc = imgui.GetColorU32({ color[1], color[2], color[3], 1.0 })
            for i = 2, #poly - 1 do
                dl:AddTriangleFilled(poly[1], poly[i], poly[i + 1], fc)
            end
        end
    end

    -- Outline (brighter near cap).
    local outline_alpha = 0.95
    local outline = imgui.GetColorU32({
        color[1], color[2], color[3], outline_alpha })
    for i = 1, 4 do
        dl:AddLine(v[i], v[(i % 4) + 1], outline, 2.0)
    end

    -- Two small "facet dots" on the right edge to evoke a cut-gem highlight.
    local dotcol = imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.55 })
    dl:AddCircleFilled({ cx + hw * 0.55, cy - r * 0.18 }, 1.2, dotcol)
    dl:AddCircleFilled({ cx + hw * 0.30, cy + r * 0.10 }, 1.0, dotcol)

    local shadow = imgui.GetColorU32({ 0, 0, 0, 0.85 })
    local white  = imgui.GetColorU32({ 1, 1, 1, 1.0 })
    local dim    = imgui.GetColorU32({ 0.70, 0.74, 0.80, 1.0 })

    -- Big effective level centered inside the diamond.
    if eff_lvl then
        local s = tostring(eff_lvl)
        local nw, nh = imgui.CalcTextSize(s)
        nw = nw or 0; nh = nh or 12
        local nx = cx - nw * 0.5
        local ny = cy - nh * 0.5
        dl:AddText({ nx + 1, ny + 1 }, shadow, s)
        dl:AddText({ nx,     ny     }, white,  s)
    end

    -- Caption: name / cur/cap / hint, below the diamond.
    local cap_yt = cy + r + 4
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
end
-- isn't applicable (no rank for this job, already at cap and
-- show_capped is off, etc.).
----------------------------------------------------------------
local function prepare(sid, magic, job_id, mjl)
    if not sid then return nil end
    local cur, rank = get_combat_skill(sid)
    if not cur then return nil end

    -- Detect integer-tick rises for the burst halo + reset fractional.
    local last = skill_int_seen[sid]
    if last and cur > last then
        skill_tick_burst[sid] = os.clock()
        frac_reset(sid)
    end
    skill_int_seen[sid] = cur

    -- For magic skills, restrict to main-job ranks only. The engine reports
    -- ranks from sub-job too, which makes irrelevant rows (e.g. SMN/NIN on a
    -- non-summoner/ninja main) show up. Use the main-job table as the gate.
    if magic then
        local main_rank = rank_for_job_magic_skill(job_id, sid)
        if not main_rank then return nil end
        rank = main_rank
    elseif not rank then
        rank = rank_for_job_skill(job_id, sid)
    end
    if not rank then return nil end

    local cap     = skill_cap_for(rank, mjl)
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

    local is_cast_gated = SKILL_IS_CAST_GATED[sid] == true
    local min_mob_lvl   = nil
    if not is_cast_gated and cap and cur < cap then
        min_mob_lvl = min_mob_level_for(rank, cur)
    end

    local pct = (cap and cap > 0) and math.max(0, math.min(1, cur_eff / cap)) or 0
    return {
        sid           = sid,
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
local function render_pill_line(item)
    local hint = ''
    if item.cap then
        if item.is_cast_gated then
            hint = '  cast'
        elseif item.min_mob_lvl then
            hint = ('  Lv %d+'):format(item.min_mob_lvl)
        end
    end
    local line
    if item.cap and item.letter then
        line = ('%s  %s/%d (%s)%s%s'):format(
            item.label, item.cur_str, item.cap, item.letter, item.eff_str, hint)
    elseif item.cap then
        line = ('%s  %s/%d%s%s'):format(
            item.label, item.cur_str, item.cap, item.eff_str, hint)
    else
        line = ('%s  %s'):format(item.label, item.cur_str)
    end
    skill_pill(item.sid, item.pct, item.color, line)
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
    local mw_sid = get_main_weapon_skill_id()
    if mw_sid and not is_skill_hidden(mw_sid) then
        local mw_item = prepare(mw_sid, false, job_id, mjl)
        if mw_item then items:append(mw_item) end
    end
    for _, mid in ipairs(MAGIC_SKILL_IDS) do
        if not is_skill_hidden(mid) then
            local it = prepare(mid, true, job_id, mjl)
            if it then items:append(it) end
        end
    end

    local mode = config.display_mode

    -- Optional sort. Tie-break by SID for stable frame-to-frame order.
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
    end

    if mode == 'donuts' then
        local per_row = config.per_row
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
        local per_row = config.per_row
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
        imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 4, 1 })
        for _, item in ipairs(items) do render_pill_line(item) end
        imgui.PopStyleVar()
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
        -- SliderInt also wants a {int} ref table.
        local pr_max = math.max(1, last_item_count)
        if config.per_row > pr_max then
            config.per_row = pr_max; save()
        end
        local pr_ref = { config.per_row }
        imgui.PushItemWidth(160)
        if imgui.SliderInt('##sp_perrow', pr_ref, 1, pr_max) then
            config.per_row = math.max(1, math.min(pr_max, math.floor(pr_ref[1])))
            save()
        end
        imgui.PopItemWidth()
        imgui.SameLine()
        imgui.TextDisabled(('(%d of %d)'):format(config.per_row, pr_max))
        if imgui.SmallButton('1##sp_pr1') then config.per_row = 1; save() end
        imgui.SameLine()
        if imgui.SmallButton('2##sp_pr2') then config.per_row = math.min(2, pr_max); save() end
        imgui.SameLine()
        if imgui.SmallButton('3##sp_pr3') then config.per_row = math.min(3, pr_max); save() end
        imgui.SameLine()
        if imgui.SmallButton('All##sp_prall') then config.per_row = pr_max; save() end

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
                    if i < #CHAT_PALETTE then imgui.SameLine() end
                end
                imgui.SameLine()
                imgui.TextDisabled(('  %s (%d)'):format(selected_name, current))
            end
            color_row('0.1',  'chat_color_low')
            color_row('0.2',  'chat_color_mid')
            color_row('0.3+', 'chat_color_high')
            imgui.Unindent(16)
        end

        imgui.Separator()
        imgui.Text('Skills to show')
        -- Build a stable list: main weapon slot first (label "Weapon"), then
        -- the 8 magic skills in MAGIC_SKILL_IDS order. Each gets a checkbox.
        -- Per-skill state is stored in config.skills_hidden keyed by sid.
        local function skill_check(sid, label)
            local hidden = is_skill_hidden(sid)
            local r = { not hidden }
            if imgui.Checkbox(label .. '##sp_sk_' .. tostring(sid), r) then
                set_skill_hidden(sid, not r[1])
                save()
            end
        end
        -- Weapon row uses the equipped weapon's skill id (if any) so the
        -- checkbox label matches what you actually see.
        local mw_sid = get_main_weapon_skill_id()
        if mw_sid then
            skill_check(mw_sid, SKILL_NAMES[mw_sid] or ('Weapon#' .. mw_sid))
        end
        local col = 1
        for _, mid in ipairs(MAGIC_SKILL_IDS) do
            if mw_sid and col == 1 then imgui.SameLine() end
            skill_check(mid, SKILL_NAMES[mid] or ('Skill#' .. mid))
            col = col + 1
            if col >= 3 then col = 1 else imgui.SameLine() end
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

-- Read current integer skill from memory. Combat skills 1..47.
local function _cur_int_for_sid(sid)
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
        -- Bucket color by magnitude: 0.1 = low, 0.2 = mid, 0.3+ = high.
        local frac_color = config.chat_color_mid
        if value <= 1 then
            frac_color = config.chat_color_low
        elseif value >= 3 then
            frac_color = config.chat_color_high
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
            .. CC(6, 'level up')
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
        if sid and tenths and sid > 0 and sid < 48 then
            frac_add(sid, (tenths or 0) / 10)
            _skillup_pkt_at[sid] = os.clock()
            if config.chat_skillups then
                emit_skillup_chat(sid, 'frac', tenths)
                e.blocked = true
            end
        end
    elseif msgnum == 53 then
        local sid    = struct.unpack('L', e.data, 0x0C + 0x01)
        local newint = struct.unpack('L', e.data, 0x10 + 0x01)
        if sid and sid > 0 and sid < 48 then
            frac_reset(sid)
            _skillup_pkt_at[sid] = os.clock()
            if config.chat_skillups then
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
                end
            end
        end
    end
    -- When chat_skillups is on, suppress the game's default "skill rises / reaches"
    -- chat line so users see only the enhanced version. Same blocking pattern as
    -- skilluptracker uses to avoid double-printing. CRITICAL: do not block our
    -- own emitted lines (they carry the [prism] header), or the addon eats itself.
    if config.chat_skillups
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
            say('usage: /prism mode pills|donuts|crystals (current: ' .. config.display_mode .. ')')
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
        -- Diagnostic: emit one of each magnitude (0.1, 0.2, 0.3) plus a tick,
        -- so the user can see all three color buckets at once for tuning.
        local was = config.chat_skillups
        config.chat_skillups = true
        emit_skillup_chat(3, 'frac', 1)
        emit_skillup_chat(3, 'frac', 2)
        emit_skillup_chat(3, 'frac', 3)
        emit_skillup_chat(3, 'tick', 96)
        config.chat_skillups = was
        say('chattest: emitted 0.1/0.2/0.3 + tick samples (state preserved)')
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
                set_skill_hidden(hit, sub == 'hide')
                save()
                say(SKILL_NAMES[hit] .. ' ' .. (sub == 'hide' and 'HIDDEN' or 'SHOWN'))
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

