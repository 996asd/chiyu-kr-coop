-- Deterministic 32-bit FNV-1a State Checksum (every 30 ticks)
-- Produces compact hex checksum + diagnostics to locate first diverging tick/field.
local bit = require("bit")
local bxor = bit.bxor
local band = bit.band
local rshift = bit.rshift
local tobit = bit.tobit

local state_hash = {}

local FNV_OFFSET = tobit(0x811c9dc5)
local FNV_PRIME = tobit(0x01000193)

local function imul32(a, b)
    a = tobit(a)
    b = tobit(b)
    local ah = rshift(a, 16)
    local al = band(a, 0xffff)
    local bh = rshift(b, 16)
    local bl = band(b, 0xffff)
    return tobit(al * bl + band(ah * bl + al * bh, 0xffff) * 65536)
end

local function fnv_u8(h, byte_val)
    return imul32(bxor(h, band(byte_val, 0xff)), FNV_PRIME)
end

local function fnv_int(h, n)
    local v = tobit(math.floor((n or 0) + 0.5))
    h = fnv_u8(h, band(v, 0xff))
    h = fnv_u8(h, band(rshift(v, 8), 0xff))
    h = fnv_u8(h, band(rshift(v, 16), 0xff))
    h = fnv_u8(h, band(rshift(v, 24), 0xff))
    return h
end

local function fnv_str(h, s)
    if not s then return fnv_u8(h, 0) end
    for i = 1, #s do
        h = fnv_u8(h, string.byte(s, i))
    end
    return fnv_u8(h, 0xff)
end

local function q100(v)
    if not v or v ~= v then return 0 end
    return math.floor(v * 100 + 0.5)
end

local function to_hex32(h)
    local u = tobit(h)
    if u < 0 then u = u + 4294967296 end
    return string.format("%08X", u)
end

local LOCAL_ID_BASE = 100000000

function state_hash.compute(store, prng, coop)
    local h = FNV_OFFSET
    local tick = store.tick or 0
    local gold = math.floor((store.player_gold or 0) + 0.5)
    local lives = store.lives or 0
    local wave = store.wave_group_number or 0
    local rng_calls = prng and prng:get_sim_calls() or 0
    local rng_state = prng and prng:get_sim_state_u32() or 0
    local g1, g2 = nil, nil
    if coop and coop:is_active() then
        g1 = coop:get_player_gold(1)
        g2 = coop:get_player_gold(2)
        gold = coop:get_canonical_gold()
    end

    local sim_ent_count = 0
    local ids = {}
    local n = 0
    for id, e in pairs(store.entities) do
        if type(id) == "number" and e and not e._kr_mp_local and id < LOCAL_ID_BASE then
            local is_combat = e.enemy or e.soldier or e.hero or e.tower or e.bullet or e.modifier or e.health
            -- In FL 8.2.0, particle_system ticks inside render-rate prepare_render() with visual PRNG lifetimes,
            -- so pure visual emitters (no combat components) may expire on slightly different ticks without affecting sim.
            if is_combat or not e.particle_system then
                sim_ent_count = sim_ent_count + 1
            end
            if is_combat then
                n = n + 1
                ids[n] = id
            end
        end
    end
    table.sort(ids)

    h = fnv_int(h, tick)
    h = fnv_int(h, gold)
    if g1 ~= nil then
        h = fnv_int(h, g1)
        h = fnv_int(h, g2)
    end
    h = fnv_int(h, lives)
    h = fnv_int(h, wave)
    h = fnv_int(h, sim_ent_count)
    h = fnv_int(h, rng_calls)
    h = fnv_int(h, rng_state)

    local enemy_cnt, soldier_cnt, tower_cnt, bullet_cnt, hero_cnt = 0, 0, 0, 0, 0
    local hp_sum = 0

    for i = 1, n do
        local id = ids[i]
        local e = store.entities[id]
        h = fnv_int(h, id)
        h = fnv_str(h, e.template_name)

        if e.pos then
            h = fnv_int(h, q100(e.pos.x))
            h = fnv_int(h, q100(e.pos.y))
        end
        if e.health then
            local hp_q = q100(e.health.hp)
            hp_sum = hp_sum + hp_q
            h = fnv_int(h, hp_q)
            h = fnv_u8(h, e.health.dead and 1 or 0)
        end
        if e.nav_path then
            h = fnv_int(h, e.nav_path.pi or 0)
            h = fnv_int(h, e.nav_path.spi or 0)
            h = fnv_int(h, e.nav_path.ni or 0)
        end
        if e.tower then
            tower_cnt = tower_cnt + 1
            h = fnv_int(h, e.tower.spent or 0)
            if e._mp_owner then
                h = fnv_u8(h, e._mp_owner)
            end
            if e.tower.holder_id then
                h = fnv_str(h, tostring(e.tower.holder_id))
            end
        end
        if e.hero then
            hero_cnt = hero_cnt + 1
            h = fnv_int(h, e.hero.xp or 0)
            h = fnv_int(h, e.hero.level or 0)
        end
        if e.enemy then enemy_cnt = enemy_cnt + 1 end
        if e.soldier then soldier_cnt = soldier_cnt + 1 end
        if e.bullet then bullet_cnt = bullet_cnt + 1 end
    end

    return {
        tick = tick,
        hash = to_hex32(h),
        gold = gold,
        lives = lives,
        wave = wave,
        ents = sim_ent_count,
        tracked = n,
        enemies = enemy_cnt,
        soldiers = soldier_cnt,
        towers = tower_cnt,
        bullets = bullet_cnt,
        heroes = hero_cnt,
        hp_sum = hp_sum,
        rng = rng_calls,
        rng_s = string.format("%08X", rng_state),
    }
end

function state_hash.format_line(snap)
    return string.format(
        "tick=%d hash=%s gold=%d lives=%d wave=%d ents=%d tracked=%d E=%d S=%d T=%d B=%d H=%d hp=%d rng=%d rng_s=%s",
        snap.tick, snap.hash, snap.gold, snap.lives, snap.wave,
        snap.ents, snap.tracked, snap.enemies, snap.soldiers, snap.towers,
        snap.bullets, snap.heroes, snap.hp_sum, snap.rng, snap.rng_s
    )
end

return state_hash
