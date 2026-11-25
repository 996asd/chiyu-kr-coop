-- KR-MP Complete FL 4.1.0 Chinese Catalog: 100 Stages (KR5/KR3/KR2/KR1), 67 Heroes, 41 Towers
local catalog = {}

catalog.DEFAULT_TOWERS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }

catalog.STAGE_PACKS = {
    {
        id = "kr5",
        name = "5代·联盟 (30关)",
        stages = {
            { idx = 101, name = "树之海洋" },
            { idx = 102, name = "守卫之门" },
            { idx = 103, name = "森林之心" },
            { idx = 104, name = "翡翠树梢" },
            { idx = 105, name = "荒废郊区" },
            { idx = 106, name = "野兽巢穴" },
            { idx = 107, name = "冷峻山谷" },
            { idx = 108, name = "绯红矿坑" },
            { idx = 109, name = "邪恶路口" },
            { idx = 110, name = "神庙庭院" },
            { idx = 111, name = "峡谷高原" },
            { idx = 112, name = "枯萎农田" },
            { idx = 113, name = "亵渎神庙" },
            { idx = 114, name = "腐化山谷" },
            { idx = 115, name = "恶视魔塔" },
            { idx = 116, name = "欲念之巅" },
            { idx = 117, name = "迷雾废墟" },
            { idx = 118, name = "深叶哨所" },
            { idx = 119, name = "堕落神庙" },
            { idx = 120, name = "树灵村落" },
            { idx = 121, name = "沉没遗迹" },
            { idx = 122, name = "极饿凶谷" },
            { idx = 123, name = "暗钢之门" },
            { idx = 124, name = "狂热组装厂" },
            { idx = 125, name = "巨型核心" },
            { idx = 126, name = "克隆密室" },
            { idx = 127, name = "统治穹顶" },
            { idx = 128, name = "玷污神庙" },
            { idx = 129, name = "繁殖室" },
            { idx = 130, name = "遗忘王座" },
        },
    },
    {
        id = "kr3",
        name = "3代·起源 (22关)",
        stages = {
            { idx = 1,  name = "灰鸦港口" },
            { idx = 2,  name = "高桥" },
            { idx = 3,  name = "瀑布小径" },
            { idx = 4,  name = "红杉阻击战" },
            { idx = 5,  name = "皇家庭园" },
            { idx = 6,  name = "狮鹫驿站" },
            { idx = 7,  name = "石环阵" },
            { idx = 8,  name = "格林堡之战" },
            { idx = 9,  name = "水晶之湖" },
            { idx = 10, name = "奇迹仙境" },
            { idx = 11, name = "罪恶精灵王庭" },
            { idx = 12, name = "追本溯源" },
            { idx = 13, name = "奥术都市" },
            { idx = 14, name = "黑寡妇避难所" },
            { idx = 15, name = "艾纳妮神殿" },
            { idx = 16, name = "加拉里安之墙" },
            { idx = 17, name = "血石矿场" },
            { idx = 18, name = "歼灭者王座" },
            { idx = 19, name = "暮色森林岗哨" },
            { idx = 20, name = "都尔德郊原" },
            { idx = 21, name = "矮人国之门" },
            { idx = 22, name = "污染矿坑" },
        },
    },
    {
        id = "kr2",
        name = "2代·前线 (22关)",
        stages = {
            { idx = 23, name = "战锤要塞" },
            { idx = 24, name = "沙漠之鹰" },
            { idx = 25, name = "沙中绿洲" },
            { idx = 26, name = "绝望沙丘" },
            { idx = 27, name = "海盗老巢" },
            { idx = 28, name = "纳泽鲁之门" },
            { idx = 29, name = "猩红山谷" },
            { idx = 30, name = "断藤大桥" },
            { idx = 31, name = "失落丛林" },
            { idx = 32, name = "马克瓦尔可" },
            { idx = 33, name = "萨科拉神庙" },
            { idx = 34, name = "地下迷宫" },
            { idx = 35, name = "贝莱赛德的巢穴" },
            { idx = 36, name = "黑暗深处" },
            { idx = 37, name = "余烬尖刺深渊" },
            { idx = 38, name = "海龟港" },
            { idx = 39, name = "风暴环礁" },
            { idx = 40, name = "沉没城堡" },
            { idx = 41, name = "白骨镇" },
            { idx = 42, name = "亵渎树林" },
            { idx = 43, name = "沙尘高原" },
            { idx = 44, name = "暗光深渊" },
        },
    },
    {
        id = "kr1",
        name = "1代·初代 (26关)",
        stages = {
            { idx = 45, name = "南港" },
            { idx = 46, name = "郊原" },
            { idx = 47, name = "帕格拉斯" },
            { idx = 48, name = "双子河畔" },
            { idx = 49, name = "银橡森林" },
            { idx = 50, name = "城堡之战" },
            { idx = 51, name = "寒步矿场" },
            { idx = 52, name = "冰风隘口" },
            { idx = 53, name = "暴云寺院" },
            { idx = 54, name = "废弃之地" },
            { idx = 55, name = "凄凉山谷" },
            { idx = 56, name = "黑暗之塔" },
            { idx = 57, name = "萨雷格兹的巢穴" },
            { idx = 58, name = "阿卡洛斯遗迹" },
            { idx = 59, name = "腐朽森林" },
            { idx = 60, name = "寂静森林" },
            { idx = 61, name = "强盗的巢穴" },
            { idx = 62, name = "冰川高地" },
            { idx = 63, name = "哈克拉吉高原" },
            { idx = 64, name = "火焰之坑" },
            { idx = 65, name = "万魔殿" },
            { idx = 66, name = "真菌森林" },
            { idx = 67, name = "腐芯镇" },
            { idx = 68, name = "古代大墓地" },
            { idx = 69, name = "夜牙沼泽" },
            { idx = 70, name = "布莱克本城堡" },
        },
    },
}

catalog.HERO_PACKS = {
    {
        id = "h5",
        name = "5代英雄 (20)",
        heroes = {
            { idx = 48, name = "维斯珀" },
            { idx = 49, name = "蕾琳" },
            { idx = 50, name = "尼鲁" },
            { idx = 51, name = "格里姆森" },
            { idx = 52, name = "托雷斯" },
            { idx = 53, name = "战争巨头" },
            { idx = 54, name = "赛莉恩" },
            { idx = 55, name = "奥纳格罗" },
            { idx = 56, name = "卢米妮尔" },
            { idx = 57, name = "安雅" },
            { idx = 58, name = "科斯米尔" },
            { idx = 59, name = "布卢登" },
            { idx = 60, name = "波恩哈特(5)" },
            { idx = 61, name = "斯特蕾吉" },
            { idx = 62, name = "希尔瓦拉" },
            { idx = 63, name = "喀拉托" },
            { idx = 64, name = "丝派蒂尔" },
            { idx = 65, name = "艾斯酷特" },
            { idx = 66, name = "电云" },
            { idx = 67, name = "南瓜灯杰克" },
        },
    },
    {
        id = "h3",
        name = "3代英雄 (16)",
        heroes = {
            { idx = 1,  name = "艾莉丹" },
            { idx = 2,  name = "埃里汎" },
            { idx = 3,  name = "卡莎" },
            { idx = 4,  name = "雷格森" },
            { idx = 5,  name = "迪纳斯王子" },
            { idx = 6,  name = "瑞兹与大瑞格" },
            { idx = 7,  name = "无畏巴克" },
            { idx = 8,  name = "维兹南" },
            { idx = 9,  name = "鑫" },
            { idx = 10, name = "火凤凰" },
            { idx = 11, name = "杜拉斯" },
            { idx = 12, name = "莉恩" },
            { idx = 13, name = "布鲁斯" },
            { idx = 14, name = "莉莉斯" },
            { idx = 15, name = "威尔伯" },
            { idx = 16, name = "浮士德" },
        },
    },
    {
        id = "h2",
        name = "2代英雄 (16)",
        heroes = {
            { idx = 17, name = "阿尔里奇" },
            { idx = 18, name = "幻影" },
            { idx = 19, name = "黑棘船长" },
            { idx = 20, name = "克罗南" },
            { idx = 21, name = "女巫布鲁西" },
            { idx = 22, name = "纽维斯" },
            { idx = 23, name = "德得尔" },
            { idx = 24, name = "格劳尔" },
            { idx = 25, name = "沙塔" },
            { idx = 26, name = "阿什比特" },
            { idx = 27, name = "卡基诺斯" },
            { idx = 28, name = "库绍" },
            { idx = 29, name = "但丁" },
            { idx = 30, name = "波恩哈特(2)" },
            { idx = 31, name = "卡兹" },
            { idx = 32, name = "塞塔姆" },
        },
    },
    {
        id = "h1",
        name = "1代/改版 (15)",
        heroes = {
            { idx = 33, name = "杰拉尔德" },
            { idx = 34, name = "艾莉瑞雅" },
            { idx = 35, name = "马利克" },
            { idx = 36, name = "博林" },
            { idx = 37, name = "马格纳斯" },
            { idx = 38, name = "炎之魔神" },
            { idx = 39, name = "迪纳斯国王" },
            { idx = 40, name = "伊罗拉" },
            { idx = 41, name = "英格瓦" },
            { idx = 42, name = "钢锯" },
            { idx = 43, name = "鬼侍" },
            { idx = 44, name = "索尔" },
            { idx = 45, name = "天十" },
            { idx = 46, name = "毒蛇" },
            { idx = 47, name = "伏尔泰" },
        },
    },
}

catalog.TOWER_PACKS = {
    {
        id = "t5",
        name = "5代防御塔 (19座)",
        towers = {
            { idx = 1,  name = "圣骑士殿堂" },
            { idx = 2,  name = "皇家弓箭手" },
            { idx = 3,  name = "奥术法师" },
            { idx = 4,  name = "三管加农炮" },
            { idx = 5,  name = "树灵使者" },
            { idx = 6,  name = "恶魔熔坑" },
            { idx = 7,  name = "精灵观星者" },
            { idx = 8,  name = "火箭枪手" },
            { idx = 9,  name = "巨弩哨站" },
            { idx = 10, name = "死灵法师" },
            { idx = 11, name = "矮人喷火器" },
            { idx = 12, name = "沙丘哨兵" },
            { idx = 13, name = "幽冥战魂" },
            { idx = 14, name = "酿酒战匠" },
            { idx = 15, name = "诡术魔导师" },
            { idx = 16, name = "暮光长弓" },
            { idx = 17, name = "沼泽隐士" },
            { idx = 18, name = "炮兵小队" },
            { idx = 19, name = "电涌巨像" },
        },
    },
    {
        id = "t4",
        name = "4代防御塔 (22座)",
        towers = {
            { idx = 20, name = "精英骚扰者" },
            { idx = 21, name = "炙热宝石" },
            { idx = 22, name = "火光祭坛" },
            { idx = 23, name = "暗影弓手" },
            { idx = 24, name = "黑暗骑士" },
            { idx = 25, name = "炼狱法师" },
            { idx = 26, name = "熔炉" },
            { idx = 27, name = "哥布林回旋镖" },
            { idx = 28, name = "食人魔沉船" },
            { idx = 29, name = "幽灵墓" },
            { idx = 30, name = "腐朽森林" },
            { idx = 31, name = "少林寺" },
            { idx = 32, name = "沼泽巨人" },
            { idx = 33, name = "女巫姐妹花" },
            { idx = 34, name = "战争飞艇" },
            { idx = 35, name = "掷骨者" },
            { idx = 36, name = "兽人勇士巢穴" },
            { idx = 37, name = "兽人萨满" },
            { idx = 38, name = "火箭骑兵" },
            { idx = 39, name = "阴森墓地" },
            { idx = 40, name = "深渊恶魔之礁" },
            { idx = 41, name = "沙虫巢穴" },
        },
    },
}

-- Build fast lookup indexes
local STAGE_BY_IDX = {}
local STAGE_PACK_TAG = { kr5 = "5代", kr3 = "3代", kr2 = "2代", kr1 = "1代" }
for _, pack in ipairs(catalog.STAGE_PACKS) do
    local tag = STAGE_PACK_TAG[pack.id] or ""
    for _, st in ipairs(pack.stages) do
        STAGE_BY_IDX[st.idx] = { idx = st.idx, name = st.name, tag = tag, pack_id = pack.id }
    end
end

local HERO_BY_IDX = {}
for _, pack in ipairs(catalog.HERO_PACKS) do
    for _, h in ipairs(pack.heroes) do
        HERO_BY_IDX[h.idx] = h
    end
end

local TOWER_BY_IDX = {}
for _, pack in ipairs(catalog.TOWER_PACKS) do
    for _, t in ipairs(pack.towers) do
        TOWER_BY_IDX[t.idx] = t
    end
end

function catalog.get_stage_label(idx)
    local s = STAGE_BY_IDX[tonumber(idx) or 101]
    if s then
        return string.format("%s·第%d关 %s", s.tag, s.idx, s.name)
    end
    return "第 " .. tostring(idx) .. " 关"
end

function catalog.get_stage_short(idx)
    local s = STAGE_BY_IDX[tonumber(idx) or 101]
    if s then
        return string.format("%d %s", s.idx, s.name)
    end
    return "Lv." .. tostring(idx)
end

function catalog.get_hero_label(idx)
    local h = HERO_BY_IDX[tonumber(idx) or 48]
    if h then
        return h.name
    end
    return "英雄#" .. tostring(idx)
end

function catalog.get_tower_name(idx)
    local t = TOWER_BY_IDX[tonumber(idx) or 1]
    if t then
        return t.name
    end
    return "塔#" .. tostring(idx)
end

function catalog.format_tower_summary(towers)
    local list = (type(towers) == "table" and #towers > 0) and towers or catalog.DEFAULT_TOWERS
    local names = {}
    for i = 1, math.min(#list, 4) do
        names[#names + 1] = catalog.get_tower_name(list[i])
    end
    local suffix = (#list > 4) and string.format(" 等%d座", #list) or ""
    return table.concat(names, "、") .. suffix
end

return catalog
