-- KR-MP Complete FL 8.2.0 Chinese Catalog: 201 Stages (KR6/KR5/KR4/KR3/KR2/KR1), 105 Heroes, 59 Towers
local catalog = {}

catalog.FL_VERSION = "8.2.0"
catalog.DEFAULT_LEVEL = 101
catalog.DEFAULT_HERO_1 = 53 -- 维斯珀
catalog.DEFAULT_HERO_2 = 54 -- 蕾琳
catalog.MAX_TOWER_ID = 59
catalog.DEFAULT_TOWERS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }

catalog.STAGE_PACKS = {
    {
        id = "kr6",
        name = "6代·创世 (21关)",
        tag = "6代",
        stages = {
            { idx = 251, name = "利尼维亚城堡" },
            { idx = 252, name = "奥术魔法学院" },
            { idx = 253, name = "遭受入侵的农田" },
            { idx = 254, name = "西部防壁" },
            { idx = 255, name = "银橡村" },
            { idx = 256, name = "洛扎贡之塔" },
            { idx = 257, name = "三面伏击" },
            { idx = 258, name = "阿卡洛斯要塞" },
            { idx = 259, name = "险峻路途" },
            { idx = 260, name = "雪怪巢穴" },
            { idx = 261, name = "极冻深巢" },
            { idx = 262, name = "哈克拉吉村" },
            { idx = 263, name = "暴云寺院大堂" },
            { idx = 264, name = "光芯镇" },
            { idx = 265, name = "布莱克本城堡" },
            { idx = 266, name = "金色林地" },
            { idx = 267, name = "圣骑士圣域" },
            { idx = 268, name = "卫兹南之塔" },
            { idx = 269, name = "城堡近郊" },
            { idx = 270, name = "密林伏击" },
            { idx = 271, name = "强盗营寨" },
        },
    },
    {
        id = "kr5",
        name = "5代·联盟 (42关)",
        tag = "5代",
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
            { idx = 131, name = "仙界猴林" },
            { idx = 132, name = "炎龙洞穴" },
            { idx = 133, name = "怒风岛" },
            { idx = 134, name = "风暴之眼" },
            { idx = 135, name = "魔王堡垒" },
            { idx = 136, name = "巨龙之门" },
            { idx = 137, name = "守望者要塞" },
            { idx = 138, name = "核心圣所" },
            { idx = 139, name = "龙人繁衍地" },
            { idx = 140, name = "云国之冠" },
            { idx = 141, name = "巨龙之门改" },
            { idx = 142, name = "旧日极饿凶谷" },
        },
    },
    {
        id = "kr4",
        name = "4代·复仇 (52关)",
        tag = "4代",
        stages = {
            { idx = 150, name = "维兹南的塔" },
            { idx = 151, name = "矮人之门" },
            { idx = 152, name = "老城回廊" },
            { idx = 153, name = "卡赞矿区" },
            { idx = 154, name = "金色酿酒坊" },
            { idx = 155, name = "发条厂" },
            { idx = 156, name = "博古尔的王座" },
            { idx = 157, name = "北国人前哨战" },
            { idx = 158, name = "冰冻激流" },
            { idx = 159, name = "北国人村庄" },
            { idx = 160, name = "龙之埋骨场" },
            { idx = 161, name = "冰川飞龙巢" },
            { idx = 162, name = "欧蒂尔农田" },
            { idx = 163, name = "银橡前哨站" },
            { idx = 164, name = "洛扎贡之城" },
            { idx = 165, name = "逐光者营地" },
            { idx = 166, name = "迪纳斯城堡I" },
            { idx = 167, name = "玛吉尼西亚海岸" },
            { idx = 168, name = "阿努瑞人广场" },
            { idx = 169, name = "贤者池塘" },
            { idx = 170, name = "击破寒冰" },
            { idx = 171, name = "深入群山" },
            { idx = 172, name = "冰冻王座" },
            { idx = 173, name = "古代城门" },
            { idx = 174, name = "众河之城" },
            { idx = 175, name = "龙之力" },
            { idx = 176, name = "重返腐朽森林" },
            { idx = 177, name = "沼泽地里的一夜" },
            { idx = 178, name = "远古幽魂" },
            { idx = 179, name = "挖掘出口" },
            { idx = 180, name = "失落通道" },
            { idx = 181, name = "原始世界" },
            { idx = 182, name = "巫师登陆" },
            { idx = 183, name = "萨佩绿洲" },
            { idx = 184, name = "失落的帝国" },
            { idx = 185, name = "战锤要塞街道" },
            { idx = 186, name = "大竞技场" },
            { idx = 187, name = "海盗兄弟会" },
            { idx = 188, name = "猴岛" },
            { idx = 189, name = "群鲨环礁" },
            { idx = 190, name = "骸骨沉船湾" },
            { idx = 191, name = "金银岛" },
            { idx = 192, name = "迪纳斯城堡II" },
            { idx = 193, name = "击破寒冰改" },
            { idx = 194, name = "深入群山改" },
            { idx = 195, name = "冰冻王座改" },
            { idx = 196, name = "矮人港口" },
            { idx = 197, name = "秘银矿道" },
            { idx = 198, name = "熔岩山谷" },
            { idx = 199, name = "烈焰坟场" },
            { idx = 200, name = "恶魔祭坛" },
            { idx = 201, name = "黑之月" },
        },
    },
    {
        id = "kr3",
        name = "3代·起源 (23关)",
        tag = "3代",
        stages = {
            { idx = 1, name = "灰鸦港口" },
            { idx = 2, name = "高桥" },
            { idx = 3, name = "瀑布小径" },
            { idx = 4, name = "红杉阻击战" },
            { idx = 5, name = "皇家庭园" },
            { idx = 6, name = "狮鹫驿站" },
            { idx = 7, name = "石环阵" },
            { idx = 8, name = "格林堡之战" },
            { idx = 9, name = "水晶之湖" },
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
            { idx = 86, name = "失落庭园" },
        },
    },
    {
        id = "kr2",
        name = "2代·前线 (31关)",
        tag = "2代",
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
            { idx = 77, name = "无眠林冢" },
            { idx = 78, name = "林渊蛛巢" },
            { idx = 79, name = "风暴环礁之夜" },
            { idx = 80, name = "撼天墟谷" },
            { idx = 87, name = "诡异符文" },
            { idx = 88, name = "要塞往事" },
            { idx = 89, name = "泽拉福城墙" },
            { idx = 90, name = "要塞内城" },
            { idx = 91, name = "魔晶祭坛" },
        },
    },
    {
        id = "kr1",
        name = "1代·初代 (32关)",
        tag = "1代",
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
            { idx = 71, name = "重返腐朽森林" },
            { idx = 72, name = "沼泽地里的一夜" },
            { idx = 73, name = "洛扎贡城" },
            { idx = 74, name = "银白海岸" },
            { idx = 75, name = "诅咒沙滩" },
            { idx = 76, name = "冰河裂谷" },
        },
    },
}

catalog.HERO_PACKS = {
    {
        id = "h6",
        name = "6代·创世 (15)",
        heroes = {
            { idx = 91, name = "杰拉尔德", tpl = "hero_gerald_g6" },
            { idx = 92, name = "泽菲拉", tpl = "hero_zefira" },
            { idx = 93, name = "博林", tpl = "hero_bolin_g6" },
            { idx = 94, name = "康纳", tpl = "hero_connor" },
            { idx = 95, name = "杰米娜", tpl = "hero_myriath" },
            { idx = 96, name = "马利克", tpl = "hero_malik_g6" },
            { idx = 97, name = "罗德", tpl = "hero_rhodes" },
            { idx = 98, name = "阿什比特", tpl = "hero_ashbite" },
            { idx = 99, name = "德拉坎", tpl = "hero_drakkan" },
            { idx = 100, name = "伊格纳斯", tpl = "hero_ignus_g6" },
            { idx = 101, name = "鬼侍", tpl = "hero_oni_g6" },
            { idx = 102, name = "伊莉安娜", tpl = "hero_illiana" },
            { idx = 103, name = "奥赛尼尔", tpl = "hero_osnir" },
            { idx = 104, name = "达莉雅", tpl = "hero_princess" },
            { idx = 105, name = "静默猎手", tpl = "hero_silent" },
        },
    },
    {
        id = "h5",
        name = "5代·联盟 (20)",
        heroes = {
            { idx = 53, name = "维斯珀", tpl = "hero_vesper" },
            { idx = 54, name = "蕾琳", tpl = "hero_raelyn" },
            { idx = 55, name = "尼鲁", tpl = "hero_muyrn" },
            { idx = 56, name = "格里姆森", tpl = "hero_venom" },
            { idx = 57, name = "托雷斯", tpl = "hero_builder" },
            { idx = 58, name = "战争巨头", tpl = "hero_robot" },
            { idx = 59, name = "赛莉恩", tpl = "hero_space_elf" },
            { idx = 60, name = "奥纳格罗", tpl = "hero_mecha" },
            { idx = 61, name = "卢米妮尔", tpl = "hero_lumenir" },
            { idx = 62, name = "安雅", tpl = "hero_hunter" },
            { idx = 63, name = "科斯米尔", tpl = "hero_dragon_gem" },
            { idx = 64, name = "布卢登", tpl = "hero_bird" },
            { idx = 65, name = "波恩哈特", tpl = "hero_dragon_bone" },
            { idx = 66, name = "斯特蕾吉", tpl = "hero_witch" },
            { idx = 67, name = "希尔瓦拉", tpl = "hero_dragon_arb" },
            { idx = 68, name = "喀拉托", tpl = "hero_lava" },
            { idx = 69, name = "丝派蒂尔", tpl = "hero_spider" },
            { idx = 70, name = "孙悟空", tpl = "hero_wukong" },
            { idx = 71, name = "斗战胜佛", tpl = "hero_douzhanshengfo" },
            { idx = 72, name = "奥利昂", tpl = "hero_dragon_sun" },
        },
    },
    {
        id = "h4",
        name = "4代·复仇 (18)",
        heroes = {
            { idx = 73, name = "维鲁克", tpl = "hero_orc" },
            { idx = 74, name = "阿斯拉", tpl = "hero_asra" },
            { idx = 75, name = "奥洛克", tpl = "hero_oloch" },
            { idx = 76, name = "特拉敏", tpl = "hero_tramin" },
            { idx = 77, name = "极狗", tpl = "hero_jigou" },
            { idx = 78, name = "苦楝夫人", tpl = "hero_margosa" },
            { idx = 79, name = "墨忒弥斯", tpl = "hero_mortemis" },
            { idx = 80, name = "毁灭坦克", tpl = "hero_tank" },
            { idx = 81, name = "贝雷萨德", tpl = "hero_beresad" },
            { idx = 82, name = "浚湃", tpl = "hero_naga" },
            { idx = 83, name = "墨尔古伦", tpl = "hero_murglun" },
            { idx = 84, name = "艾斯酷特", tpl = "hero_eiskalt" },
            { idx = 85, name = "电云", tpl = "hero_dianyun" },
            { idx = 86, name = "南瓜灯杰克", tpl = "hero_jack_o_lantern" },
            { idx = 87, name = "格罗什", tpl = "hero_mammoth" },
            { idx = 88, name = "伊斯菲特", tpl = "hero_isfet" },
            { idx = 89, name = "卢塞尔娜", tpl = "hero_lucerna" },
            { idx = 90, name = "特拉敏七号", tpl = "hero_tramin_seventh" },
        },
    },
    {
        id = "hr",
        name = "重生原创 (5)",
        heroes = {
            { idx = 48, name = "荆刃奥伯龙", tpl = "hero_oberon" },
            { idx = 49, name = "余烬", tpl = "hero_ember" },
            { idx = 50, name = "龙影半影", tpl = "hero_penumbra" },
            { idx = 51, name = "泽兹特拉", tpl = "hero_zezitra" },
            { idx = 52, name = "神枪手强尼", tpl = "hero_deadeye" },
        },
    },
    {
        id = "h3",
        name = "3代·起源 (16)",
        heroes = {
            { idx = 1, name = "艾莉丹", tpl = "hero_elves_archer" },
            { idx = 2, name = "埃里汎", tpl = "hero_arivan" },
            { idx = 3, name = "卡莎", tpl = "hero_catha" },
            { idx = 4, name = "雷格森", tpl = "hero_regson" },
            { idx = 5, name = "迪纳斯王子", tpl = "hero_elves_denas" },
            { idx = 6, name = "瑞兹与大瑞格", tpl = "hero_rag" },
            { idx = 7, name = "无畏巴克", tpl = "hero_bravebark" },
            { idx = 8, name = "维兹南", tpl = "hero_veznan" },
            { idx = 9, name = "鑫", tpl = "hero_xin" },
            { idx = 10, name = "火凤凰", tpl = "hero_phoenix" },
            { idx = 11, name = "杜拉斯", tpl = "hero_durax" },
            { idx = 12, name = "莉恩", tpl = "hero_lynn" },
            { idx = 13, name = "布鲁斯", tpl = "hero_bruce" },
            { idx = 14, name = "莉莉斯", tpl = "hero_lilith" },
            { idx = 15, name = "威尔伯", tpl = "hero_wilbur" },
            { idx = 16, name = "浮士德", tpl = "hero_faustus" },
        },
    },
    {
        id = "h2",
        name = "2代·前线 (16)",
        heroes = {
            { idx = 17, name = "阿尔里奇", tpl = "hero_alric" },
            { idx = 18, name = "幻影", tpl = "hero_mirage" },
            { idx = 19, name = "黑棘船长", tpl = "hero_pirate" },
            { idx = 20, name = "克罗南", tpl = "hero_beastmaster" },
            { idx = 21, name = "女巫布鲁西", tpl = "hero_voodoo_witch" },
            { idx = 22, name = "纽维斯", tpl = "hero_wizard" },
            { idx = 23, name = "德得尔", tpl = "hero_priest" },
            { idx = 24, name = "格劳尔", tpl = "hero_giant" },
            { idx = 25, name = "沙塔", tpl = "hero_alien" },
            { idx = 26, name = "阿什比特", tpl = "hero_dragon" },
            { idx = 27, name = "卡基诺斯", tpl = "hero_crab" },
            { idx = 28, name = "库绍", tpl = "hero_monk" },
            { idx = 29, name = "但丁", tpl = "hero_van_helsing" },
            { idx = 30, name = "波恩哈特", tpl = "hero_dracolich" },
            { idx = 31, name = "卡兹", tpl = "hero_minotaur" },
            { idx = 32, name = "塞塔姆", tpl = "hero_monkey_god" },
        },
    },
    {
        id = "h1",
        name = "1代·初代 (15)",
        heroes = {
            { idx = 33, name = "杰拉尔德", tpl = "hero_gerald" },
            { idx = 34, name = "艾莉瑞雅", tpl = "hero_alleria" },
            { idx = 35, name = "马利克", tpl = "hero_malik" },
            { idx = 36, name = "博林", tpl = "hero_bolin" },
            { idx = 37, name = "马格纳斯", tpl = "hero_magnus" },
            { idx = 38, name = "炎之魔神", tpl = "hero_ignus" },
            { idx = 39, name = "迪纳斯国王", tpl = "hero_denas" },
            { idx = 40, name = "伊罗拉", tpl = "hero_elora" },
            { idx = 41, name = "英格瓦", tpl = "hero_ingvar" },
            { idx = 42, name = "钢锯", tpl = "hero_hacksaw" },
            { idx = 43, name = "鬼侍", tpl = "hero_oni" },
            { idx = 44, name = "索尔", tpl = "hero_thor" },
            { idx = 45, name = "天十", tpl = "hero_10yr" },
            { idx = 46, name = "毒蛇", tpl = "hero_viper" },
            { idx = 47, name = "伏尔泰", tpl = "hero_voltaire" },
        },
    },
}

catalog.TOWER_PACKS = {
    {
        id = "t6",
        name = "6代·创世 (16座)",
        towers = {
            { idx = 44, name = "弓兵要塞", tpl = "archers" },
            { idx = 45, name = "守卫骑士团", tpl = "knights" },
            { idx = 46, name = "魔典学者", tpl = "wizard" },
            { idx = 47, name = "皇家投石机", tpl = "catapult" },
            { idx = 48, name = "精灵精英游侠", tpl = "ranger" },
            { idx = 49, name = "矮人扩散炮", tpl = "culverine" },
            { idx = 50, name = "日耀大师", tpl = "sunray_master" },
            { idx = 51, name = "光明女祭司", tpl = "light_priestess" },
            { idx = 52, name = "铁木树精", tpl = "tree" },
            { idx = 53, name = "野猫女猎手", tpl = "wildcat" },
            { idx = 54, name = "炼金术士小屋", tpl = "alchemist" },
            { idx = 55, name = "奥术幻铸师", tpl = "forger" },
            { idx = 56, name = "诅咒弩手", tpl = "crossbows" },
            { idx = 57, name = "淘金矮人", tpl = "miners" },
            { idx = 58, name = "哨兵瞭望塔", tpl = "sniper" },
            { idx = 59, name = "猫头鹰骑兵", tpl = "owl" },
        },
    },
    {
        id = "t5",
        name = "5代·联盟 (21座)",
        towers = {
            { idx = 1, name = "圣骑士殿堂", tpl = "paladin_covenant" },
            { idx = 2, name = "皇家弓箭手", tpl = "royal_archers" },
            { idx = 3, name = "奥术法师", tpl = "arcane_wizard" },
            { idx = 4, name = "三管加农炮", tpl = "tricannon" },
            { idx = 5, name = "树灵使者", tpl = "arborean_emissary" },
            { idx = 6, name = "恶魔熔坑", tpl = "demon_pit" },
            { idx = 7, name = "精灵观星者", tpl = "elven_stargazers" },
            { idx = 8, name = "火箭枪手", tpl = "rocket_gunners" },
            { idx = 9, name = "巨弩哨站", tpl = "ballista" },
            { idx = 10, name = "死灵法师", tpl = "necromancer" },
            { idx = 11, name = "矮人喷火器", tpl = "flamespitter" },
            { idx = 12, name = "沙丘哨兵", tpl = "sand" },
            { idx = 13, name = "幽冥战魂", tpl = "ghost" },
            { idx = 14, name = "酿酒战匠", tpl = "barrel" },
            { idx = 15, name = "诡术魔导师", tpl = "ray" },
            { idx = 16, name = "暮光长弓", tpl = "dark_elf" },
            { idx = 17, name = "沼泽隐士", tpl = "hermit_toad" },
            { idx = 18, name = "炮兵小队", tpl = "dwarf" },
            { idx = 19, name = "电涌巨像", tpl = "sparking_geode" },
            { idx = 20, name = "竹宗三侠", tpl = "pandas" },
            { idx = 21, name = "龙之孵育所", tpl = "dragons" },
        },
    },
    {
        id = "t4",
        name = "4代·复仇 (22座)",
        towers = {
            { idx = 22, name = "精英骚扰者", tpl = "twilight_elves_barrack" },
            { idx = 23, name = "炙热宝石", tpl = "blazing_watcher" },
            { idx = 24, name = "火光祭坛", tpl = "ignis_altar" },
            { idx = 25, name = "暗影弓手", tpl = "shadow_archer" },
            { idx = 26, name = "黑暗骑士", tpl = "dark_knights" },
            { idx = 27, name = "炼狱法师", tpl = "infernal_mage" },
            { idx = 28, name = "熔炉", tpl = "melting_furnace" },
            { idx = 29, name = "哥布林回旋镖", tpl = "goblirang" },
            { idx = 30, name = "食人魔沉船", tpl = "ogre_shipwreck" },
            { idx = 31, name = "幽灵墓", tpl = "spirit_mausoleum" },
            { idx = 32, name = "腐朽森林", tpl = "rotten_forest" },
            { idx = 33, name = "少林寺", tpl = "shaolin" },
            { idx = 34, name = "沼泽巨人", tpl = "swamp_monster" },
            { idx = 35, name = "女巫姐妹花", tpl = "wicked_sisters" },
            { idx = 36, name = "战争飞艇", tpl = "balloon" },
            { idx = 37, name = "掷骨者", tpl = "bone_flingers" },
            { idx = 38, name = "兽人勇士巢穴", tpl = "orc_warriors_den" },
            { idx = 39, name = "兽人萨满", tpl = "orc_shaman" },
            { idx = 40, name = "火箭骑兵", tpl = "rocket_riders" },
            { idx = 41, name = "阴森墓地", tpl = "grim_cemetery" },
            { idx = 42, name = "深渊恶魔之礁", tpl = "deep_devils" },
            { idx = 43, name = "沙虫巢穴", tpl = "sandworm" },
        },
    },
}

-- Build fast lookup indexes
local STAGE_BY_IDX = {}
local TOTAL_STAGES = 0
for _, pack in ipairs(catalog.STAGE_PACKS) do
    local tag = pack.tag or ""
    for _, st in ipairs(pack.stages) do
        STAGE_BY_IDX[st.idx] = { idx = st.idx, name = st.name, tag = tag, pack_id = pack.id }
        TOTAL_STAGES = TOTAL_STAGES + 1
    end
end
catalog.TOTAL_STAGES = TOTAL_STAGES

local HERO_BY_IDX = {}
local TOTAL_HEROES = 0
for _, pack in ipairs(catalog.HERO_PACKS) do
    for _, h in ipairs(pack.heroes) do
        HERO_BY_IDX[h.idx] = h
        TOTAL_HEROES = TOTAL_HEROES + 1
    end
end
catalog.TOTAL_HEROES = TOTAL_HEROES

local TOWER_BY_IDX = {}
local TOTAL_TOWERS = 0
for _, pack in ipairs(catalog.TOWER_PACKS) do
    for _, t in ipairs(pack.towers) do
        TOWER_BY_IDX[t.idx] = t
        TOTAL_TOWERS = TOTAL_TOWERS + 1
    end
end
catalog.TOTAL_TOWERS = TOTAL_TOWERS

function catalog.get_stage_info(idx)
    return STAGE_BY_IDX[tonumber(idx) or catalog.DEFAULT_LEVEL]
end

function catalog.get_stage_label(idx)
    local s = STAGE_BY_IDX[tonumber(idx) or catalog.DEFAULT_LEVEL]
    if s then
        return string.format("%s·第%d关 %s", s.tag, s.idx, s.name)
    end
    return "第 " .. tostring(idx) .. " 关"
end

function catalog.get_stage_short(idx)
    local s = STAGE_BY_IDX[tonumber(idx) or catalog.DEFAULT_LEVEL]
    if s then
        return string.format("%d %s", s.idx, s.name)
    end
    return "Lv." .. tostring(idx)
end

function catalog.get_hero_info(idx)
    return HERO_BY_IDX[tonumber(idx) or catalog.DEFAULT_HERO_1]
end

function catalog.get_hero_label(idx)
    local h = HERO_BY_IDX[tonumber(idx) or catalog.DEFAULT_HERO_1]
    if h then
        return h.name
    end
    return "英雄#" .. tostring(idx)
end

function catalog.get_tower_info(idx)
    return TOWER_BY_IDX[tonumber(idx) or 1]
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
