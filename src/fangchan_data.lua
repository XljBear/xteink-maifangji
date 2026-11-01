-- 买房记：商品、房源、随机事件、彩票、难度 —— 这个游戏的全部"内容"。
--
-- 这个文件只有数据，没有玩法（玩法在 fangchan_game.lua，界面在 ui.lua）。想改数值、加商品、
-- 加新闻、调彩票中奖率，改这里就够了。
--
-- 仓库不限制数量：想囤多少囤多少，唯一的约束是手上有没有钱。
--
-- base: 基准价，价格长期围绕它波动
-- vol:  每回合波动幅度，0.35 表示一回合最多涨跌约 35%

local Data = {}

Data.START_CASH = 2000      -- 开局手上的钱
Data.MAX_ROUNDS = 60        -- 一共 60 个回合
Data.PULL = 0.14            -- 每回合价格向基准价回归的比例（越大，涨跌来回得越快）
Data.FLOOR = 0.35           -- 价格下限：基准价的 35%
Data.CEIL = 2.60            -- 价格上限：基准价的 260%
Data.EVENT_CHANCE = 0.40    -- 每回合发生一条新闻的概率

Data.money_fmt = '¥%1'      -- 金额的样子：¥12,345（%1 换成数字）

-- 难度只改"你能看到多少信息"，不改钱、不改价格：
--   show_base 显示每种货的基准价；show_tip 显示眼下是便宜还是贵
Data.DIFFICULTY = {
  { name = '简单', show_base = true,  show_tip = true,
    desc = '看得到每种货的基准价，还提醒你眼下是便宜还是贵。' },
  { name = '普通', show_base = false, show_tip = false,
    desc = '不告诉你基准价，也不提示便宜还是贵，全靠自己记行情。' },
}

-- 单价从几十到一万二：钱少的时候只能玩便宜的，钱多了才碰得上黄金
Data.GOODS = {
  { name = '白菜', base = 30,   vol = 0.35 },
  { name = '大米', base = 60,   vol = 0.22 },
  { name = '棉布', base = 250,  vol = 0.24 },
  { name = '煤炭', base = 300,  vol = 0.26 },
  { name = '钢材', base = 800,  vol = 0.22 },
  { name = '手机', base = 1800, vol = 0.18 },
  { name = '白酒', base = 2600, vol = 0.20 },
  { name = '黄金', base = 12000, vol = 0.28 },
}

-- 房子：五个档位，买得起哪一档，结局就是哪一档的评价。
-- price 越高越难，置换时旧房按原价抵扣。
Data.HOUSES = {
  { name = '城中村单间', price = 15000,   rank = '总算有个窝' },
  { name = '老破小两居', price = 50000,   rank = '小有余粮' },
  { name = '学区三居',   price = 150000,  rank = '安居乐业' },
  { name = '江景大平层', price = 450000,  rank = '人生赢家' },
  { name = '独栋别墅',   price = 1200000, rank = '财富自由' },
}

Data.NO_HOUSE_RANK = '还在租房'

------------------------------------------------------------------ 过日子的开销

-- 光躺着不动是要花钱的：每一回合结束，先从你兜里掏一笔。
-- 两样加起来：生活费（越往后越贵，物价在涨）+ 仓储费（货堆在仓库里是要交钱的）。
-- 掏不出来不会把你卡死，欠着 —— 欠的钱记在账上，下一回合一有钱先还。
Data.UPKEEP = {
  living_base = 80,       -- 第 1 回合的生活费
  living_step = 3,        -- 每往后一个回合，生活费涨这么多（60 回合时是 257）
  store_rate = 0.005,     -- 仓储费：一件货一回合按其基准价的比例收
  store_min = 0,          -- 最便宜的货（白菜、大米）算下来不到一块，就不收了
}

Data.DEBT_RANK = '欠了一屁股债'

------------------------------------------------------------------ 彩票站

-- 只有一种玩法：六格刮刮乐。一张 ¥200，每回合最多 3 张。
--
-- 买来是一张盖着涂层的卡，六个格子自己点开，一格一格揭。
-- 每一格独立抽奖：多数刮出来是张笑脸（没钱），偶尔蹦出一个金额。
-- 六格全刮完，把格子里的金额加起来，就是这一张中的钱。
--
-- 另外每张票都往"本期奖池"里注 ¥10，并有一次机会（1/150）独得整个池子。
-- 整体返奖九成：图的是刮的那几下和那一把大奖，不是理财。
Data.LOTTERY = {
  price = 200,
  per_round = 3,
  cells = 6,              -- 一张卡六个格子

  pool_start = 500,       -- 开局奖池里先放着这么多
  pool_in = 10,           -- 每张票往奖池里注这么多
  pool_chance = 150,      -- 每张票多大机会独得奖池：1/150

  -- 每一格刮出来的东西。amount 为 0 就是一张笑脸，什么也没有。
  -- w 是权重：大约三分之二的格子是笑脸，六格全空的一万张里八百多张。
  CELL_PRIZES = {
    { w = 640, amount = 0 },
    { w = 90,  amount = 20 },
    { w = 80,  amount = 30 },
    { w = 70,  amount = 50 },
    { w = 50,  amount = 100 },
    { w = 25,  amount = 200 },
    { w = 6,   amount = 500 },
    { w = 2,   amount = 1500 },
    { w = 1,   amount = 5000 },
  },
}

------------------------------------------------------------------ 随机事件

-- kind 决定它怎么影响局面，由 fangchan_game.lua 执行：
--   good            某一种商品（target 写商品名，不写就随机）价格乘以 lo..hi
--   all             所有商品价格乘以 lo..hi
--   cash            直接给一笔钱 lo..hi
--   cash_rate       按现有现金的比例给钱
--   cash_rate_sub   按现有现金的比例扣钱
--   lose_goods      随机一种在手的货损失 lo..hi 的比例
--   free_goods      白得 lo..hi 件货（target 写商品名，不写就随机）
--   free_lotto      白得一张刮刮乐（不花钱、不占本回合的名额）
--   none            只是说句话，什么也不影响
-- w 是权重，越大越常见。
Data.EVENTS = {
  -- 单种商品：涨
  { w = 6, text = '台风登陆，蔬菜减产，菜价飞涨。', kind = 'good', target = '白菜', lo = 1.6, hi = 2.4 },
  { w = 6, text = '煤矿安全大检查，煤炭供应收紧。', kind = 'good', target = '煤炭', lo = 1.5, hi = 2.0 },
  { w = 6, text = '邻国禁止粮食出口，米价一路走高。', kind = 'good', target = '大米', lo = 1.5, hi = 2.1 },
  { w = 5, text = '国际局势紧张，金价一路暴涨。', kind = 'good', target = '黄金', lo = 1.4, hi = 1.9 },
  { w = 5, text = '基建全面开工，钢材抢手。', kind = 'good', target = '钢材', lo = 1.4, hi = 1.8 },
  { w = 4, text = '新机发布会一机难求，黄牛把手机炒起来了。', kind = 'good', target = '手机', lo = 1.3, hi = 1.7 },
  { w = 4, text = '军需订单追加，棉布一夜之间被清空。', kind = 'good', target = '棉布', lo = 1.4, hi = 1.8 },
  { w = 4, text = '老酒拍卖创下纪录，白酒跟着往上蹿。', kind = 'good', target = '白酒', lo = 1.3, hi = 1.7 },
  { w = 3, text = '寒潮提前南下，取暖用煤需求暴增。', kind = 'good', target = '煤炭', lo = 1.3, hi = 1.6 },
  { w = 3, text = '产区遭遇虫害，大米供应告急。', kind = 'good', target = '大米', lo = 1.4, hi = 1.8 },

  -- 单种商品：跌
  { w = 6, text = '风调雨顺，粮食大丰收。', kind = 'good', target = '大米', lo = 0.45, hi = 0.70 },
  { w = 6, text = '电商大促，手机跳楼价。', kind = 'good', target = '手机', lo = 0.50, hi = 0.75 },
  { w = 5, text = '纺织订单外流，棉布滞销。', kind = 'good', target = '棉布', lo = 0.55, hi = 0.80 },
  { w = 5, text = '白酒消费税传闻，行情下挫。', kind = 'good', target = '白酒', lo = 0.55, hi = 0.85 },
  { w = 4, text = '海关查获走私黄金，金价回落。', kind = 'good', target = '黄金', lo = 0.60, hi = 0.80 },
  { w = 4, text = '台风过后抢种，白菜大量上市。', kind = 'good', target = '白菜', lo = 0.45, hi = 0.70 },
  { w = 4, text = '楼市降温，钢材堆在港口卖不动。', kind = 'good', target = '钢材', lo = 0.55, hi = 0.80 },
  { w = 3, text = '风电光伏齐发力，煤炭没人要了。', kind = 'good', target = '煤炭', lo = 0.55, hi = 0.80 },

  -- 全市场
  { w = 4, text = '物流涨价，什么都跟着贵了一点。', kind = 'all', lo = 1.10, hi = 1.25 },
  { w = 3, text = '消费疲软，市场一片清淡。', kind = 'all', lo = 0.80, hi = 0.92 },
  { w = 3, text = '双十一全民剁手，物价普遍上扬。', kind = 'all', lo = 1.12, hi = 1.30 },
  { w = 3, text = '通缩阴影笼罩，什么都便宜了。', kind = 'all', lo = 0.72, hi = 0.88 },
  { w = 3, text = '同行恶意压价，市场乌烟瘴气。', kind = 'all', lo = 0.80, hi = 0.90 },
  { w = 3, text = '传闻要发消费券，市场提前躁动。', kind = 'all', lo = 1.08, hi = 1.20 },

  -- 钱：进
  { w = 5, text = '路上捡到钱包，你交还失主，对方硬塞给你一笔谢礼。', kind = 'cash', lo = 150, hi = 800 },
  { w = 4, text = '老客户介绍了生意，你收到一笔佣金。', kind = 'cash_rate', lo = 0.05, hi = 0.12 },
  { w = 3, text = '小区旧改，门口修路的补偿款到账了。', kind = 'cash', lo = 400, hi = 1500 },
  { w = 2, text = '失联多年的远房亲戚留给你一笔遗产。', kind = 'cash', lo = 1500, hi = 5000 },

  -- 钱：出
  { w = 3, text = '市场监管抽查，你交了一笔罚款。', kind = 'cash_rate_sub', lo = 0.05, hi = 0.12 },
  { w = 3, text = '朋友结婚，你随了一份子。', kind = 'cash_rate_sub', lo = 0.04, hi = 0.10 },
  { w = 3, text = '你感冒请假，耽误了几天生意。', kind = 'cash_rate_sub', lo = 0.05, hi = 0.15 },
  { w = 2, text = '骑手超速被拍，罚款单寄到了家里。', kind = 'cash', lo = -400, hi = -100 },

  -- 货：损失
  { w = 3, text = '仓库漏水，一部分货泡汤了。', kind = 'lose_goods', lo = 0.20, hi = 0.45 },
  { w = 3, text = '仓库闹了老鼠，咬坏了一批货。', kind = 'lose_goods', lo = 0.15, hi = 0.35 },
  { w = 2, text = '运输途中翻车，车上的货撒了一地。', kind = 'lose_goods', lo = 0.25, hi = 0.50 },

  -- 货：白得
  { w = 4, text = '你帮人指了趟路，对方硬塞了两袋货给你。', kind = 'free_goods', target = '大米', lo = 2, hi = 8 },
  { w = 4, text = '清仓甩卖的老板，白送了你一批尾货。', kind = 'free_goods', lo = 1, hi = 5 },
  { w = 3, text = '供货商发错货，多发的那批就归你了。', kind = 'free_goods', lo = 1, hi = 3 },
  { w = 3, text = '路边搞活动，你白得了一张刮刮乐。', kind = 'free_lotto' },

  -- 只是说句话
  { w = 3, text = '骗子冒充供货商，还好你多了个心眼，钱没丢。', kind = 'none' },
  { w = 3, text = '街坊都在传要拆迁，你心里七上八下，行情倒是没动。', kind = 'none' },
}

return Data
