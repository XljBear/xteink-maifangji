"""买房记（API 2.9）的离线测试：在 Lua 5.5（lupa）里把 src/ 打成 index.lua，然后照着设备那
一屏点一遍——买卖、推进回合、买房与置换、行情、成绩、存档与重载、60 个回合的结局。

  python -I test_fangchan.py
"""
import os, re, subprocess, sys
import lupa

LUA = lupa.lua55 if hasattr(lupa, 'lua55') else lupa.lua54

HERE = os.path.dirname(os.path.abspath(__file__))
subprocess.run([sys.executable, '-I', os.path.join(HERE, 'bundle.py')], check=True)
L = LUA.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
drawn, store, inputs = {}, {}, {}
fake_ms = 20260101
local gmt = {}
gmt.__index = function(_, k) return function(_, ...)
  if k == 'text' then local x, y, s, o = ...; drawn[#drawn + 1] = { s = s, x = x, y = y, f = (o or {}).font and (o.font).fname or 'medium' }
  elseif k == 'circle' then local x, y, r = ...; drawn[#drawn + 1] = { s = '<circle>', x = x, y = y, r = r }
  elseif k == 'polyline' then local p = ...; drawn[#drawn + 1] = { s = '<polyline>', x = p[1], y = p[2], pts = p }
  elseif k == 'line' then local x1, y1, x2, y2 = ...; drawn[#drawn + 1] = { s = '<line>', x = x1, y = y1, x2 = x2, y2 = y2 }
  elseif k == 'rect' then local x, y, w, h = ...; drawn[#drawn + 1] = { s = '<rect>', x = x, y = y, w = w, h = h } end
end end
gg = setmetatable({}, gmt)
local function M(t)
  local out = {}
  for k, f in pairs(t) do
    if type(f) == 'function' then out[k] = function(self, ...) assert(self == out, 'method call expected for ' .. k); return f(...) end
    else out[k] = f end
  end
  return out
end
-- 汉字按两个西文字符宽来量，和设备的字体差不多
local function font(name, lh)
  local f = M({ measure = function(s)
    local n = 0
    for p, c in utf8.codes(s) do n = n + (c >= 0x2E80 and 24 or 12) end
    return n
  end })
  f.line_height = lh
  f.fname = name
  return f
end
ctx = {
  invalidate = function() end,
  storage = M({ write = function(n, d) store[n] = d; return true end, read = function(n) if store[n] then return store[n] end return nil, 'not_found' end }),
  fonts = { small = font('small', 20), medium = font('medium', 24), large = font('large', 30) },
  input = M({ text = function(opts, fn) inputs[#inputs + 1] = fn end }),
  clock = M({ millis = function() return fake_ms end }),
}
''')
INDEX = os.path.join(HERE, 'index.lua').replace(os.sep, '/')


def start():
    L.execute(f"dofile([[{INDEX}]])")
    gl = L.globals()
    gl.on_load(gl.ctx)
    return gl


g = start()
tap_ = L.eval("function(x, y) on_input(ctx, {type='pointer', phase='down', x=x, y=y}); on_input(ctx, {type='pointer', phase='up', x=x, y=y}) end")
key = L.eval("function(k) fake_ms = fake_ms + 300; on_input(ctx, {type='key', key=k}) end")
draw = L.eval(r"function() drawn = {}; on_draw(ctx, gg); for _, d in ipairs(drawn) do if not utf8.len(d.s) then error('invalid UTF-8 drawn: ' .. tostring(d.s)) end end; return drawn end")


def texts():
    return [str(v.s) for v in draw().values()]


def recs():
    out = {}
    for r in draw().values():
        out[str(r.s)] = (int(r.x), int(r.y))          # 同一个字出现多次时取最后画的那个
    return out


def tap_label(label):
    r = recs()
    assert label in r, (label, list(r))
    x, y = r[label]
    tap_(x + 3, y + 5)


def no_err():
    t = texts()
    assert not any('ERR' in x for x in t), t


def num(s):
    return int(re.sub(r'[^\d]', '', s))


def cash():
    return num([x for x in texts() if x.startswith('现金 ')][0])


def held_qty():                        # '存 66 件 · 值 ¥1,584 · 便宜' → 66
    for x in texts():
        m = re.match(r'^存 (\d+) 件', x)
        if m:
            return int(m.group(1))
    raise AssertionError(texts())


def round_no():                       # '第 12 / 60 回合' → 12
    for x in texts():
        m = re.match(r'^第 (\d+) / 60 回合$', x)
        if m:
            return int(m.group(1))
    raise AssertionError(texts())


def field(save, key):
    m = re.search(r'^' + key + r'=([^\n]*)$', save, re.M)
    assert m, (key, save)
    return m.group(1)


MARKET_Y, ROW = 104, 57

# ---------------------------------------------------------------- 开局那一屏
t = texts()
assert '现金 ¥2,000' in t and '第 1 / 60 回合' in t, t
assert '净资产 ¥2,000 · 持仓 0 件' in t, t
assert '房产 无 · 还在租房' in t, t
for name in ('白菜', '大米', '棉布', '煤炭', '钢材', '手机', '白酒', '黄金'):
    assert name in t, name
for b in ('下一回合', '买房', '彩票', '一键清仓', '行情', '难度', '新游戏', '成绩'):
    assert b in t, b
assert 'game.txt' in g.store, list(g.store)
assert field(g.store['game.txt'], 'round') == '1'

# ---------------------------------------------------------------- 买入 → 卖出
tap_(100, MARKET_Y + 20)                                   # 第一行：白菜
t = texts()
assert '白菜' in t and '买入' in t and '(卖出)' in t and '取消' in t, t      # 手上没货，卖出是灰的
assert any(x.startswith('基准 ¥') and '手上共' in x for x in t), t
tap_label('买入')
assert any(x.startswith('最多 ') for x in texts()), texts()       # 件数，不是钱
tap_label('全部')
tap_label('买入')
no_err()
t = texts()
held = held_qty()
assert held > 0, t
assert cash() < 2000, t
assert re.match(r'^[1-9]', field(g.store['game.txt'], 'inv')), g.store['game.txt']
spent = int(field(g.store['game.txt'], 'inv').split(',')[0]) * int(field(g.store['game.txt'], 'prices').split(',')[0])
assert spent + cash() == 2000, (spent, cash())                   # 没有仓库上限：钱全花光
assert cash() < 2000, cash()

tap_(100, MARKET_Y + 20)
t = texts()
assert any('买入价 ¥' in x for x in t), t                    # 手上这批货的买入价
tap_label('卖出')
t = texts()
assert any(x.startswith('买入价 ¥') for x in t), t            # 卖出数量框里也写明了
tap_label('1/2')
tap_label('卖出')
no_err()
held2 = held_qty()
assert held2 == held - held // 2, (held, held2)
t = ' '.join(texts())
assert '买入价' in t and '现价' in t and '到手' in t, t                   # 卖完报一次账
cash_after_sell = cash()

# ---------------------------------------------------------------- 推进一个回合
tap_label('下一回合')
t = texts()
assert '知道了' in t, t
tap_label('知道了')
no_err()
t = texts()
assert '第 2 / 60 回合' in t, t
assert field(g.store['game.txt'], 'round') == '2', g.store['game.txt']    # 每回合自动存档

# ---------------------------------------------------------------- 行情、成绩
tap_label('行情')
t = texts()
assert '行情（简单）' in t and any('基准' in x for x in t), t
tap_label('关闭')
tap_label('成绩')
t = texts()
assert any(x.startswith('最高净资产：') for x in t), t
assert '—— 各房型买到过几次 ——' in t, t
assert '城中村单间 · ¥15,000 · 0 次' in t, t                        # 还没买过
assert '历年一共买到 0 次' in ' '.join(t), t
tap_label('关闭')

# ---------------------------------------------------------------- 买房（给一笔钱，走存档）
save = g.store['game.txt']
g.store['game.txt'] = re.sub(r'^cash=\d+$', 'cash=50000', save, flags=re.M)
g = start()
assert '现金 ¥50,000' in texts(), texts()
tap_label('买房')
t = texts()
assert '城中村单间' in t and '(独栋别墅)' in t, t                  # 贵的档位买不起，是灰的
assert '现在就能买' in ' '.join(t), t
price1 = num([x for x in t if x.startswith('城中村单间 · ¥')][0].split(' · ')[1])
tap_label('城中村单间')
tap_label('知道了')
no_err()
t = texts()
assert '房产 城中村单间' in ' '.join(t), t
assert cash() == 50000 - price1, (cash(), price1)
assert field(g.store['game.txt'], 'owned') == '1'
assert 'net=' in g.store['best.txt'], g.store.get('best.txt')
assert field(g.store['best.txt'], 'wins') == '1,0,0,0,0', g.store['best.txt']   # 单间记一次

# 置换：旧房按原价抵扣，只补差价
g.store['game.txt'] = re.sub(r'^cash=\d+$', 'cash=200000', g.store['game.txt'], flags=re.M)
g = start()
tap_label('买房')
t = texts()
price3 = num([x for x in t if x.startswith('学区三居 · ¥')][0].split(' · ')[1])
assert ('补差价 ¥%s' % f'{price3 - price1:,}') in ' '.join(t), t     # 旧房按原价抵扣
tap_label('学区三居')
tap_label('知道了')
no_err()
t = texts()
assert '房产 学区三居' in ' '.join(t), t
assert cash() == 200000 - (price3 - price1), (cash(), price1, price3)
assert field(g.store['best.txt'], 'wins') == '1,0,1,0,0', g.store['best.txt']   # 换房各记一档

# 成绩页里能看到各房型累计买到过几次
tap_label('成绩')
t = texts()
assert '城中村单间 · ¥15,000 · 1 次' in t, t
assert '学区三居 · ¥150,000 · 1 次' in t, t
assert '老破小两居 · ¥50,000 · 0 次' in t, t
assert '独栋别墅 · ¥1,200,000 · 0 次' in t, t
assert '历年一共买到 2 次' in ' '.join(t), t
tap_label('关闭')

# ---------------------------------------------------------------- 存档与重载一致
before = g.store['game.txt']
g = start()
assert g.store['game.txt'] == before, (before, g.store['game.txt'])
assert '房产 学区三居' in ' '.join(texts()), texts()
assert re.match(r'^[1-9]', field(g.store['game.txt'], 'basis')), g.store['game.txt']
assert any('· 本 ¥' in x for x in texts()), texts()          # 买入价也一起存下来了
tap_label('成绩')                                            # 买过几次也要能读回来
assert '城中村单间 · ¥15,000 · 1 次' in texts(), texts()
tap_label('关闭')

# ---------------------------------------------------------------- 一键清仓
tap_(100, MARKET_Y + 20)
tap_label('买入')
tap_label('全部')
tap_label('买入')
tap_label('一键清仓')
t = texts()
assert '一键清仓' in t and '清仓' in t, t
tap_label('清仓')
no_err()
assert '持仓 0 件' in ' '.join(texts()), texts()

# ---------------------------------------------------------------- 新游戏
tap_label('新游戏')
tap_label('新游戏')
t = texts()
assert '第 1 / 60 回合' in t and '现金 ¥2,000' in t and '房产 无' in ' '.join(t), t

# ---------------------------------------------------------------- 难度：简单看得见基准价，普通看不见
t = texts()
assert any(x.startswith('基准 ¥') for x in t), t                # 开局默认简单
tap_label('难度')
t = texts()
assert '(简单（当前）)' in t and '普通' in t, t                  # 当前难度是灰的
tap_label('普通')
no_err()
assert field(g.store['settings.txt'], 'difficulty') == '2', g.store.get('settings.txt')
t = texts()
assert not any(x.startswith('基准 ¥') for x in t), t            # 普通：基准价和便宜提示都没了
assert '与上回合持平' in t, t                                    # 只给看得见的事实
tap_label('行情')
t = texts()
assert not any('基准' in x for x in t), t
assert '行情（普通）' in t, t
tap_label('关闭')
tap_label('难度')
tap_label('简单')
no_err()
assert 'settings.txt' in g.store and field(g.store['settings.txt'], 'difficulty') == '1'
assert any(x.startswith('基准 ¥') for x in texts()), texts()

# ------------------------------------------------------------ 彩票站：六格刮刮乐
def lotto_line(prefix):
    for x in texts():
        if x.startswith(prefix):
            return x
    raise AssertionError((prefix, texts()))


def pool():                       # '一格最多 ¥5,000 · 奖池 ¥500' → 500
    return num(lotto_line('一格最多 ¥').split('奖池 ¥')[1])


def cells():                      # 六个格子的左上角坐标，按从左到右、从上到下
    return [(int(r.x), int(r.y)) for r in draw().values()
            if str(r.s) == '<rect>' and int(r.w) == 126 and int(r.h) == 100]


def cell_tap(k):                  # 点第 k 格的正中间
    x, y = cells()[k - 1]
    tap_(x + 63, y + 50)


def marks(tag):                   # 画出来的某种图元有几个
    return sum(1 for r in draw().values() if str(r.s) == tag)


def too_wide():                   # 弹窗里超宽、会被折行的那几行（弹窗里一行最多 400px）
    w = L.eval("function(s) return ctx.fonts.small:measure(s) end")
    return [str(r.s) for r in draw().values()
            if not str(r.s).startswith('<') and int(r.x) == 40 and w(str(r.s)) > 400]


tap_label('彩票')
t = texts()
assert '彩票站' in t, t
assert lotto_line('¥200 一张 · 六个格子 · 还剩 3 张'), t
assert any('六格加起来算总账' in x for x in t), t
assert not too_wide(), too_wide()
pool0 = pool()
assert pool0 >= 500, pool0

# 买一张：六个格子都盖着涂层，一格都还没刮
cash_before = cash()
tap_label('买一张（¥200）')
t = texts()
assert cash() == cash_before - 200, (cash(), cash_before)
assert any(x.startswith('刮刮乐 · 第 1 张') for x in t), t
assert lotto_line('已经刮开 0 / 6 格'), t
cs = cells()
assert len(cs) == 6, (len(cs), t)
assert not too_wide(), too_wide()
assert marks('<line>') >= 40, marks('<line>')         # 六个格子都盖着斜线涂层
card0 = int(field(g.store['game.txt'], 'lotto').split(',')[5])
assert card0 > 0, g.store['game.txt']                 # 六个格子的奖随手存进存档
assert field(g.store['game.txt'], 'lotto').split(',')[7] == '0'

# 一格一格刮开：每刮一格，那一格的涂层就没了，攒的钱跟着涨
def revealed():
    line = lotto_line('已经刮开 ')
    n = int(line.split('已经刮开 ')[1].split(' / ')[0])
    return n, num(line.split('到手 ¥')[1].rstrip('。'))


total, smiles = 0, 0
for k in range(1, 6):
    n0, v0 = revealed()
    assert n0 == k - 1, (k, texts())
    cell_tap(k)
    n1, v1 = revealed()
    assert n1 == k, (k, texts())
    got = v1 - v0
    if got == 0:
        smiles += 1
        assert marks('<circle>') >= 3 and marks('<polyline>') >= 1, (k, texts())   # 画了张脸
    else:
        total += got
    assert marks('<line>') <= 49 - k * 8, (k, marks('<line>'))     # 那一格的涂层没了

# 刮到第六格：六个都开了，先把整张卡摆出来看看，再自己按收下
cash_now = cash()
cell_tap(6)
t = texts()
assert any(x.startswith('已经刮开 6 / 6 格') for x in t), t
assert not too_wide(), too_wide()
assert cash() == cash_now, (cash(), cash_now)            # 还没收下，钱还没到账
assert marks('<line>') <= 2, marks('<line>')             # 涂层全刮没了
tap_label('收下这笔钱')
t = texts()
assert any(x.startswith('六个格子：') for x in t), t
assert any(x.startswith('一共刮出 ¥') or x.startswith('票价 ¥200 就这么没了') for x in t), t
assert cash() - cash_now == total, (cash(), cash_now, total)        # 六格累加的钱一次到账
assert marks('<line>') <= 2, marks('<line>')                        # 涂层全刮没了
tap_label('知道了')
assert pool() == pool0 + 10, (pool0, texts())          # 每张票往奖池里注 ¥10
assert '彩票站' in texts(), texts()
assert cash() == cash_before - 200 + total, (cash(), cash_before, total)
assert field(g.store['game.txt'], 'lotto').split(',')[5] == '0'   # 交回去了，手上没卡了
assert total > 0 or smiles == 6, (total, smiles)

# 手上有没刮完的卡，就不能再买一张：按钮变成"接着刮"
tap_label('买一张（¥200）')
cell_tap(1)
cell_tap(2)
tap_label('关闭')
tap_label('彩票')
t = texts()
assert '接着刮' in t and '(买一张（¥200）)' not in t, t
assert any('手上那张还没刮完' in x for x in t), t

# 没刮完的卡：退出重进还在，还能接着刮（存档里记着刮开了哪几格）
saved = g.store['game.txt']
opened = int(field(saved, 'lotto').split(',')[7])
assert 0 < opened < 64, field(saved, 'lotto')
g = start()                                            # 退出重进
assert g.store['game.txt'] == saved, (saved, g.store['game.txt'])
assert any('还剩 4 格没刮' in x for x in texts()), texts()
tap_label('彩票')
tap_label('接着刮')
t = texts()
assert any(x.startswith('已经刮开 2 / 6 格') for x in t), t
assert marks('<line>') >= 30, marks('<line>')           # 剩下四格还盖着
tap_label('剩下的全刮开')
no_err()
t = texts()
assert any(x.startswith('已经刮开 6 / 6 格') for x in t), t
tap_label('收下这笔钱')
t = texts()
assert any(x.startswith('六个格子：') for x in t), t
tap_label('知道了')
tap_label('关闭')

# 一回合三张：这一回合已经买了两张，再买一张就没了
tap_label('彩票')
assert any(x.startswith('本局 2 张') for x in texts()), texts()
tap_label('买一张（¥200）')
tap_label('剩下的全刮开')
tap_label('收下这笔钱')
no_err()
tap_label('知道了')
assert lotto_line('¥200 一张 · 六个格子 · 还剩 0 张'), texts()
assert any(x.startswith('本局 3 张') for x in texts()), texts()
assert '(买一张（¥200）)' in texts(), texts()          # 名额用完了，按钮是灰的
assert int(field(g.store['game.txt'], 'lotto').split(',')[0]) == 0
tap_label('关闭')
tap_label('下一回合')
if '知道了' in texts():
    tap_label('知道了')
tap_label('彩票')
assert lotto_line('¥200 一张 · 六个格子 · 还剩 3 张'), texts()
tap_label('关闭')
no_err()

# ---------------------------------------------------------------- 返回键：没有弹窗要交回系统
back = L.eval("function() fake_ms = fake_ms + 300; return tostring(on_input(ctx, {type='key', key='back'})) end")
assert back() == 'false', '没有弹窗时返回键必须交回系统，系统才会弹“离开应用”'
tap_label('行情')
assert back() == 'true', '有弹窗时返回键先关弹窗'
assert not any('最近的行情' in x for x in texts()), texts()

# ---------------------------------------------------------------- 最后一回合：按钮变“结束游戏”
save = g.store['game.txt']
g.store['game.txt'] = re.sub(r'^round=\d+$', 'round=60', save, flags=re.M)
g.store['game.txt'] = re.sub(r'^cash=\d+$', 'cash=20000', g.store['game.txt'], flags=re.M)
g.store['game.txt'] = re.sub(r'^owned=\d+$', 'owned=0', g.store['game.txt'], flags=re.M)
g = start()
t = texts()
assert '第 60 / 60 回合' in t and '结束游戏' in t and '下一回合' not in t, t
assert '最后一回合了' in ' '.join(t), t
tap_label('结束游戏')
t = texts()
assert '这是最后一回合了' in t, t                       # 没买房而钱够：先问一句
assert '先买房' in t and '直接结束' in t, t
assert any('够买城中村单间' in x for x in t), t
tap_label('先买房')
t = texts()
assert '城中村单间' in t and '买房' in ' '.join(t), t   # 直接跳到买房那一屏
tap_label('关闭')
tap_label('结束游戏')
tap_label('直接结束')
t = texts()
assert '六十回合结束' in t, t                           # 没买，最后还是能直接结束
assert field(g.store['game.txt'], 'over') == '1'
tap_label('新游戏')

# 已经买了房的，最后一回合不再多问
save = g.store['game.txt']
g.store['game.txt'] = re.sub(r'^round=\d+$', 'round=60', save, flags=re.M)
g.store['game.txt'] = re.sub(r'^cash=\d+$', 'cash=20000', g.store['game.txt'], flags=re.M)
g.store['game.txt'] = re.sub(r'^owned=\d+$', 'owned=1', g.store['game.txt'], flags=re.M)
g = start()
tap_label('结束游戏')
assert '六十回合结束' in texts(), texts()
tap_label('新游戏')

# 收摊时手上还捏着没刮完的卡：刮出来的那两格还是算数（六格全是 ¥20，只刮了两格）
save = g.store['game.txt']
g.store['game.txt'] = re.sub(r'^round=\d+$', 'round=60', save, flags=re.M)
g.store['game.txt'] = re.sub(r'^cash=\d+$', 'cash=20000', g.store['game.txt'], flags=re.M)
g.store['game.txt'] = re.sub(r'^owned=\d+$', 'owned=1', g.store['game.txt'], flags=re.M)
g.store['game.txt'] = re.sub(r'^lotto=.*$', 'lotto=3,0,1,200,0,222222,500,3', g.store['game.txt'], flags=re.M)
g = start()
assert any('还剩 4 格没刮' in x for x in texts()), texts()   # 卡和刮到哪儿都读回来了
tap_label('结束游戏')
t = texts()
assert '六十回合结束' in t, t
assert any('手上那张刮刮乐刮出 ¥' in x for x in t), t
assert cash() - 20000 in (40, 540), cash()              # 只算刮开的两格 ¥20×2（540 是顺带中了奖池）
tap_label('新游戏')

# ---------------------------------------------------------------- 打完 60 个回合
seen_rounds = []
seen_events = 0
for _ in range(200):
    t = texts()
    if '六十回合结束' in t:
        break
    tap_label('结束游戏') if '结束游戏' in t else tap_label('下一回合')
    t = texts()
    if '—— 特殊事件 ——' in t:                           # 出新闻的回合，事件要单独列出来
        seen_events += 1
    if '知道了' in t:
        tap_label('知道了')
    if '直接结束' in texts():                            # 最后一回合钱够买房时的询问
        tap_label('直接结束')
    no_err()
    seen_rounds.append(round_no())
    assert field(g.store['game.txt'], 'round') == str(seen_rounds[-1]), g.store['game.txt']
t = texts()
assert '六十回合结束' in t, t
assert any(x.startswith('净资产：') for x in t), t
assert any(x.startswith('房产：') for x in t), t
assert any(x.startswith('历史最好：') for x in t), t
assert max(seen_rounds) == 60, seen_rounds[-5:]
assert seen_events > 5, seen_events                     # 60 个回合里总该出过几条新闻
assert field(g.store['game.txt'], 'over') == '1'
tap_label('新游戏')
assert '第 1 / 60 回合' in texts(), texts()
no_err()
print('买房记：测试通过')
