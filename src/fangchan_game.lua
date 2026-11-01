-- 买房记：玩法规则和状态。
--
-- 这一层是纯逻辑，不认识屏幕：ui.lua 调它的方法、读它的字段。一回合里值得告诉玩家的事，
-- 方法会往一个 messages 表里塞短句，界面负责显示。
--
-- 一局的流程：开局 2000 元、60 个回合。每回合先让所有商品随机涨跌（围着基准价漂），再抽
-- 一条新闻；玩家在这回合里想买多少就买多少，点"下一回合"进入下一回合。仓库不限量，
-- 钱够就能买房，60 回合里买到房就算赢。另外每回合可以买几张刮刮乐碰碰运气。

local Data = require('fangchan_data')
local T = require('ffi/util').template

local Game = {}
Game.__index = Game

Game.MAX_ROUNDS = Data.MAX_ROUNDS

-- 12345 -> "12,345"
local function formatNumber(n)
  n = math.floor(tonumber(n) or 0)
  local sign = ''
  if n < 0 then sign = '-'; n = -n end
  local s = tostring(n)
  local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
  return sign .. (out:gsub('^,', ''))
end

function Game.format(n) return formatNumber(n) end
function Game:money(n) return T(Data.money_fmt, formatNumber(n)) end

function Game:new()
  local g = setmetatable({}, self)
  g:newGame()
  return g
end

function Game:newGame()
  math.randomseed(os.time())
  self.round = 1
  self.cash = Data.START_CASH
  self.owned = 0                 -- 0 = 还没房；否则是 Data.HOUSES 的下标
  self.over = false
  self.inventory, self.prices, self.prev, self.log, self.basis = {}, {}, {}, {}, {}
  for i, good in ipairs(Data.GOODS) do
    self.inventory[i] = 0
    self.basis[i] = 0            -- 手上这批货的平均买入价，卖出时给玩家对照
    -- 开局的价格不直接等于基准价，先随机偏一点
    self.prices[i] = math.max(1, math.floor(good.base * (0.8 + math.random() * 0.4)))
    self.prev[i] = self.prices[i]
  end
  self.lotto_left = Data.LOTTERY.per_round   -- 这一回合还能买几张
  self.lotto_free = 0                        -- 白得的彩票券，随时能兑，不占名额
  self.lotto_n, self.lotto_spent, self.lotto_win = 0, 0, 0
  self.lotto_cells, self.lotto_open = nil, nil   -- 手上那张卡：六个格子的奖品、刮开了哪几格
  self.lotto_pool = Data.LOTTERY.pool_start  -- 本期奖池：每张票往里注钱，1/150 的机会独得
  self:resetTip()                        -- 上一条小道消息：这一回合买，下一回合看它应不应验
  self.tip_left = Data.TIPS.per_round    -- 这回合还能买几条消息
  self.stat = self:newStat()             -- 这一局的账，成就勋章看它
  self.log[1] = T('开局：%1 的启动资金，%2 个回合，赚够钱买一套房。', self:money(Data.START_CASH), Data.MAX_ROUNDS)
  return self
end

------------------------------------------------------------------ 这一局的账（成就看它）

-- 只记本局的事：成就里"一局内如何如何"的看这里。跨局累加的那些在界面那边（best.txt）
function Game:newStat()
  return { best_trade = 0, max_hold = 0, house_buys = 0, first_round = 0,
    max_net = 0, traded = 0, tips = 0, max_cell = 0, blank_cards = 0, pool_wins = 0 }
end

-- 交易过第 i 种货，记一笔（成就"八面玲珑"要数这个）
local function mark_traded(self, i)
  if not self.stat then self.stat = self:newStat() end
  if i and i >= 1 and i <= 8 then self.stat.traded = (self.stat.traded or 0) | (1 << (i - 1)) end
end
function Game:tradedCount()
  if not self.stat then return 0 end
  local n = self.stat.traded or 0
  local c = 0
  for i = 1, #Data.GOODS do if n & (1 << (i - 1)) ~= 0 then c = c + 1 end end
  return c
end

-- 每回合结束、每笔买卖之后都该走一遍：把这一刻的数字记进账里
function Game:tally()
  if not self.stat then self.stat = self:newStat() end
  local s = self.stat
  local h = self:held()
  if h > (s.max_hold or 0) then s.max_hold = h end
  local nw = self:netWorth()
  if nw > (s.max_net or 0) then s.max_net = nw end
  return s
end

------------------------------------------------------------------ 小道消息

function Game:resetTip()
  self.tip_idx, self.tip_dir, self.tip_true, self.tip_junk = 0, 0, false, false
  self.tip_strong, self.tip_span, self.tip_seen, self.tip_base = false, 0, 0, 0
  self.tip_text = nil
end

function Game:tipText() return self.tip_text end
function Game:tipLeft() return self.over and 0 or math.floor(self.tip_left or 0) end
-- 手上这条还有几个回合见分晓（0 就是没揣着消息）
function Game:tipSpan() return math.floor(self.tip_span or 0) end

local function pick_one(t) return t[math.random(#t)] end

-- 买一条：当场抽好（哪种货、涨还是跌、管几个回合、来势凶不凶、靠不靠得住），
-- 接下来那几个回合里价格会真的往说的方向走 —— 走完才知道准不准。
function Game:buyTip()
  if self.over then return nil, '这一局已经结束了。' end
  if (self.tip_left or 0) <= 0 then return nil, T('这回合的 %1 条已经买过了，等下一回合。', Data.TIPS.per_round) end
  if self:tipSpan() > 0 then
    return nil, T('上一条说的是%1，还有 %2 个回合才见分晓。',
      Data.GOODS[self.tip_idx] and Data.GOODS[self.tip_idx].name or '行情', self:tipSpan())
  end
  if self.cash < Data.TIPS.price then return nil, T('一条要 %1，钱不够。', self:money(Data.TIPS.price)) end
  self.cash = self.cash - Data.TIPS.price
  self.tip_left = (self.tip_left or 0) - 1
  self:resetTip()
  self:tally()
  self.stat.tips = (self.stat.tips or 0) + 1          -- 成就"广撒网"数这个
  if math.random() < (Data.TIPS.junk_chance or 0) then
    self.tip_junk = true
    self.tip_text = pick_one(Data.TIP_JUNK)
    return self.tip_text
  end
  local Tp = Data.TIPS
  self.tip_idx = math.random(#Data.GOODS)
  self.tip_dir = math.random(2) == 1 and 1 or -1
  self.tip_true = math.random() < (Tp.accuracy or 0.7)
  self.tip_strong = math.random() < (Tp.strong_chance or 0)
  local lo = math.floor(Tp.span_lo or 2)
  local hi = math.floor(Tp.span_hi or 3)
  if hi < lo then hi = lo end
  self.tip_span = lo + math.random(0, hi - lo)
  self.tip_seen = self.tip_span
  self.tip_base = self.prices[self.tip_idx] or Data.GOODS[self.tip_idx].base   -- 买的时候的价，最后拿它比
  local words
  if self.tip_dir > 0 then words = self.tip_strong and Data.TIP_UP_STRONG or Data.TIP_UP
  else words = self.tip_strong and Data.TIP_DOWN_STRONG or Data.TIP_DOWN end
  self.tip_text = T('%1：%2接下来 %3 个回合%4。', pick_one(Data.TIP_SOURCES),
    Data.GOODS[self.tip_idx].name, self.tip_seen, pick_one(words))
  return self.tip_text
end

------------------------------------------------------------------ 价格

-- 走一步价格：先往基准价拉回一点（按倍率拉，跌到底也能爬回来），再叠一个随机涨跌，
-- 最后夹在上下限之间
local function step_price(good, p)
  local drift = (math.random() * 2 - 1) * good.vol
  local pull = (good.base / p) ^ Data.PULL - 1
  local np = p * (1 + pull + drift)
  np = math.max(good.base * Data.FLOOR, math.min(good.base * Data.CEIL, np))
  return math.max(1, math.floor(np))
end

-- 一条新闻之后价格也别飞出天际
local function clamp_price(good, p)
  return math.max(1, math.floor(math.max(good.base * 0.25, math.min(good.base * 4, p))))
end

local function pct(a, b) return math.floor((a - b) / b * 100 + 0.5) end

-- 小道消息在这儿兑现：它管的那几个回合里，每回合都把价格往说的方向推一把。
-- 靠得住的消息推的方向跟说的一致，坑人的消息推的方向正好相反 —— 所以跟着做有赚有赔。
-- 走完最后一个回合才结算一句"应验了 / 是假的"，中间不打扰。
-- 放在 clamp_price 后面：它得用得上 clamp_price（前面的都看不见后面声明的 local）
function Game:resolveTip()
  if self.tip_junk then
    self.tip_junk = false
    return T('上回买的那条消息，%1', self.tip_text or '什么也没听着。')
  end
  local i = self.tip_idx or 0
  local span = self:tipSpan()
  if i <= 0 or span <= 0 then return nil end
  local good = Data.GOODS[i]
  if not good then self:resetTip(); return nil end
  local Tp = Data.TIPS
  local dir = self.tip_dir or 1
  local f = self.tip_true and dir or -dir            -- 坑人的消息：反着推
  local push = self.tip_strong and (Tp.push_strong or 0.18) or (Tp.push or 0.10)
  self.prices[i] = clamp_price(good, self.prices[i] * (1 + f * push))
  self.tip_span = span - 1
  if self.tip_span > 0 then return nil end            -- 还在路上，等下一回合
  local from = (self.tip_base or 0) > 0 and self.tip_base or good.base
  local to = self.prices[i]
  local hit = (to - from) * dir > 0
  local d = pct(to, from)
  local move = (d >= 0 and '+' or '') .. d .. '%'
  local msg
  if hit then
    self.stat.tip_true = (self.stat.tip_true or 0) + 1
    msg = T('消息应验了：%1从 %2 走到 %3（%4）。', good.name, self:money(from), self:money(to), move)
  else
    msg = T('消息是假的：%1从 %2 走到 %3（%4），反着来了。', good.name, self:money(from),
      self:money(to), move)
  end
  self:resetTip()
  return msg
end

------------------------------------------------------------------ 仓库

-- 仓库不限制数量：这里只统计手上共有多少件，给玩家看
function Game:held()
  local n = 0
  for i = 1, #Data.GOODS do n = n + (self.inventory[i] or 0) end
  return n
end

function Game:stockValue()
  local v = 0
  for i = 1, #Data.GOODS do v = v + (self.inventory[i] or 0) * (self.prices[i] or 0) end
  return v
end

-- 手上这种货的平均买入价（0 = 没货）。卖出的时候拿它跟现价比一比
function Game:costBasis(i) return math.floor(self.basis[i] or 0) end
-- 这批货现在赚了多少（负数就是亏）
function Game:profit(i)
  local held = self.inventory[i] or 0
  return math.floor(held * ((self.prices[i] or 0) - (self.basis[i] or 0)))
end

-- 进 qty 件货，均价跟着摊：新均价 =（旧货的成本 + 这次花的钱）/ 总件数
local function add_cost(self, i, qty, price)
  local old = self.inventory[i] or 0
  local n = old + qty
  self.inventory[i] = n
  self.basis[i] = n > 0 and math.floor(((self.basis[i] or 0) * old + price * qty) / n + 0.5) or 0
end
function Game:houseValue() return self.owned > 0 and Data.HOUSES[self.owned].price or 0 end
function Game:netWorth() return self.cash + self:stockValue() + self:houseValue() end

-- 相对基准价是便宜还是贵，给玩家一个参考
function Game:tip(i)
  local good = Data.GOODS[i]
  local r = (self.prices[i] or good.base) / good.base
  if r < 0.75 then return '便宜'
  elseif r < 1.10 then return '正常'
  elseif r < 1.60 then return '偏贵'
  else return '很贵' end
end

------------------------------------------------------------------ 一个回合

local function pick_event()
  local total = 0
  for k, e in ipairs(Data.EVENTS) do total = total + e.w end
  local r = math.random() * total
  for k, e in ipairs(Data.EVENTS) do
    r = r - e.w
    if r <= 0 then return e end
  end
  return Data.EVENTS[1]
end

-- 商品名 → 下标（新闻里写的是名字，改商品顺序也不会搞错）
local function good_index(name)
  for i, good in ipairs(Data.GOODS) do if good.name == name then return i end end
  return nil
end

-- 执行一条新闻：改价格、给钱、扣钱、损失货物。返回一句给玩家看的话。
function Game:fireEvent(messages)
  local e = pick_event()
  -- 有些事件（白得一张刮刮乐、只是说句话）没有倍率，用到的时候才算
  local f = (e.lo ~= nil and e.hi ~= nil) and (e.lo + math.random() * (e.hi - e.lo)) or nil
  if e.kind == 'good' then
    local i = good_index(e.target)
    if not i then messages[#messages + 1] = e.text; return e end
    self.prices[i] = clamp_price(Data.GOODS[i], self.prices[i] * f)
    messages[#messages + 1] = e.text
  elseif e.kind == 'all' then
    for i, good in ipairs(Data.GOODS) do self.prices[i] = clamp_price(good, self.prices[i] * f) end
    messages[#messages + 1] = e.text
  elseif e.kind == 'cash' then
    local amt = math.floor(f)
    if amt >= 0 then
      self.cash = self.cash + amt
      messages[#messages + 1] = T('%1 你多了 %2。', e.text, self:money(amt))
    else
      local d = math.min(self.cash, -amt)
      self.cash = self.cash - d
      messages[#messages + 1] = T('%1 你少了 %2。', e.text, self:money(d))
    end
  elseif e.kind == 'cash_rate' then
    local amt = math.floor(self.cash * f)
    if amt > 0 then
      self.cash = self.cash + amt
      messages[#messages + 1] = T('%1 你多了 %2。', e.text, self:money(amt))
    else
      messages[#messages + 1] = e.text
    end
  elseif e.kind == 'cash_rate_sub' then
    local amt = math.min(self.cash, math.floor(self.cash * f))
    if amt > 0 then
      self.cash = self.cash - amt
      messages[#messages + 1] = T('%1 你少了 %2。', e.text, self:money(amt))
    else
      messages[#messages + 1] = e.text
    end
  elseif e.kind == 'lose_goods' then
    local held = {}
    for i = 1, #Data.GOODS do if (self.inventory[i] or 0) > 0 then held[#held + 1] = i end end
    if #held == 0 then
      messages[#messages + 1] = e.text .. '还好仓库是空的。'
    else
      local i = held[math.random(#held)]
      local lost = math.floor(self.inventory[i] * f)
      self.inventory[i] = self.inventory[i] - lost
      if self.inventory[i] <= 0 then self.inventory[i] = 0; self.basis[i] = 0 end
      messages[#messages + 1] = T('%1 你损失了 %2 件%3。', e.text, lost, Data.GOODS[i].name)
    end
  elseif e.kind == 'free_goods' then
    local i = e.target and good_index(e.target) or math.random(#Data.GOODS)
    if not i then i = math.random(#Data.GOODS) end
    local n = math.max(1, math.floor(f))
    add_cost(self, i, n, 0)                     -- 白得的：成本算 0，卖多少赚多少
    messages[#messages + 1] = T('%1 你多了 %2 件%3。', e.text, n, Data.GOODS[i].name)
  elseif e.kind == 'free_lotto' then
    self.lotto_free = (self.lotto_free or 0) + 1
    messages[#messages + 1] = e.text .. '随时可以去刮。'
  else
    messages[#messages + 1] = e.text
  end
  return e
end

-- 进入下一回合：价格先走一步，再抽新闻。
-- 返回两摞话：events 是这一回合的特殊事件（新闻说的话），moves 是涨跌榜。分开给界面摆。
function Game:nextRound()
  local events, moves = {}, {}
  if self.over then return { events = events, moves = moves, over = true } end
  for i = 1, #Data.GOODS do self.prev[i] = self.prices[i] end
  for i, good in ipairs(Data.GOODS) do self.prices[i] = step_price(good, self.prices[i]) end
  -- 手上那条小道消息在这儿推价格：随机涨跌走完之后，再往消息说的方向推一把
  local tip_msg = self:resolveTip()
  if math.random() < Data.EVENT_CHANCE then
    local e = self:fireEvent(events)
    self:note(e.text)
  end
  -- 涨跌榜：只报动过 8% 以上的，最多两样
  local best_up, best_down = nil, nil
  for i, good in ipairs(Data.GOODS) do
    local d = pct(self.prices[i], self.prev[i])
    if not best_up or d > best_up.d then best_up = { idx = i, d = d } end
    if not best_down or d < best_down.d then best_down = { idx = i, d = d } end
  end
  if best_up and best_up.d >= 8 then
    moves[#moves + 1] = T('▲ %1 涨到 %2（+%3%）', Data.GOODS[best_up.idx].name, self:money(self.prices[best_up.idx]), best_up.d)
  end
  if best_down and best_down.d <= -8 then
    moves[#moves + 1] = T('▼ %1 跌到 %2（%3%）', Data.GOODS[best_down.idx].name, self:money(self.prices[best_down.idx]), best_down.d)
  end
  self.round = self.round + 1
  self.lotto_left = Data.LOTTERY.per_round       -- 新的一回合，又有三张名额
  self.tip_left = Data.TIPS.per_round            -- 消息也又能买了
  self:tally()
  local done = false
  if self.round > Data.MAX_ROUNDS then
    self.round = Data.MAX_ROUNDS
    self.over = true
    done = true
  end
  if done then events[#events + 1] = T('第 %1 回合结束，60 个回合用完了。', Data.MAX_ROUNDS) end
  return { events = events, moves = moves, tip = tip_msg, over = self.over }
end

-- 收摊：最后一回合自己结束（或者六十回合走完）。结算画面由界面弹
function Game:finish()
  self.over = true
  return true
end

------------------------------------------------------------------ 彩票站：六格刮刮乐

-- 一个格子刮出什么：按权重抽一个奖品下标
local function pick_cell()
  local total = 0
  for _k, p in ipairs(Data.LOTTERY.CELL_PRIZES) do total = total + p.w end
  local r = math.random() * total
  for k, p in ipairs(Data.LOTTERY.CELL_PRIZES) do
    r = r - p.w
    if r <= 0 then return k end
  end
  return 1
end
local function cell_amount(k)
  local p = Data.LOTTERY.CELL_PRIZES[math.floor(k or 0)]
  return p and p.amount or 0
end
local function n_cells() return Data.LOTTERY.cells end

-- 存档：六个格子的奖品下标压成一个六位数（每格一位），刮开情况压成一个位掩码
local function pack_card(cells)
  local v = 0
  if not cells then return 0 end
  for k = 1, n_cells() do v = v * 10 + math.floor(cells[k] or 0) end
  return v
end
local function pack_mask(open)
  local v = 0
  if not open then return 0 end
  for k = n_cells(), 1, -1 do v = v * 2 + (open[k] and 1 or 0) end
  return v
end

-- 这一回合还能买几张（白得的券不算名额，随时能用）
function Game:lotteryLeft() return self.over and 0 or math.floor(self.lotto_left or 0) end
function Game:lotteryFree() return math.floor(self.lotto_free or 0) end
function Game:lotteryPool() return math.floor(self.lotto_pool or 0) end

-- 手上那张卡：返回（六格的金额，六格刮开了没有），没有卡就是 nil
function Game:lotteryCard()
  local c, o = self.lotto_cells, self.lotto_open
  if not c or #c ~= n_cells() then return nil end
  local amounts = {}
  for k = 1, n_cells() do amounts[k] = cell_amount(c[k]) end
  return amounts, o
end

-- 能不能再买一张：要么这回合还有名额且掏得出钱，要么手上有一张白得的券。
-- 手上还捏着一张没刮完的不算：先刮完那张再说。
function Game:canLottery()
  if self.over then return false, '这一局已经结束了。' end
  if self.lotto_cells then return false, '手上那张还没刮完呢，先刮完再说。' end
  if (self.lotto_free or 0) > 0 then return true end
  if (self.lotto_left or 0) <= 0 then return false, T('这回合的 %1 张已经买完了，等下一回合。', Data.LOTTERY.per_round) end
  if self.cash < Data.LOTTERY.price then return false, T('一张要 %1，钱不够。', self:money(Data.LOTTERY.price)) end
  return true
end

-- 开一张新卡之前走这一步：要么兑掉一张白得的券，要么掏钱占一个名额，
-- 同时把 ¥10 注进本期奖池
local function take_ticket(self)
  if (self.lotto_free or 0) > 0 then
    self.lotto_free = self.lotto_free - 1
  else
    self.cash = self.cash - Data.LOTTERY.price
    self.lotto_left = (self.lotto_left or 0) - 1
    self.lotto_spent = (self.lotto_spent or 0) + Data.LOTTERY.price
  end
  self.lotto_n = (self.lotto_n or 0) + 1
  self.lotto_pool = (self.lotto_pool or 0) + Data.LOTTERY.pool_in
  return true
end

-- 买一张：六个格子的奖当场抽好存着，玩家一格一格点开（退出重进也不会丢）
function Game:buyLottery()
  local ok, err = self:canLottery()
  if not ok then return nil, err end
  take_ticket(self)
  local c, o = {}, {}
  for k = 1, n_cells() do c[k] = pick_cell(); o[k] = false end
  self.lotto_cells, self.lotto_open = c, o
  return true
end

-- 刮开第 k 格。返回这一格的金额，已经刮过或没这张卡就返回 nil
function Game:scratchCell(k)
  local c, o = self.lotto_cells, self.lotto_open
  k = math.floor(tonumber(k) or 0)
  if not c or k < 1 or k > n_cells() then return nil end
  if o[k] then return nil end
  o[k] = true
  local a = cell_amount(c[k])
  self:tally()
  if a > (self.stat.max_cell or 0) then self.stat.max_cell = a end   -- 成就"锦鲤附体"看这个
  return a
end

-- 六个格子里刮开了几格
function Game:cardOpenCount()
  local o = self.lotto_open
  if not o then return 0 end
  local n = 0
  for k = 1, n_cells() do if o[k] then n = n + 1 end end
  return n
end
-- 已经刮开的那几格一共多少钱（给玩家看着攒）
function Game:cardRevealedTotal()
  local c, o = self.lotto_cells, self.lotto_open
  if not c then return 0 end
  local v = 0
  for k = 1, n_cells() do if o[k] then v = v + cell_amount(c[k]) end end
  return v
end
-- 六个都刮开了没有
function Game:cardDone() return self.lotto_cells ~= nil and self:cardOpenCount() >= n_cells() end

-- 交回这张卡：把已经刮开的那几格的金额加起来入账，再抽一次奖池机会。
-- 没刮开的格子不算 —— 不刮就没有钱。返回（总金额，六个格子各自的金额，额外发生的事）
function Game:cashCard()
  local c, o = self.lotto_cells, self.lotto_open
  if not c or not o then return nil end
  local amounts, total = {}, 0
  for k = 1, n_cells() do
    amounts[k] = cell_amount(c[k])
    if o[k] then total = total + amounts[k] end
  end
  local opened = self:cardOpenCount()
  self.lotto_cells, self.lotto_open = nil, nil
  self:tally()
  if total > 0 then
    self.cash = self.cash + total
    self.lotto_win = (self.lotto_win or 0) + total
  elseif opened >= n_cells() then
    self.stat.blank_cards = (self.stat.blank_cards or 0) + 1        -- 成就"空手而归"
  end
  local msgs = {}
  -- 每张票都有一次机会独得奖池，中不中奖跟卡上刮出来的钱各算各的
  if math.random(Data.LOTTERY.pool_chance) == 1 then
    local pool = self:lotteryPool()
    if pool > 0 then
      self.cash = self.cash + pool
      self.lotto_win = (self.lotto_win or 0) + pool
      self.lotto_pool = 0
      self.stat.pool_wins = (self.stat.pool_wins or 0) + 1          -- 成就"奖池猎手"
      msgs[#msgs + 1] = T('独得本期奖池 %1！奖池清空，从头再攒。', self:money(pool))
    end
  end
  return total, amounts, msgs
end


-- 记一条行情，最多留 4 条，给"行情"那一屏翻
function Game:note(s)
  if not s or s == '' then return end
  table.insert(self.log, 1, s)
  while #self.log > 4 do table.remove(self.log) end
end

------------------------------------------------------------------ 买卖

function Game:maxBuy(i)
  local price = self.prices[i]
  if not price or price <= 0 then return 0 end
  return math.max(0, math.floor(self.cash / price))
end

function Game:buy(i, qty)
  local price = self.prices[i]
  qty = math.floor(tonumber(qty) or 0)
  if qty <= 0 then return false end
  if not price then return false, '这里不做这种货。' end
  local cost = price * qty
  if cost > self.cash then return false, '钱不够。' end
  self.cash = self.cash - cost
  add_cost(self, i, qty, price)
  mark_traded(self, i)
  self:tally()
  return true
end

function Game:sell(i, qty)
  local price = self.prices[i]
  qty = math.floor(tonumber(qty) or 0)
  if qty <= 0 then return false end
  if not price then return false, '这里没人收这种货。' end
  if qty > (self.inventory[i] or 0) then return false, '手上没有这么多。' end
  local gain = math.floor(qty * (price - (self.basis[i] or 0)))   -- 这一笔赚了多少
  self.cash = self.cash + price * qty
  self.inventory[i] = self.inventory[i] - qty
  if self.inventory[i] <= 0 then self.inventory[i] = 0; self.basis[i] = 0 end
  mark_traded(self, i)
  self:tally()                                                    -- 先把 stat 摆好再往里记
  if gain > (self.stat.best_trade or 0) then self.stat.best_trade = gain end
  return true
end

-- 一键清仓：把手上的货全卖了，返回（件数，收入）
function Game:sellAll()
  local n, got = 0, 0
  for i = 1, #Data.GOODS do
    local held = self.inventory[i] or 0
    if held > 0 and self.prices[i] then
      self.cash = self.cash + self.prices[i] * held
      got = got + self.prices[i] * held
      n = n + held
      self.inventory[i] = 0
      self.basis[i] = 0
    end
  end
  return n, got
end

------------------------------------------------------------------ 买房

-- 买第 i 档要掏多少钱：已经有一套的话，旧房按原价抵扣，只补差价
function Game:houseCost(i)
  local h = Data.HOUSES[i]
  if not h then return nil end
  if self.owned <= 0 then return h.price end
  return h.price - Data.HOUSES[self.owned].price
end

function Game:canBuyHouse(i)
  local cost = self:houseCost(i)
  return cost ~= nil and i > self.owned and self.cash >= cost
end

function Game:buyHouse(i)
  if not Data.HOUSES[i] then return false, '没有这一档。' end
  if i <= self.owned then return false, '你已经住得更好了。' end
  local cost = self:houseCost(i)
  if self.cash < cost then return false, T('钱不够，还差 %1。', self:money(cost - self.cash)) end
  self.cash = self.cash - cost
  self.owned = i
  self:tally()
  self.stat.house_buys = (self.stat.house_buys or 0) + 1
  if (self.stat.first_round or 0) <= 0 then self.stat.first_round = self.round end
  return true, T('你买下了%1，成了有房的人。', Data.HOUSES[i].name)
end

function Game:rank()
  if self.owned > 0 then return Data.HOUSES[self.owned].rank end
  return Data.NO_HOUSE_RANK
end

------------------------------------------------------------------ 存档

function Game:serialize()
  local inv, pr, pv, ba = {}, {}, {}, {}
  for i = 1, #Data.GOODS do
    inv[i] = tostring(math.floor(self.inventory[i] or 0))
    pr[i] = tostring(math.floor(self.prices[i] or 0))
    pv[i] = tostring(math.floor(self.prev[i] or 0))
    ba[i] = tostring(math.floor(self.basis[i] or 0))
  end
  local s = self.stat or self:newStat()
  return {
    round = self.round, cash = self.cash, owned = self.owned,
    inventory = inv, prices = pr, prev = pv, basis = ba,
    over = self.over, log = self.log,
    -- 小道消息：还能买几条 / 哪种货 / 涨还是跌 / 靠不靠得住 / 来势凶不凶 /
    -- 还剩几个回合 / 一共几个回合 / 买的时候的价 / 是不是废话；原文另存一行
    tip = { self.tip_left or 0, self.tip_idx or 0, self.tip_dir or 0,
      (self.tip_true and 1 or 0), (self.tip_strong and 1 or 0),
      self.tip_span or 0, self.tip_seen or 0, math.floor(self.tip_base or 0),
      (self.tip_junk and 1 or 0) },
    tiptxt = self.tip_text or '',
    -- 这一局的账：成就看它。跨局累加的那些（刮了几张、买过几条消息）在界面那边
    stat = { s.best_trade or 0, s.max_hold or 0, s.house_buys or 0, s.first_round or 0,
      s.max_net or 0, s.traded or 0, s.tips or 0, s.max_cell or 0,
      s.blank_cards or 0, s.pool_wins or 0 },
    lotto_left = self.lotto_left, lotto_free = self.lotto_free,
    lotto_n = self.lotto_n, lotto_spent = self.lotto_spent,
    lotto_win = self.lotto_win, lotto_pool = self.lotto_pool,
    -- 手上那张卡：六个格子的奖品下标压成一个六位数，刮开了哪几格压成一个位掩码
    lotto_card = pack_card(self.lotto_cells),
    lotto_mask = pack_mask(self.lotto_open),
  }
end

function Game:load(state)
  if type(state) ~= 'table' or not state.round or not state.inventory then return false end
  self:newGame()                       -- 先把所有字段摆好，再用存档盖上去
  self.round = math.floor(tonumber(state.round) or 1)
  self.cash = math.floor(tonumber(state.cash) or Data.START_CASH)
  self.owned = math.floor(tonumber(state.owned) or 0)
  self.inventory, self.prices, self.prev, self.log, self.basis = {}, {}, {}, {}, {}
  for i, good in ipairs(Data.GOODS) do
    self.inventory[i] = math.floor(tonumber(state.inventory[i]) or 0)
    local p = math.floor(tonumber(state.prices[i]) or 0)
    self.prices[i] = p > 0 and p or math.max(1, math.floor(good.base))
    self.prev[i] = math.floor(tonumber(state.prev[i]) or 0)
    if self.prev[i] <= 0 then self.prev[i] = self.prices[i] end
    -- 老存档没有 basis：拿现价当买入价，总比没有强
    self.basis[i] = math.floor(tonumber(state.basis and state.basis[i]) or (self.inventory[i] > 0 and self.prices[i] or 0))
    if self.inventory[i] <= 0 then self.basis[i] = 0 end
  end
  self.over = state.over == true or state.over == '1'
  -- 小道消息：老存档没有这一行，读不到就是没买过
  self:resetTip()
  self.tip_left = Data.TIPS.per_round
  if type(state.tip) == 'table' then
    local tp = state.tip
    local yn = function(v) return v == 1 or v == '1' or v == true end
    self.tip_left = math.floor(tonumber(tp[1]) or Data.TIPS.per_round)
    local idx = math.floor(tonumber(tp[2]) or 0)
    self.tip_idx = (idx >= 1 and idx <= #Data.GOODS) and idx or 0
    self.tip_dir = (tonumber(tp[3]) or 0) < 0 and -1 or 1
    self.tip_true = yn(tp[4])
    self.tip_strong = yn(tp[5])
    self.tip_span = math.max(0, math.floor(tonumber(tp[6]) or 0))
    self.tip_seen = math.max(0, math.floor(tonumber(tp[7]) or 0))
    self.tip_base = math.floor(tonumber(tp[8]) or 0)
    self.tip_junk = yn(tp[9])
    if self.tip_idx <= 0 and not self.tip_junk then self.tip_span = 0 end
    if self.tip_span <= 0 then self.tip_idx = 0 end
    if self.tip_base <= 0 then self.tip_base = self.prices[self.tip_idx] or 0 end
    -- 消息原文存下来：退出重进还能看见那条消息说了什么（老存档没有这一行，就当没买过）
    self.tip_text = (type(state.tiptxt) == 'string' and state.tiptxt ~= '') and state.tiptxt or nil
    if not self.tip_text then self:resetTip() end
  end
  -- 这一局的账：没有就从头记
  self.stat = self:newStat()
  if type(state.stat) == 'table' then
    local f = function(n) return math.floor(tonumber(n) or 0) end
    self.stat.best_trade = f(state.stat[1])
    self.stat.max_hold = f(state.stat[2])
    self.stat.house_buys = f(state.stat[3])
    self.stat.first_round = f(state.stat[4])
    self.stat.max_net = f(state.stat[5])
    self.stat.traded = f(state.stat[6])
    self.stat.tips = f(state.stat[7])
    self.stat.max_cell = f(state.stat[8])
    self.stat.blank_cards = f(state.stat[9])
    self.stat.pool_wins = f(state.stat[10])
  end
  self.lotto_left = math.floor(tonumber(state.lotto_left) or Data.LOTTERY.per_round)
  self.lotto_free = math.floor(tonumber(state.lotto_free) or 0)
  self.lotto_n = math.floor(tonumber(state.lotto_n) or 0)
  self.lotto_spent = math.floor(tonumber(state.lotto_spent) or 0)
  self.lotto_win = math.floor(tonumber(state.lotto_win) or 0)
  -- 老存档没有奖池：那就从开局的底子开始攒
  self.lotto_pool = math.floor(tonumber(state.lotto_pool) or Data.LOTTERY.pool_start)
  -- 手上那张没刮完的卡要原样读回来。老存档那一位放的是别的东西，读出来不成样子就当没卡
  self.lotto_cells, self.lotto_open = nil, nil
  local card = math.floor(tonumber(state.lotto_card) or 0)
  local mask = math.floor(tonumber(state.lotto_mask) or 0)
  if card > 0 then
    local s = string.format('%0' .. n_cells() .. 'd', card % (10 ^ n_cells()))
    local c, o, bad = {}, {}, false
    for k = 1, n_cells() do
      local idx = math.floor(tonumber(s:sub(k, k)) or 0)
      if not Data.LOTTERY.CELL_PRIZES[idx] then bad = true; break end
      c[k] = idx
      o[k] = mask % 2 == 1
      mask = math.floor(mask / 2)
    end
    if not bad then self.lotto_cells, self.lotto_open = c, o end
  end
  if type(state.log) == 'table' then
    for k, s in ipairs(state.log) do if type(s) == 'string' then self.log[#self.log + 1] = s end end
  end
  if #self.log == 0 then self.log[1] = T('开局：%1 的启动资金，%2 个回合，赚够钱买一套房。', self:money(Data.START_CASH), Data.MAX_ROUNDS) end
  if self.round > Data.MAX_ROUNDS then self.round = Data.MAX_ROUNDS; self.over = true end
  return true
end

return Game
