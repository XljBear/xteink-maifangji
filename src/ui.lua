-- 买房记 for XTOS Licorice (API 2.9)：设备上的那一屏。
--
-- 一屏看完：回合、现金、净资产、库存、房产，下面八行行情，再下面六个按钮。点商品买卖，
-- 点"下一回合"推进；买房、清仓、行情、成绩都在按钮里。每一步都自动存档，退出也存。
--
-- 所有 ctx.* 都是这个 API 上的方法：一律用冒号调用。

local W, H = 480, 800
local Data = require('fangchan_data')
local Game = require('fangchan_game')
local T = require('ffi/util').template

local game
local difficulty = 1                     -- Data.DIFFICULTY 的下标：1 = 简单
-- best_net / best_house 是历史最好成绩；house_wins[i] 是第 i 档房子历年一共买到过几次
local best_net, best_house = 0, 0
local house_wins = {}
for _k = 1, #Data.HOUSES do house_wins[_k] = 0 end
local modal = nil                        -- 弹窗：{ title, lines, rows = { { {标签, 函数, 可用}, .. }, .. }, cancel }
local status = ''
local ERR = nil
local lottery_box, difficulty_box, end_game   -- 下面才定义，按钮表先挂个名字

------------------------------------------------------------------ 小工具

local function refresh() pcall(function() ctx.invalidate() end) end
local function fmt(n) return Game.format(n) end

-- 一个 UTF-8 字符数组（中文没有空格，只能一个字一个字地量着折行）
local function chars(s)
  local out = {}
  for _p, c in utf8.codes(s) do out[#out + 1] = utf8.char(c) end
  return out
end
-- 掉最后一个字符，整个 UTF-8 序列一起掉
local function drop_last(s) return (s:gsub('[%z\1-\127\192-\255][\128-\191]*$', '')) end
-- 最多 n 个字节，且不把一个字切成两半
local function short(s, n)
  s = tostring(s)
  if #s <= n then return s end
  local t = s:sub(1, n)
  while #t > n - 1 or (#t > 0 and t:sub(-1):byte() >= 128 and not utf8.len(t)) do t = drop_last(t) end
  return t .. '~'
end

local function font(name) return ctx.fonts and ctx.fonts[name] end
local function width(f, s)
  local ok, w = pcall(function() return f:measure(s) end)
  return (ok and type(w) == 'number') and w or #s * 11
end
local function line_h(name)
  local ok, h = pcall(function() return font(name).line_height end)
  return (ok and tonumber(h)) or (name == 'large' and 30 or name == 'small' and 20 or 24)
end

-- 折行：中文一个字一个 token，西文按空格分词，行宽超了就换行
local function tokenize(s)
  local out, word = {}, ''
  local function flush() if word ~= '' then out[#out + 1] = word; word = '' end end
  for _p, c in utf8.codes(s) do
    local ch = utf8.char(c)
    if ch == ' ' or ch == '\t' then flush(); out[#out + 1] = ' '
    elseif c >= 0x2E80 then flush(); out[#out + 1] = ch      -- 汉字和全角标点：一个字一段
    else word = word .. ch end
  end
  flush()
  return out
end

local function wrap(s, fname, maxw)
  local f, out = font(fname), {}
  for para in (tostring(s) .. '\n'):gmatch('([^\n]*)\n') do
    local line = ''
    for _k, tk in ipairs(tokenize(para)) do
      if tk == ' ' then
        if line ~= '' and line:sub(-1) ~= ' ' then line = line .. ' ' end
      else
        local join = ''
        local last = line:byte(-1)
        -- 两边只要有一边不是 ASCII（汉字、¥、·）就紧挨着排，中文不用空格分词
        local cjk = tk:byte() >= 0x80 or (last ~= nil and last >= 0x80)
        if line ~= '' and not cjk and line:sub(-1) ~= ' ' then join = ' ' end
        local cand = line .. join .. tk
        if line ~= '' and width(f, cand) > maxw then
          out[#out + 1] = (line:gsub(' +$', ''))
          line = tk
        else
          line = cand
        end
      end
    end
    out[#out + 1] = (line:gsub(' +$', ''))
  end
  return out
end

------------------------------------------------------------------ 存档

local function read(name)
  local ok, s = pcall(function() return ctx.storage:read(name) end)
  return (ok and type(s) == 'string') and s or nil
end
local function write(name, s) pcall(function() ctx.storage:write(name, s) end) end

local function kv(s)
  local t = {}
  for k, v in (s or ''):gmatch('([%w_]+)=([^\n]*)') do t[k] = (v:gsub('%s+$', '')) end
  return t
end

-- 存档写成 key=value 的行：设备没有 JSON 编码器，这样也够读回来
local function save()
  if not game then return end
  local st = game:serialize()
  write('game.txt', table.concat({
    'round=' .. st.round, 'cash=' .. math.floor(st.cash), 'owned=' .. st.owned,
    'inv=' .. table.concat(st.inventory, ','), 'prices=' .. table.concat(st.prices, ','),
    'prev=' .. table.concat(st.prev, ','), 'basis=' .. table.concat(st.basis, ','),
    'over=' .. (st.over and '1' or '0'),
    -- lotto= 这一串往前加过字段：老存档位数对不上，读不到的按开局处理
    'lotto=' .. table.concat({ st.lotto_left, st.lotto_free, st.lotto_n, st.lotto_spent,
      st.lotto_win, st.lotto_card, st.lotto_pool, st.lotto_mask }, ','),
    'log=' .. table.concat(st.log, '|'),
  }, '\n'))
end

local function load_saved()
  local t = kv(read('game.txt'))
  if not t.round then return false end
  local function list(s)
    local out, i = {}, 0
    for v in ((s or '') .. ','):gmatch('([^,]*),') do i = i + 1; out[i] = tonumber(v) end
    return out
  end
  local log = {}
  for s in (t.log or ''):gmatch('[^|]+') do log[#log + 1] = s end
  local lt = list(t.lotto)
  return game:load({
    round = tonumber(t.round), cash = tonumber(t.cash), owned = tonumber(t.owned),
    inventory = list(t.inv), prices = list(t.prices), prev = list(t.prev), basis = list(t.basis),
    over = t.over == '1', log = log,
    lotto_left = lt[1], lotto_free = lt[2], lotto_n = lt[3],
    lotto_spent = lt[4], lotto_win = lt[5], lotto_card = lt[6],
    lotto_pool = lt[7], lotto_mask = lt[8],
  })
end

-- 难度单独存一份：换难度不动这一局，新开一局也还是这个难度
local function save_settings() write('settings.txt', 'difficulty=' .. difficulty) end
local function load_settings()
  local t = kv(read('settings.txt'))
  local d = math.floor(tonumber(t.difficulty) or 1)
  difficulty = Data.DIFFICULTY[d] and d or 1
end
local function diff() return Data.DIFFICULTY[difficulty] end
local function show_base() return diff().show_base end      -- 显不显示基准价
local function show_tip() return diff().show_tip end        -- 提不提示便宜还是贵

-- best.txt 记三样：最高净资产、买过最好的房子、每一档房子一共买到过几次（逗号分隔）
local function save_best()
  local w = {}
  for i = 1, #Data.HOUSES do w[i] = tostring(math.floor(house_wins[i] or 0)) end
  write('best.txt', 'net=' .. math.floor(best_net) .. '\nhouse=' .. best_house
    .. '\nwins=' .. table.concat(w, ','))
end
local function load_best()
  local t = kv(read('best.txt'))
  best_net = tonumber(t.net) or 0
  best_house = tonumber(t.house) or 0
  local i = 0
  for v in ((t.wins or '') .. ','):gmatch('([^,]*),') do
    i = i + 1
    if i <= #Data.HOUSES then house_wins[i] = math.floor(tonumber(v) or 0) end
  end
end
local function record(net, house)
  if net > best_net then best_net = net end
  if house > best_house then best_house = house end
  save_best()
end
-- 买成了第 i 档：这一档的累计次数 +1
local function record_house(i)
  if Data.HOUSES[i] then
    house_wins[i] = (house_wins[i] or 0) + 1
    save_best()
  end
end
local function total_house_wins()
  local n = 0
  for i = 1, #Data.HOUSES do n = n + (house_wins[i] or 0) end
  return n
end

------------------------------------------------------------------ 弹窗

local BOX_X, BOX_W, ROW_H, GAP = 20, W - 40, 56, 10
-- 刮刮卡的格子：一行三个，两行六个
local CELL_W, CELL_H, CELL_GAP = 126, 100, 11

local function layout_modal(m)
  local lines = {}
  if m.title then
    for _k, l in ipairs(wrap(m.title, 'medium', BOX_W - 40)) do lines[#lines + 1] = { l, 'medium' } end
  end
  for _k, s in ipairs(m.lines or {}) do
    for _k, l in ipairs(wrap(s, m.big and 'large' or 'small', BOX_W - 40)) do lines[#lines + 1] = { l, m.big and 'large' or 'small' } end
  end
  local th = 0
  for _k, l in ipairs(lines) do th = th + line_h(l[2]) + 4 end
  local nrow = m.cells and math.ceil(#m.cells / 3) or 0
  local ch = nrow > 0 and (nrow * CELL_H + (nrow - 1) * CELL_GAP + 8) or 0
  local h = 20 + th + 14 + ch + #m.rows * (ROW_H + GAP) + 10
  local y = math.max(150, math.floor((H - h) / 2))
  if y + h > H - 30 then y = math.max(10, H - 30 - h) end
  local cy = y + 20 + th + 14
  local cells = {}
  for k = 1, (m.cells and #m.cells or 0) do
    local c, r = (k - 1) % 3, (k - 1) // 3
    cells[k] = { x = BOX_X + 20 + c * (CELL_W + CELL_GAP), y = cy + r * (CELL_H + CELL_GAP),
      w = CELL_W, h = CELL_H, c = m.cells[k] }
  end
  local btns, by = {}, cy + ch
  for _k, row in ipairs(m.rows) do
    local n = #row
    local bw = math.floor((BOX_W - 40 - (n - 1) * GAP) / n)
    for k, btn in ipairs(row) do
      btns[#btns + 1] = { x = BOX_X + 20 + (k - 1) * (bw + GAP), y = by, w = bw, h = ROW_H, b = btn }
    end
    by = by + ROW_H + GAP
  end
  return lines, btns, y, h, cells
end

-- 还没刮开的那一层涂层：45 度的斜线，画在 (x,y,w,h) 这个框里
local function hatch(gg, x, y, w, h)
  local step = 22
  local d = -h + step
  while d < w - step do
    local ax, ay, bx, by
    if d < 0 then ax, ay = x, y + h + d else ax, ay = x + d, y + h end
    if d + h <= w then bx, by = x + d + h, y else bx, by = x + w, y + h - (w - d) end
    pcall(function() gg:line(ax, ay, bx, by) end)
    d = d + step
  end
end

-- 刮出来是笑脸：画一张脸。字体里未必有 ☺ 这个字符，用线条画最保险
local function smiley(gg, cx, cy)
  pcall(function()
    gg:circle(cx, cy - 2, 23)
    gg:circle(cx - 9, cy - 11, 2)
    gg:circle(cx + 9, cy - 11, 2)
    gg:polyline({ cx - 13, cy + 5, cx - 7, cy + 12, cx, cy + 14, cx + 7, cy + 12, cx + 13, cy + 5 })
  end)
end

-- 一格：没刮开是涂着斜线的方块，刮开了就是笑脸或者金额
local function draw_cell(gg, cl)
  local c = cl.c
  gg:rect(cl.x, cl.y, cl.w, cl.h, { line_width = 2 })
  if c.open then
    if (c.amount or 0) > 0 then
      local s = game:money(c.amount)
      local f = font('large')
      while #s > 1 and width(f, s) > cl.w - 12 do s = s:sub(1, -2) end
      local tf = width(f, s) > cl.w - 12 and font('medium') or f
      gg:text(cl.x + math.floor((cl.w - width(tf, s)) / 2), cl.y + math.floor((cl.h - line_h('medium')) / 2), s, { font = tf })
    else
      smiley(gg, cl.x + cl.w // 2, cl.y + cl.h // 2)
    end
  else
    hatch(gg, cl.x + 4, cl.y + 4, cl.w - 8, cl.h - 8)
  end
end

local function draw_modal(gg)
  local lines, btns, y, h, cells = layout_modal(modal)
  gg:rect(BOX_X, y, BOX_W, h)
  gg:rect(BOX_X + 3, y + 3, BOX_W - 6, h - 6)
  local ty = y + 20
  for _k, l in ipairs(lines) do gg:text(BOX_X + 20, ty, l[1], { font = font(l[2]) }); ty = ty + line_h(l[2]) + 4 end
  for _k, cl in ipairs(cells) do draw_cell(gg, cl) end
  for _k, bt in ipairs(btns) do
    local enabled = bt.b[3] ~= false
    gg:rect(bt.x, bt.y, bt.w, bt.h, { line_width = enabled and 2 or 1 })
    local f = font('medium')
    local label = tostring(bt.b[1])
    while #label > 1 and width(f, label) > bt.w - 12 do label = drop_last(label) end
    local tx = bt.x + math.floor((bt.w - width(f, label)) / 2)
    gg:text(tx, bt.y + 15, enabled and label or ('(' .. label .. ')'), { font = f })
  end
end

local function show(m) modal = m; refresh() end
local function close_modal() modal = nil end

local function info(lines, after)
  if type(lines) == 'string' then lines = { lines } end
  if not lines or #lines == 0 then if after then after() end return end
  show({ lines = lines, rows = { { { '知道了', function() close_modal(); if after then after() end end } } },
    cancel = function() close_modal(); if after then after() end end })
end

-- 数量选择器：1 到 max，按档位加减，四分之一、一半、全部，或者用键盘手输
local function choose_amount(title, max, apply, money, ok_label, note)
  max = math.floor(max or 0)
  if max < 1 then info('现在没什么可做的。'); return end
  local v = max
  local digits = #tostring(max)
  local small = math.max(1, math.floor(10 ^ math.max(0, digits - 2)))
  local big = small * 10
  local m
  local function set(x) v = math.max(1, math.min(max, math.floor(x))); m.lines[2] = money and game:money(v) or fmt(v) end
  m = {
    title = title, lines = { T('最多 %1', money and game:money(max) or fmt(max)), '', note or '' },
    rows = {
      { { '-' .. fmt(big), function() set(v - big) end }, { '-' .. fmt(small), function() set(v - small) end },
        { '+' .. fmt(small), function() set(v + small) end }, { '+' .. fmt(big), function() set(v + big) end } },
      { { '1/4', function() set(max / 4) end }, { '1/2', function() set(max / 2) end },
        { '全部', function() set(max) end }, { '手输', function()
          pcall(function()
            ctx.input:text({ title = title, text = tostring(v) }, function(c, s)
              local n = tonumber((tostring(s or ''):gsub('[^%d]', '')))
              if n then set(n) end
              refresh()
            end)
          end)
        end } },
      { { ok_label or title, function() close_modal(); apply(v); save() end }, { '取消', close_modal } },
    },
    cancel = close_modal,
  }
  set(v)
  show(m)
end

------------------------------------------------------------------ 各个动作

local function trade(i)
  local good = Data.GOODS[i]
  local price = game.prices[i]
  local held = game.inventory[i] or 0
  local basis = game:costBasis(i)
  local lines = { T('现价 %1 · 现金 %2', game:money(price), game:money(game.cash)) }
  -- 基准价和"便宜/贵"只有简单难度才给看
  if show_base() or show_tip() then
    lines[#lines + 1] = T('基准 %1 · %2 · 手上共 %3 件', game:money(good.base), game:tip(i), game:held())
  end
  if held > 0 then
    local pr = game:profit(i)
    local s = T('手上 %1 件，买入价 %2，现值 %3', held, game:money(basis), game:money(held * price))
    lines[#lines + 1] = pr >= 0 and s .. T('，赚 %1', game:money(pr)) or s .. T('，亏 %1', game:money(-pr))
  else
    lines[#lines + 1] = '手上没有这种货。'
  end
  show({
    title = good.name,
    lines = lines,
    rows = {
      { { '买入', function()
          close_modal()
          choose_amount(T('买入 %1', good.name), game:maxBuy(i), function(v)
            local ok, err = game:buy(i, v)
            if ok then status = T('买入 %1 件%2，花了 %3。', v, good.name, game:money(v * game.prices[i]))
            else status = err or '买不了。' end
          end, false, '买入', T('现价 %1 · 现金 %2', game:money(game.prices[i]), game:money(game.cash)))
        end, game:maxBuy(i) > 0 },
        { '卖出', function()
          close_modal()
          choose_amount(T('卖出 %1', good.name), held, function(v)
            local p = game.prices[i]
            local ok, err = game:sell(i, v)
            if ok then
              local gain = math.floor(v * (p - basis))
              status = T('卖出 %1 件%2：买入价 %3，现价 %4，到手 %5，%6。', v, good.name,
                game:money(basis), game:money(p), game:money(v * p),
                gain >= 0 and T('赚了 %1', game:money(gain)) or T('亏了 %1', game:money(-gain)))
            else status = err or '卖不了。' end
          end, false, '卖出', T('买入价 %1 · 现价 %2', game:money(basis), game:money(game.prices[i])))
        end, held > 0 } },
      { { '取消', close_modal } },
    },
    cancel = close_modal,
  })
end

local over_box

local function next_round()
  close_modal()
  if game.round >= Data.MAX_ROUNDS then end_game(); return end      -- 最后一回合：结束游戏
  local r = game:nextRound()
  save()
  if r.over then over_box(); return end
  -- 特殊事件和价格变化分开摆：两样都要让玩家看见
  local lines = {}
  if #r.events > 0 then
    lines[#lines + 1] = '—— 特殊事件 ——'
    for _k, s in ipairs(r.events) do lines[#lines + 1] = s end
  end
  if #r.moves > 0 then
    lines[#lines + 1] = '—— 行情变化 ——'
    for _k, s in ipairs(r.moves) do lines[#lines + 1] = s end
  end
  if #lines == 0 then lines[1] = T('第 %1 回合，行情没什么变化。', game.round) end
  show({ title = T('第 %1 回合', game.round), lines = lines,
    rows = { { { '知道了', close_modal } } }, cancel = close_modal })
end

-- 买房：五个档位，够钱就能点；已经有一套的按原价抵扣，只补差价
local function house_box()
  local lines, rows = {}, {}
  for i, h in ipairs(Data.HOUSES) do
    if i <= game.owned then
      lines[#lines + 1] = T('%1 · %2 · 已拥有', h.name, game:money(h.price))
    else
      local cost = game:houseCost(i)
      local gap = cost - game.cash
      if gap > 0 then
        lines[#lines + 1] = T('%1 · %2 · 还差 %3', h.name, game:money(h.price), game:money(gap))
      elseif game.owned > 0 then
        lines[#lines + 1] = T('%1 · %2 · 补差价 %3 就能换', h.name, game:money(h.price), game:money(cost))
      else
        lines[#lines + 1] = T('%1 · %2 · 现在就能买', h.name, game:money(h.price))
      end
    end
  end
  lines[#lines + 1] = T('现金 %1 · 净资产 %2', game:money(game.cash), game:money(game:netWorth()))
  for i, h in ipairs(Data.HOUSES) do
    rows[#rows + 1] = { { h.name, function()
        close_modal()
        local ok, msg = game:buyHouse(i)
        save()
        if ok then
          record(game:netWorth(), game.owned)
          record_house(i)
          info({ msg, T('手里还剩 %1。60 个回合还没用完，还能接着换更好的。', game:money(game.cash)) })
        else
          status = msg or '买不了。'
        end
      end, game:canBuyHouse(i) } }
  end
  rows[#rows + 1] = { { '关闭', close_modal } }
  show({ title = '买房：五档，够钱就能买', lines = lines, rows = rows, cancel = close_modal })
end

local function sell_all_box()
  local n, got = 0, 0
  for i = 1, #Data.GOODS do
    local held = game.inventory[i] or 0
    n = n + held
    got = got + held * (game.prices[i] or 0)
  end
  if n == 0 then status = '仓库是空的，没什么可清。'; return end
  show({
    title = '一键清仓',
    lines = { T('把手上 %1 件货全卖掉，到手 %2。', n, game:money(got)) },
    rows = { { { '清仓', function()
        close_modal()
        local c, g = game:sellAll(); save()
        status = T('卖出 %1 件，到手 %2。', c, game:money(g))
      end }, { '取消', close_modal } } },
    cancel = close_modal,
  })
end

local function market_box()
  local lines = {}
  for i, good in ipairs(Data.GOODS) do
    local p = game.prices[i]
    local prev = game.prev[i] or p
    local mark = p > prev and '▲' or (p < prev and '▼' or '—')
    if show_base() then
      lines[#lines + 1] = T('%1%2 %3（基准 %4）%5', mark, good.name, game:money(p), game:money(good.base), game:tip(i))
    else
      -- 普通难度：只给看得见的事实 —— 现价和比上一回合动了多少
      local d = prev > 0 and math.floor((p - prev) / prev * 100 + 0.5) or 0
      local chg = d == 0 and '与上回合持平' or (d > 0 and T('较上回合 +%1%', d) or T('较上回合 %1%', d))
      lines[#lines + 1] = T('%1%2 %3 · %4', mark, good.name, game:money(p), chg)
    end
    local held = game.inventory[i] or 0
    if held > 0 then lines[#lines] = lines[#lines] .. T(' · 存 %1 件，买入价 %2', held, game:money(game:costBasis(i))) end
  end
  lines[#lines + 1] = '—— 最近的行情 ——'
  for _k, s in ipairs(game.log) do lines[#lines + 1] = s end
  show({ title = T('行情（%1）', diff().name), lines = lines, rows = { { { '关闭', close_modal } } }, cancel = close_modal })
end

-- 彩票站：只有一种玩法，六格刮刮乐

-- 这一张卡刮完了，把六个格子的结果报一遍
local function card_report(total, amounts, extra)
  local parts, blanks = {}, 0
  for _k, a in ipairs(amounts or {}) do
    if a > 0 then parts[#parts + 1] = game:money(a) else blanks = blanks + 1 end
  end
  if blanks > 0 then parts[#parts + 1] = T('笑脸 × %1', blanks) end
  local lines = { T('六个格子：%1', table.concat(parts, ' · ')) }
  if total > 0 then
    local d = total - Data.LOTTERY.price
    lines[#lines + 1] = T('一共刮出 %1', game:money(total))
    lines[#lines + 1] = T('票价 %1，这一张%2', game:money(Data.LOTTERY.price),
      d > 0 and T('赚了 %1', game:money(d)) or (d < 0 and T('亏了 %1', game:money(-d)) or '刚好回本'))
  else
    lines[#lines + 1] = '六格全是笑脸，一张都没刮出来。'
    lines[#lines + 1] = T('票价 %1 就这么没了。', game:money(Data.LOTTERY.price))
  end
  for _k, m in ipairs(extra or {}) do lines[#lines + 1] = m end
  lines[#lines + 1] = T('现金 %1。', game:money(game.cash))
  return lines
end

-- 这三个屏互相串着来：先挂个名字，下面再一个一个定义
local scratch_box, scratch_all, cash_in

-- 六个格子全刮开之后：把卡交回站里，钱入账
cash_in = function()
  local total, amounts, extra = game:cashCard()
  save()
  if total == nil then lottery_box(); return end
  info(card_report(total, amounts, extra), lottery_box)
end

-- 卡上还有没刮开的：一把全刮了，省得一个个点
scratch_all = function()
  for k = 1, Data.LOTTERY.cells do game:scratchCell(k) end
  save()
  scratch_box()
end

-- 刮刮卡这一屏：六个盖着涂层的格子，点一格开一格；全刮完了自己按收下
scratch_box = function()
  local amounts, open = game:lotteryCard()
  if not amounts then lottery_box(); return end
  local cells = {}
  for k = 1, #amounts do
    cells[k] = { amount = amounts[k], open = open[k], fn = function()
        game:scratchCell(k)
        save()
        scratch_box()
      end }
  end
  local n = game:cardOpenCount()
  local lines = {
    T('已经刮开 %1 / %2 格，到手 %3。', n, #amounts, game:money(game:cardRevealedTotal())),
  }
  if n == 0 then lines[#lines + 1] = T('点一个格子刮一下。票价 %1。', game:money(Data.LOTTERY.price)) end
  local rows = {}
  if game:cardDone() then
    rows[#rows + 1] = { { '收下这笔钱', cash_in } }
  else
    rows[#rows + 1] = { { '剩下的全刮开', scratch_all } }
  end
  rows[#rows + 1] = { { '关闭', close_modal } }
  show({
    title = T('刮刮乐 · 第 %1 张', game.lotto_n or 1),
    lines = lines, cells = cells, rows = rows,
    cancel = close_modal,
  })
end

lottery_box = function()
  local L = Data.LOTTERY
  local holding = game:lotteryCard() ~= nil
  local can = select(1, game:canLottery())
  -- 六个格子各自的金额：给玩家看看这一张最多能刮出什么
  local tops = {}
  for _k, p in ipairs(L.CELL_PRIZES) do if p.amount > 0 then tops[#tops + 1] = p.amount end end
  table.sort(tops, function(a, b) return a > b end)
  local lines = {
    T('%1 一张 · 六个格子 · 还剩 %2 张', game:money(L.price), game:lotteryLeft()),
    '一格一格点开，刮出金额就攒着',
    '是笑脸就是没中，六格加起来算总账',
    T('一格最多 %1 · 奖池 %2', game:money(tops[1] or 0), game:money(game:lotteryPool())),
    T('每张票 1/%1 的机会独得奖池', L.pool_chance),
    T('本局 %1 张 · 花 %2 · 中 %3', game.lotto_n or 0, game:money(game.lotto_spent or 0), game:money(game.lotto_win or 0)),
  }
  if game:lotteryFree() > 0 then lines[#lines + 1] = T('手上还有 %1 张白得的券。', game:lotteryFree()) end
  if holding then lines[#lines + 1] = '手上那张还没刮完。' end
  show({
    title = '彩票站',
    lines = lines,
    rows = {
      { { holding and '接着刮' or T('买一张（%1）', game:money(L.price)), function()
          close_modal()
          if holding then scratch_box(); return end
          local ok, err = game:buyLottery()
          if ok then save(); scratch_box() else status = err or '买不了。' end
        end, holding or can } },
      { { '关闭', close_modal } },
    },
    cancel = close_modal,
  })
end

-- 难度：只改看得见多少信息，不影响钱和价格
difficulty_box = function()
  local lines, rows = {}, {}
  for i, d in ipairs(Data.DIFFICULTY) do
    lines[#lines + 1] = (i == difficulty and '▸ ' or '') .. d.name .. '：' .. d.desc
    rows[#rows + 1] = { { i == difficulty and T('%1（当前）', d.name) or d.name, function()
        close_modal()
        difficulty = i
        save_settings()
        status = T('难度：%1。%2', d.name, d.desc)
      end, i ~= difficulty } }
  end
  rows[#rows + 1] = { { '关闭', close_modal } }
  show({ title = '难度：只改显示多少信息', lines = lines, rows = rows, cancel = close_modal })
end

local function scores_box()
  local h = best_house > 0 and Data.HOUSES[best_house].name or '一套都没买过'
  local lines = {
    T('最高净资产：%1', game:money(best_net)),
    T('买到过最好的房子：%1（%2）', h, best_house > 0 and Data.HOUSES[best_house].rank or Data.NO_HOUSE_RANK),
    '—— 各房型买到过几次 ——',
  }
  -- 每一档历年一共买到过几次（往上换房时每一档各记一次）
  for i, hh in ipairs(Data.HOUSES) do
    lines[#lines + 1] = T('%1 · %2 · %3 次', hh.name, game:money(hh.price), math.floor(house_wins[i] or 0))
  end
  lines[#lines + 1] = T('历年一共买到 %1 次。', total_house_wins())
  lines[#lines + 1] = '往上换房时，每一档各记一次。'
  show({
    title = '历史成绩',
    lines = lines,
    rows = { { { '关闭', close_modal } } },
    cancel = close_modal,
  })
end

local function new_game_box()
  show({
    title = '重新开始？现在这一局就没了。',
    rows = { { { '新游戏', function() close_modal(); game:newGame(); save(); status = '新的一局：2000 元，60 个回合。' end },
               { '取消', close_modal } } },
    cancel = close_modal,
  })
end

local function finish_game()
  game:finish()
  save()
  over_box()
end

-- 最后一回合点"结束游戏"：还没买房、而钱又够，先问一句要不要先买
end_game = function()
  close_modal()
  if game.over then over_box(); return end
  if game.owned <= 0 then
    local best_i = nil                                  -- 现金买得起的最高一档
    for i = #Data.HOUSES, 1, -1 do if game:canBuyHouse(i) then best_i = i; break end end
    if best_i then
      local h = Data.HOUSES[best_i]
      show({
        title = '这是最后一回合了',
        lines = { T('手上还有 %1，够买%2（%3）。', game:money(game.cash), h.name, game:money(h.price)),
          '结束之后这一局就定格了，房子就买不成了。' },
        rows = { { { '先买房', function() close_modal(); house_box() end },
                   { '直接结束', function() close_modal(); finish_game() end } } },
        cancel = close_modal,
      })
      return
    end
    local after = game.cash + game:stockValue()           -- 清仓之后能凑到多少
    if game:held() > 0 and after >= Data.HOUSES[1].price then
      show({
        title = '这是最后一回合了',
        lines = { T('现金只有 %1，但把手上 %2 件货清掉能有 %3，够买%4。', game:money(game.cash),
            game:held(), game:money(after), Data.HOUSES[1].name),
          '结束之后这一局就定格了，房子就买不成了。' },
        rows = { { { '先清仓', function() close_modal(); game:sellAll(); save(); end_game() end },
                   { '直接结束', function() close_modal(); finish_game() end } } },
        cancel = close_modal,
      })
      return
    end
  end
  finish_game()
end

over_box = function()
  -- 收摊时手上还捏着没刮完的卡：已经刮出来的那几格还是算数，剩下的归站里
  local card_got = 0
  if game:lotteryCard() then
    local t = game:cashCard()
    card_got = t or 0
    save()
  end
  local net = game:netWorth()
  record(net, game.owned)
  local house = game.owned > 0 and Data.HOUSES[game.owned].name or '没买到房'
  local lines = {
    T('净资产：%1', game:money(net)),
    T('房产：%1 · %2', house, game:rank()),
    T('历史最好：%1', game:money(best_net)),
    game.owned > 0 and T('%1 个回合里，你从 %2 做到了有房的人。', game.round, game:money(Data.START_CASH))
      or T('%1 个回合过去了，房子还是别人的。再来一局？', game.round),
  }
  if card_got > 0 then
    lines[#lines + 1] = T('手上那张刮刮乐刮出 %1。', game:money(card_got))
  end
  show({ title = '六十回合结束', lines = lines,
    rows = { { { '新游戏', function() close_modal(); game:newGame(); save() end } } } })
end

------------------------------------------------------------------ 那一屏

local MARKET_Y, ROW, BTN_Y, BTN_H, BTN_GAP = 104, 57, 566, 52, 10

-- 最后一回合：那颗按钮不再说"下一回合"，而是"结束游戏"
local function next_label()
  return game.round >= Data.MAX_ROUNDS and '结束游戏' or '下一回合'
end

-- 底部三行按钮：每行里的按钮平分整行宽度
local function button_rows()
  return {
    { { next_label(), next_round }, { '买房', house_box }, { '彩票', function() lottery_box() end } },
    { { '一键清仓', sell_all_box }, { '行情', market_box }, { '难度', function() difficulty_box() end } },
    { { '新游戏', new_game_box }, { '成绩', scores_box } },
  }
end
local function button_rects()
  local out, y = {}, BTN_Y
  for _r, row in ipairs(button_rows()) do
    local n = #row
    local bw = math.floor((W - 16 - (n - 1) * 8) / n)
    for k, btn in ipairs(row) do
      out[#out + 1] = { x = 8 + (k - 1) * (bw + 8), y = y, w = bw, h = BTN_H, b = btn }
    end
    y = y + BTN_H + BTN_GAP
  end
  return out
end

local function draw_board(gg, top_only)
  gg:text(16, 10, short(T('现金 %1', game:money(game.cash)), 30), { font = font('large') })
  local round = T('第 %1 / %2 回合', game.round, Data.MAX_ROUNDS)
  gg:text(W - 16 - width(font('medium'), round), 14, round, { font = font('medium') })
  gg:text(16, 48, short(T('净资产 %1 · 持仓 %2 件', game:money(game:netWorth()), game:held()), 52), { font = font('small') })
  local house = game.owned > 0 and T('房产 %1（%2）', Data.HOUSES[game.owned].name, game:money(game:houseValue())) or T('房产 无 · %1', Data.NO_HOUSE_RANK)
  gg:text(16, 72, short(house, 52), { font = font('small') })
  gg:line(0, 96, W, 96)
  if top_only then return end        -- 弹窗开着：剩下的屏幕归它
  for i, good in ipairs(Data.GOODS) do
    local y = MARKET_Y + (i - 1) * ROW
    local p = game.prices[i]
    local prev = game.prev[i] or p
    local mark = p > prev and '▲' or (p < prev and '▼' or '—')
    local ps = mark .. ' ' .. game:money(p)
    gg:text(16, y + 2, short(good.name, 16), { font = font('medium') })
    gg:text(W - 16 - width(font('medium'), ps), y + 2, ps, { font = font('medium') })
    local held = game.inventory[i] or 0
    local sub
    if held > 0 then
      -- 自己的账本：买入价和赚亏两个难度都给看
      sub = T('存 %1 件 · 本 %2 · 值 %3', held, game:money(game:costBasis(i)), game:money(held * p))
      local pr = game:profit(i)
      if pr > 0 then sub = sub .. T(' · 赚 %1', game:money(pr))
      elseif pr < 0 then sub = sub .. T(' · 亏 %1', game:money(-pr)) end
    elseif show_base() then
      sub = T('基准 %1 · %2', game:money(good.base), game:tip(i))
    else
      local d = prev > 0 and math.floor((p - prev) / prev * 100 + 0.5) or 0
      sub = d == 0 and '与上回合持平' or (d > 0 and T('较上回合 +%1%', d) or T('较上回合 %1%', d))
    end
    gg:text(16, y + 28, short(sub, 52), { font = font('small') })
    gg:line(16, y + 50, W - 16, y + 50)
  end
  for _k, bt in ipairs(button_rects()) do
    gg:rect(bt.x, bt.y, bt.w, bt.h)
    local f = font('small')
    local label = tostring(bt.b[1])
    while #label > 1 and width(f, label) > bt.w - 10 do label = drop_last(label) end
    gg:text(bt.x + math.floor((bt.w - width(f, label)) / 2), bt.y + 16, label, { font = f })
  end
  -- 底下两行给状态：卖出后那句"买入价多少、现价多少"一句话写不下，拆两行
  local hint = status ~= '' and status
    or (game.round >= Data.MAX_ROUNDS and '最后一回合了：点“结束游戏”收摊。' or '点商品买卖，点“下一回合”进入下一回合。')
  local sl = wrap(hint, 'small', W - 32)
  gg:text(16, H - 46, short(sl[1] or '', 60), { font = font('small') })
  if ERR then gg:text(16, H - 24, short('ERR ' .. ERR, 52), { font = font('small') })
  elseif sl[2] and sl[2] ~= '' then gg:text(16, H - 24, short(sl[2], 60), { font = font('small') }) end
end

function on_draw(c, gg)
  if not gg then return end
  local ok, e = pcall(function()
    gg:clear(0)
    draw_board(gg, modal ~= nil)
    if modal then draw_modal(gg) end
  end)
  if not ok then pcall(function() gg:text(8, H - 70, short('draw ERR ' .. tostring(e), 46)) end) end
end

local KEY_GAP_MS = 250
local last_key, last_key_ms = nil, nil
local function key_accepted(ev)
  local ph = ev.phase or ev.action or ev.state
  if ph == 'up' or ph == 'release' or ph == 'released' or ev.pressed == false or ev.down == false then return false end
  local now = tonumber(ev.time_ms)
  if not now then local ok, m = pcall(function() return ctx.clock:millis() end); now = ok and tonumber(m) or nil end
  if now and last_key == ev.key and last_key_ms and now - last_key_ms >= 0 and now - last_key_ms < KEY_GAP_MS then return false end
  last_key, last_key_ms = ev.key, now
  return true
end

local function tap(x, y)
  if modal then
    local _l, btns, my, mh, cells = layout_modal(modal)
    for _k, cl in ipairs(cells) do
      if x >= cl.x and x < cl.x + cl.w and y >= cl.y and y < cl.y + cl.h then
        if cl.c.fn then cl.c.fn() end
        return
      end
    end
    for _k, bt in ipairs(btns) do
      if x >= bt.x and x < bt.x + bt.w and y >= bt.y and y < bt.y + bt.h then
        if bt.b[3] ~= false then bt.b[2]() end
        return
      end
    end
    if (y < my or y > my + mh or x < BOX_X or x > BOX_X + BOX_W) and modal.cancel then modal.cancel() end
    return
  end
  status = ''
  for _k, bt in ipairs(button_rects()) do
    if x >= bt.x and x < bt.x + bt.w and y >= bt.y and y < bt.y + bt.h then bt.b[2](); return end
  end
  if y >= MARKET_Y and y < MARKET_Y + #Data.GOODS * ROW then trade(math.floor((y - MARKET_Y) / ROW) + 1) end
end

-- 返回键：弹窗开着就先关弹窗；没有弹窗就**不认领**这个事件，交回系统，让系统弹"离开应用"。
-- on_input 返回 true 是"这个事件归我"，系统就再也看不到了 —— 以前无条件返回 true，
-- 返回键被吃掉，所以怎么按都退不出去。
function on_input(c, ev)
  ERR = nil
  local back_to_system = false
  local ok, e = pcall(function()
    if type(ev) ~= 'table' then return end
    if ev.type == 'pointer' and ev.phase == 'up' then
      tap(ev.x or 0, ev.y or 0)
    elseif ev.type == 'key' and ev.key == 'back' then
      if modal and modal.cancel then
        if key_accepted(ev) then modal.cancel() end
      else
        back_to_system = true       -- 交给系统：弹出"离开应用"
      end
    end
  end)
  if not ok then ERR = tostring(e) end
  if back_to_system then save() end
  refresh()
  return not back_to_system
end

function on_load(c)
  load_best()
  load_settings()
  game = Game:new()
  if not load_saved() then game:newGame(); save() end
  if game.over then over_box(); return end
  -- 上一回退出时卡上还有没刮完的，进来就提醒一下
  if game:lotteryCard() then
    status = T('手上那张刮刮乐还剩 %1 格没刮。', Data.LOTTERY.cells - game:cardOpenCount())
  end
end

function on_leave() save() end
