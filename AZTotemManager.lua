-- TotemManager: live totem cards for Azeroth Survivors (runs inside the
-- WoW 1.12.1-style client, so this is a 1.12 / Lua 5.0 addon: table.getn,
-- math.mod, this/arg1 in scripts).
--
-- The game exposes the run through the AZS_* globals. Every 0.25 s the
-- driver below reads AZS_GetTotems() (key, spell, name, icon, count, cap,
-- duration, remaining) and renders one card per totem type:
--
--   totem name
--   totem icon
--   Total: standing count / cap, with a trend dot at the tail of the line
--   Next Death: seconds until the totem runs out
--   Duration: how long one totem lives once placed
--   DPS: live damage, difference-sampled from AZS_GetMeter(), abbreviated
--   Fill Status: a progress bar of the average count vs cap over one
--     totem lifetime; blue "Calculating" while history is short, then
--     red under 40 %, yellow under 70 %, green under 99 %, purple 99 %+
--   Verdict: "Upgrade Needed" / "Cap Reached" in a larger font
--
-- Anything the game puts in its totem list (such as Consecration) gets a
-- card of its own automatically.
--
-- Layout rules (learned the hard way, keep them):
--   - no text ever wraps: every line is its own font string, anchored at a
--     single point, and card width is reserved for the widest line plus
--     slack, so value changes can never outgrow the card
--   - texture geometry is applied by this engine when the anchor is set:
--     size things before anchoring them, or use a changing anchor pair
--     (the bar fill's right edge moves every tick, so its width is always
--     fresh)
--   - cards are sorted alphabetically by name (ties by key) so they never
--     swap places while the run goes
--   - hidden tooltips get parked on screen by the engine once populated,
--     so no automatic tooltip scanning: hovering a card opens the spell's
--     real tooltip instead (user-invoked, hides on leave)
--
-- Cards are sorted alphabetically by name (ties by key) so they never swap
-- places mid-run.
--
-- Settings: right-click a card or the frame, or /tm (reset, dump).

AZTotemManagerDB = AZTotemManagerDB or {}

local MAXHIST = 960
local DEFAULT_WINDOW = 60
local MIN_WINDOW = 15
local MAXWINDOW = 120
local SAMPLES_PER_SEC = 4
local SAMPLE_INTERVAL = 0.25

-- geometry constants (frame, card, bar, dot sizes in pixels)
local PAD = 10
local GAP = 8
local ROWGAP = 8
local CARD_PAD = 10
local SLACK = 18
local MIN_CARD = 150
local NAME_H = 14
local ICON_SIZE = 28
local STAT_H = 15
local LABEL_H = 14
local BAR_H = 11
local VERDICT_H = 18
local DOT_W = 5
local DOT_H = 5
local TITLE_H = 16
local HEADER_TOP = 6
local BOTTOM_PAD = 9
local COLS = 2

-- the saved settings and their fallbacks: the game replaces the global
-- with the saved version after loading, so reads always go through Opt()
local optDefaults = { verdict = 1, details = 1, trend = 1, autohide = 0, lock = 0, yellow = 70, icons = 1, dps = 1, card = 1 }

-- the saved variable made safe: the game can land a nil on the stored
-- global even after this file initialized it (the per-addon saved chunk
-- runs around addon load time), so every read re-seats the table first;
-- without this, one nil turn makes every DB() call "index a nil value"
local function DB()
  local d = AZTotemManagerDB
  if type(d) ~= "table" then
    d = {}
    AZTotemManagerDB = d
  end
  if type(d.opt) ~= "table" then d.opt = {} end
  if type(d.known) ~= "table" then d.known = {} end
  if type(d.hidden) ~= "table" then d.hidden = {} end
  if type(d.type) ~= "table" then d.type = {} end
  return d
end

-- one setting: saved value when set, else the default above (yellow's own
-- per-totem overrides live in DB().type[key], see the settings section)
local function Opt(k)
  local v = DB().opt[k]
  if v == nil then return optDefaults[k] end
  return v
end

-- per-totem overrides: DB().type[key] = { icon = 0/1, dps = 0/1 };
-- nil means "follow the global setting"
local function TypeOf(k)
  local t = DB().type[k]
  if type(t) ~= "table" then t = {} end
  return t
end

-- the effective switch for a per-totem toggle: the type's own override when
-- set (0 or 1), otherwise the global counterpart's value
local function SwitchOf(k, key, global)
  local own = TypeOf(k)[key]
  if own ~= nil then return own end
  return Opt(global)
end

-- one decimal for a number or "?" when it is not one
local function Num(x)
  if type(x) == "number" then return string.format("%.1f", x) end
  return "?"
end

-- a totem type's stable identifier: the game's key (never localized);
-- the fallback to its name only matters for odd entries
local function KeyOf(t)
  return tostring(t.key or t.name or "?")
end

local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local ICONS = {
  searing = "Interface\\Icons\\Spell_Fire_SearingTotem",
  magma = "Interface\\Icons\\Spell_Fire_MagmaTotem",
  nova = "Interface\\Icons\\Spell_Fire_FireNovaTotem",
  earthbind = "Interface\\Icons\\Spell_Nature_EarthBindTotem",
}
-- what to draw as the card's icon: the game reports one whenever it has it;
-- this only fills gaps, by key word, with the classic totem icons
local function IconOf(t, k)
  local ic = t.icon
  if type(ic) == "string" and ic ~= "" then return ic end
  local lk = string.lower(tostring(k))
  for pat, path in pairs(ICONS) do
    if string.find(lk, pat, 1, true) then return path end
  end
  return DEFAULT_ICON
end

-- the display frame: dark backdrop, draggable, its width and height are
-- recomputed from the cards on every draw tick
local f = CreateFrame("Frame", "TotemManagerFrame", UIParent)
f:SetWidth(260)
f:SetHeight(48)
f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -200)
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
f:SetBackdropColor(0, 0, 0, 0.6)

-- the stats' small font, with an availability probe: if the client ever
-- fails to render the small game font the lines fall back to the normal
-- one (0.130 regions are always named - unnamed regions are where the new
-- font pipeline loses the font - and the probes never kill the load)
local STAT_FONT = "GameFontNormalSmall"
do
  local probe = f:CreateFontString("AZTotemManagerStatFontProbe", "OVERLAY", "GameFontNormalSmall")
  local pw = nil
  pcall(function()
    probe:SetText("Duration: 88.8s")
    pw = probe:GetStringWidth()
  end)
  if type(pw) ~= "number" or pw < 20 then STAT_FONT = "GameFontNormal" end
  pcall(function() probe:SetText("") end)
end

-- the solid color texture for bars and dots, probed the same way:
-- a white base makes SetVertexColor colors come out bright and true,
-- the tinted tooltip background is the fallback
local TEX_SOLID = "Interface\\Tooltips\\UI-Tooltip-Background"
do
  local probe = f:CreateTexture("AZTotemManagerSolidProbe", "OVERLAY")
  pcall(function()
    probe:SetTexture("Interface\\Buttons\\WHITE8X8")
    local s = probe:GetTexture()
    if type(s) == "string" and string.find(string.lower(tostring(s)), "white8x8", 1, true) then
      TEX_SOLID = "Interface\\Buttons\\WHITE8X8"
    end
  end)
end

-- the header: a small label and the live total under it, both centered
-- over the cards by hand (manual centering, no width-bound strings)
local headLabel = f:CreateFontString("AZTotemManagerHeadLabel", "OVERLAY", STAT_FONT)
headLabel:SetTextColor(0.7, 0.7, 0.75)
headLabel:SetText("Total Totems")

local headValue = f:CreateFontString("AZTotemManagerHeadValue", "OVERLAY", "GameFontNormalLarge")
headValue:SetTextColor(1, 0.82, 0)
headValue:SetText("0")

-- forward declaration: the settings opener, assigned at the config section
local ToggleConfig

-- drag moves the frame (when not locked) and saves the position;
-- right click opens the settings
f:SetScript("OnDragStart", function()
  if Opt("lock") == 1 then return end
  this:StartMoving()
end)
f:SetScript("OnDragStop", function()
  this:StopMovingOrSizing()
  AZTotemManagerDB.left = this:GetLeft()
  AZTotemManagerDB.top = this:GetTop()
end)
f:SetScript("OnMouseUp", function()
  if arg1 == "RightButton" then ToggleConfig() end
end)

-- position reset: forget the saved spot and return to the default anchor
local function ResetPosition()
  AZTotemManagerDB.left = nil
  AZTotemManagerDB.top = nil
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -200)
end

------------------------------------------------------------
-- History: one sample per totem type, four times a second, held for
-- MAXHIST samples (240 s). The fill verdict and the trend dot read it.
------------------------------------------------------------
local hist = {}
local capOf = {}
local durOf = {}
local spellOf = {}
local lastRunT = nil

-- the averaging window in SECONDS: one totem lifetime, rounded up to the
-- next 5 s and clamped, from the last duration the game reported
local function WindowOf(k)
  local d = durOf[k]
  if type(d) ~= "number" or d <= 0 then return DEFAULT_WINDOW end
  local w = math.ceil(d / 5) * 5
  if w < MIN_WINDOW then w = MIN_WINDOW end
  if w > MAXWINDOW then w = MAXWINDOW end
  return w
end

-- one sample tick: remember each seen totem type (cap, duration, spell id,
-- display name for the settings list) and append one count sample per type,
-- 0 for the ones that dropped out of the list; history trims from the front
local function Sample(list)
  local present = {}
  if type(list) == "table" then
    for i = 1, table.getn(list) do
      local t = list[i]
      local k = KeyOf(t)
      present[k] = t
      capOf[k] = t.cap or capOf[k] or 0
      durOf[k] = t.duration or t.dur or durOf[k]
      spellOf[k] = t.spell or spellOf[k]
      DB().known[k] = tostring(t.name or k)
      if not hist[k] then hist[k] = {} end
    end
  end
  for k, cap in pairs(capOf) do
    local c = 0
    if present[k] then c = present[k].count or 0 end
    table.insert(hist[k], { c = c, cap = cap })
    while table.getn(hist[k]) > MAXHIST do table.remove(hist[k], 1) end
  end
end

-- Verdict(k) -> mode, fill
-- "calc" until history covers one full window (w * SAMPLES_PER_SEC
-- samples), then the rolling average of the standing count vs the cap over
-- that window: avg > 100 is clamped, 99+ counts as the cap.
-- Returns ("up", fill) for Upgrade Needed and ("cap", fill) for Cap Reached.
local function Verdict(k)
  local h = hist[k]
  local n = h and table.getn(h) or 0
  local w = WindowOf(k) * SAMPLES_PER_SEC
  if n < w then
    return "calc", 0
  end

  local sumFill = 0
  for i = n - w + 1, n do
    local s = h[i]
    if s.cap > 0 then sumFill = sumFill + s.c / s.cap end
  end
  local avg = math.floor(sumFill / w * 100 + 0.5)
  if avg > 100 then avg = 100 end
  if avg >= 99 then return "cap", avg end
  return "up", avg
end

-- Trend(k) -> "up", "down" or "dash"
-- compares the last 5 seconds (20 samples) against 10 to 15 seconds ago
-- (samples 40 to 60 back): climbing counts = wait before judging (up),
-- falling counts (down), steady or too little history (dash)
local function Trend(k)
  local h = hist[k]
  if not h then return "dash" end
  local n = table.getn(h)
  if n < 15 * SAMPLES_PER_SEC then return "dash" end
  local recent, earlier = 0, 0
  for i = n - 19, n do recent = recent + h[i].c end
  for i = n - 59, n - 40 do earlier = earlier + h[i].c end
  local d = (recent - earlier) / 20
  if d >= 1.5 then return "up" end
  if d <= -1.5 then return "down" end
  return "dash"
end

------------------------------------------------------------
-- Live DPS: AZS_GetMeter() reports damage per source, cumulative over the
-- run. Difference-sampling the cumulative number at the 0.25 s tick gives
-- the true instant dps; a short moving average keeps it smooth.
------------------------------------------------------------
local meterSt = {}

-- numbers abbreviated the way readers expect: 600, 1.5k, 10k, 100k, 1.5M
local function Abb(n)
  if type(n) ~= "number" then return "?" end
  if n < 0 then return "-" .. Abb(-n) end
  if n < 1000 then return tostring(math.floor(n + 0.5)) end
  local s
  n = n / 1000
  if n < 1000 then
    s = string.format("%.1fk", n)
  elseif n / 1000 < 1000 then
    s = string.format("%.1fM", n / 1000)
  else
    s = string.format("%.1fB", n / 1000 / 1000)
  end
  s = string.gsub(s, "%.0([kMB])$", "%1")
  return s
end

-- the smoothed live dps for a totem type, nil until there is data
local function DPSOf(k)
  local st = meterSt[k]
  if st and st.ema then return st.ema end
  return nil
end

-- one meter tick: match each known totem's damage line by name, difference
-- it against the previous tick, and fold the instant value into a short
-- exponential average; a shrinking cumulative (a new run) reseeds it
local function SampleMeter()
  if not AZS_GetMeter then return end
  local ok, lines = pcall(AZS_GetMeter)
  if not ok or type(lines) ~= "table" then return end
  local now = GetTime()

  local dmgBy = {}
  for i = 1, table.getn(lines) do
    local ln = lines[i]
    if type(ln) == "table" and ln.name then
      dmgBy[string.lower(tostring(ln.name))] = ln.dmg
    end
  end
  for k, nm in pairs(DB().known) do
    local dmg = dmgBy[string.lower(tostring(nm))]
    if type(dmg) == "number" then
      local st = meterSt[k]
      if not st then
        meterSt[k] = { prev = dmg, prevT = now, ema = nil }
      else
        local dt = now - st.prevT
        if dt > 0.001 then
          if dmg < st.prev then
            -- a meter reset (new run): reseed
            st.prev = dmg
            st.prevT = now
            st.ema = nil
          else
            local inst = (dmg - st.prev) / dt
            if st.ema == nil then
              st.ema = inst
            else
              st.ema = st.ema + (inst - st.ema) * 0.12
            end
            st.prev = dmg
            st.prevT = now
          end
        end
      end
    end
  end
end

------------------------------------------------------------
-- Spell tooltip, on hover: the game builds the spell tooltip's own
-- "Upgrades" and "Your bonuses" values natively and there is no addon API
-- for them, and populating a hidden tooltip gets parked on screen, so
-- nothing is read in the background. Hovering a card opens the spell's
-- real tooltip (the game's renderer takes the anchor), leaving closes it.
------------------------------------------------------------
local spellTip = nil

-- open the spell's tooltip beside a card: the totem reports its spell id,
-- which SetSpell accepts directly; never errors to the caller
local function OpenTip(k, ownerFrame)
  if spellOf[k] == nil then return end
  if not spellTip then
    local okCreate, frame = pcall(CreateFrame, "GameTooltip", "TWSpellTip", UIParent, "GameTooltipTemplate")
    if not okCreate then return end
    spellTip = frame
  end
  pcall(spellTip.SetOwner, spellTip, ownerFrame, "ANCHOR_RIGHT")
  pcall(spellTip.SetSpell, spellTip, spellOf[k], BOOKTYPE_SPELL)
  spellTip:Show()
end

-- close it and leave nothing behind (an emptied, hidden tooltip cannot be
-- re-parked into anything visible)
local function CloseTip()
  if spellTip then
    pcall(spellTip.ClearLines, spellTip)
    pcall(spellTip.Hide, spellTip)
  end
end

------------------------------------------------------------
-- Trend dot: a 5 px dot at the tail of the Total line, vertically centered
-- on the text like a dash. One dot per card, recolored per state: yellow
-- (steady / too little history) is the default; green = up, red = down.
------------------------------------------------------------
local DOT_WIDTHS = { 3, 5, 5, 5, 3 }
local DOT_XOFFS = { 1, 0, 0, 0, 1 }

-- the dot as 1 px scanlines (round at this size, no texture file needed),
-- one named texture per row
local function MakeDot(fr, base)
  local t = {}
  for j = 1, table.getn(DOT_WIDTHS) do
    t[j] = fr:CreateTexture(base .. "Dot" .. j, "OVERLAY")
    t[j]:SetTexture(TEX_SOLID)
    t[j]:SetVertexColor(1, 0.82, 0)
    t[j]:SetWidth(DOT_WIDTHS[j])
    t[j]:SetHeight(1)
    t[j]:Hide()
  end
  return t
end

-- recolor the whole dot
local function SetDotColor(dot, r, g, b)
  for j = 1, table.getn(dot) do dot[j]:SetVertexColor(r, g, b) end
end

-- place the dot at (ax, ay), scanline by scanline, centered per row
local function PlaceDot(fr, dot, ax, ay)
  for j = 1, table.getn(dot) do
    dot[j]:ClearAllPoints()
    dot[j]:SetPoint("TOPLEFT", fr, "TOPLEFT", ax + DOT_XOFFS[j], -(ay + j - 1))
    dot[j]:Show()
  end
end

------------------------------------------------------------
-- Cards: one card per totem type, built on demand and reused. Each card
-- carries its own strings, textures, state, and mouse handling.
------------------------------------------------------------
local cards = {}

-- card number i, created the first time it is asked for; 0.130 rule: every
-- region (frame, string, texture) gets a unique name, matching the corpus
local function GetCard(i)
  local c = cards[i]
  if c then return c end

  local base = "AZTotemManagerCard" .. i
  c = {}
  c.frame = CreateFrame("Frame", base, f)
  c.frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    tile = true, tileSize = 16,
  })
  c.frame:SetBackdropColor(0, 0, 0, 0.4)

  c.name = c.frame:CreateFontString(base .. "Name", "OVERLAY", "GameFontNormal")
  c.name:SetTextColor(1, 1, 1)

  c.icon = c.frame:CreateTexture(base .. "Icon", "ARTWORK")

  c.tot = c.frame:CreateFontString(base .. "Tot", "OVERLAY", STAT_FONT)
  c.tot:SetTextColor(0.92, 0.8, 0.45)

  c.left = c.frame:CreateFontString(base .. "Left", "OVERLAY", STAT_FONT)
  c.left:SetTextColor(0.75, 0.75, 0.8)

  c.dur = c.frame:CreateFontString(base .. "Dur", "OVERLAY", STAT_FONT)
  c.dur:SetTextColor(0.75, 0.75, 0.8)

  c.dps = c.frame:CreateFontString(base .. "Dps", "OVERLAY", STAT_FONT)
  c.dps:SetTextColor(0.75, 0.8, 0.9)

  c.fillLabel = c.frame:CreateFontString(base .. "FillLabel", "OVERLAY", STAT_FONT)
  c.fillLabel:SetTextColor(0.55, 0.55, 0.6)
  c.fillLabel:SetText("Fill Status")

  c.barbg = c.frame:CreateTexture(base .. "BarBg", "BORDER")
  c.barbg:SetTexture(TEX_SOLID)
  c.barbg:SetVertexColor(0.15, 0.15, 0.18)

  c.barfill = c.frame:CreateTexture(base .. "BarFill", "ARTWORK")
  c.barfill:SetTexture(TEX_SOLID)

  c.bartext = c.frame:CreateFontString(base .. "BarText", "OVERLAY", STAT_FONT)

  c.verdict = c.frame:CreateFontString(base .. "Verdict", "OVERLAY", "GameFontNormalLarge")

  c.dot = MakeDot(c.frame, base)

  -- card state: the verdict mode and fill percent cached from the measure
  -- pass, the trend dot state, and the measured Total line width for the
  -- dot's tail position
  c.mode = "calc"
  c.fillPct = 0
  c.tstate = "dash"
  c.totW = 0

  -- the card takes the mouse: hover opens the spell's own tooltip, drag
  -- moves the whole frame (lock respected), right click opens the settings
  c.frame:EnableMouse(true)
  c.frame:RegisterForDrag("LeftButton")
  c.frame:SetScript("OnDragStart", function()
    if Opt("lock") == 1 then return end
    f:StartMoving()
  end)
  c.frame:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    AZTotemManagerDB.left = f:GetLeft()
    AZTotemManagerDB.top = f:GetTop()
  end)
  c.frame:SetScript("OnMouseUp", function()
    if arg1 == "RightButton" then ToggleConfig() end
  end)
  c.frame:SetScript("OnEnter", function()
    if c.k then OpenTip(c.k, this) end
  end)
  c.frame:SetScript("OnLeave", function()
    CloseTip()
  end)

  cards[i] = c
  return c
end

-- MeasureCard = pass 1: set every shown line's text and measure it, so the
-- uniform card width is wide enough for the widest line (no wrapping ever);
-- also cache the card's state (mode / fill / dot state / totem line width)
local function MeasureCard(i, t, k)
  local c = GetCard(i)
  c.frame:Show()
  c.k = k

  local wtext, maxw = 0, 0

  c.name:SetText(tostring(t.name or t.key or "?"))
  wtext = c.name:GetStringWidth()
  if wtext > maxw then maxw = wtext end

  c.tot:SetText("Total: " .. (t.count or 0) .. "/" .. (t.cap or 0))
  c.tot:Show()
  wtext = c.tot:GetStringWidth()
  if wtext > maxw then maxw = wtext end
  c.totW = wtext

  -- the dot is always shown: yellow unless the trend option is on and the
  -- count is actually climbing (up) or dropping (down)
  local tstate = "dash"
  if Opt("trend") == 1 then tstate = Trend(k) end
  c.tstate = tstate
  if tstate == "up" then
    SetDotColor(c.dot, 0.25, 1, 0.25)
  elseif tstate == "down" then
    SetDotColor(c.dot, 1, 0.25, 0.25)
  else
    SetDotColor(c.dot, 1, 0.82, 0)
  end
  local tail = wtext + 5 + DOT_W
  if tail > maxw then maxw = tail end

  -- remaining time and duration, behind the details option
  if Opt("details") == 1 then
    c.left:SetText("Next Death: " .. Num(t.remaining) .. "s")
    c.dur:SetText("Duration: " .. Num(t.duration) .. "s")
    c.left:Show()
    c.dur:Show()
    wtext = c.left:GetStringWidth()
    if wtext > maxw then maxw = wtext end
    wtext = c.dur:GetStringWidth()
    if wtext > maxw then maxw = wtext end
  else
    c.left:Hide()
    c.dur:Hide()
  end

  -- live DPS only once the meter has data for this totem type
  local ddps = DPSOf(k)
  if ddps and SwitchOf(k, "dps", "dps") == 1 then
    c.dps:SetText("DPS: " .. Abb(ddps))
    c.dps:Show()
    wtext = c.dps:GetStringWidth()
    if wtext > maxw then maxw = wtext end
  else
    c.dps:Hide()
  end

  if Opt("verdict") == 1 then
    local mode, fill = Verdict(k)
    c.mode = mode
    c.fillPct = fill
    -- the bar's number: plain percentage once there is one
    if mode == "calc" then
      c.bartext:SetText("Calculating")
    else
      c.bartext:SetText(fill .. "%")
    end
    c.bartext:Show()
    wtext = c.bartext:GetStringWidth()
    if wtext > maxw then maxw = wtext end

    -- the big verdict under the bar: "..." while calculating
    if mode == "calc" then
      c.verdict:SetText("...")
    elseif mode == "cap" then
      c.verdict:SetText("Cap Reached")
    else
      c.verdict:SetText("Upgrade Needed")
    end
    c.verdict:Show()
    wtext = c.verdict:GetStringWidth()
    if wtext > maxw then maxw = wtext end
  else
    -- verdict option off: no fill status block at all
    c.fillLabel:Hide()
    c.barbg:Hide()
    c.barfill:Hide()
    c.bartext:Hide()
    c.verdict:Hide()
    c.mode = "calc"
    c.fillPct = 0
  end

  -- reserve the width: widest line + card padding + slack, at least MIN_CARD
  if maxw < 60 then maxw = 60 end
  local cardW = maxw + CARD_PAD * 2 + SLACK
  if cardW < MIN_CARD then cardW = MIN_CARD end
  c.needW = cardW
end

-- DrawCard = pass 2: position everything at the final (uniform) card width
-- and fill in the cached state.
local function DrawCard(i, t, k, wide)
  local c = GetCard(i)
  local fr = c.frame
  fr:Show()
  fr:SetWidth(wide)

  c.name:Show()
  c.name:SetPoint("TOP", fr, "TOP", 0, -4)
  local y = 4 + NAME_H + 2

  -- the icon: per-totem and global switches, both need to say show
  if SwitchOf(k, "icon", "icons") == 1 then
    pcall(c.icon.SetTexture, c.icon, IconOf(t, k))
    c.icon:Show()
    c.icon:SetWidth(ICON_SIZE)
    c.icon:SetHeight(ICON_SIZE)
    c.icon:SetPoint("TOP", fr, "TOP", 0, -y)
    y = y + ICON_SIZE + 5
  else
    c.icon:Hide()
  end

  c.tot:Show()
  c.tot:SetPoint("TOPLEFT", fr, "TOPLEFT", CARD_PAD, -y)
  PlaceDot(fr, c.dot, CARD_PAD + c.totW + 5, y + 4)
  y = y + STAT_H + 2

  if Opt("details") == 1 then
    c.left:Show()
    c.dur:Show()
    c.left:SetPoint("TOPLEFT", fr, "TOPLEFT", CARD_PAD, -y)
    y = y + STAT_H + 2
    c.dur:SetPoint("TOPLEFT", fr, "TOPLEFT", CARD_PAD, -y)
    y = y + STAT_H + 2
  end

  if c.dps:IsShown() then
    c.dps:SetPoint("TOPLEFT", fr, "TOPLEFT", CARD_PAD, -y)
    y = y + STAT_H + 2
  end

  if Opt("verdict") == 1 then
    c.fillLabel:Show()
    c.fillLabel:SetPoint("TOPLEFT", fr, "TOPLEFT", CARD_PAD, -y)
    y = y + LABEL_H + 1

    -- the bar: track and fill are sized by paired anchors with the right
    -- edge's offset changing every tick, so width and color can never go
    -- stale between them; both edges anchor to the card's TOPLEFT, which
    -- keeps the bar exactly BAR_H tall whatever the card's height is
    local barW = wide - CARD_PAD * 2
    local fillR, fillG, fillB = 0.25, 0.45, 1
    local fillW = barW
    if c.mode == "calc" then
      -- calculating: solid blue, completely filled, no percentage yet
      c.bartext:SetTextColor(1, 1, 1)
    else
      -- red under 40 %, yellow under 70 %, green under 99 %, purple 99 %+
      if c.fillPct < 40 then
        fillR, fillG, fillB = 1, 0.25, 0.25
      elseif c.fillPct < 70 then
        fillR, fillG, fillB = 1, 0.82, 0
      elseif c.fillPct < 99 then
        fillR, fillG, fillB = 0.25, 1, 0.25
      else
        fillR, fillG, fillB = 0.65, 0.35, 1
      end
      fillW = math.floor(barW * c.fillPct / 100 + 0.5)
      -- the percentage is white on every color
      c.bartext:SetTextColor(1, 1, 1)
    end
    c.barbg:ClearAllPoints()
    c.barbg:SetPoint("TOPLEFT", fr, "TOPLEFT", CARD_PAD, -y)
    c.barbg:SetPoint("BOTTOMRIGHT", fr, "TOPLEFT", CARD_PAD + barW, -(y + BAR_H))
    c.barbg:Show()
    c.barfill:SetVertexColor(fillR, fillG, fillB)
    c.barfill:ClearAllPoints()
    c.barfill:SetPoint("TOPLEFT", fr, "TOPLEFT", CARD_PAD, -y)
    c.barfill:SetPoint("BOTTOMRIGHT", fr, "TOPLEFT", CARD_PAD + fillW, -(y + BAR_H))
    c.barfill:Show()
    c.bartext:Show()
    c.bartext:SetPoint("TOP", fr, "TOP", 0, -(y + 1))
    y = y + BAR_H + 6

    -- the verdict's color follows the bar (purple for the cap)
    if c.mode == "calc" then
      c.verdict:SetTextColor(0.6, 0.6, 0.6)
    elseif c.mode == "cap" then
      c.verdict:SetTextColor(0.65, 0.35, 1)
    else
      if c.fillPct < 40 then
        c.verdict:SetTextColor(1, 0.25, 0.25)
      elseif c.fillPct < 70 then
        c.verdict:SetTextColor(1, 0.82, 0)
      else
        c.verdict:SetTextColor(0.25, 1, 0.25)
      end
    end
    c.verdict:SetPoint("TOPLEFT", fr, "TOPLEFT", CARD_PAD, -y)
    y = y + VERDICT_H + 2
  end

  -- the content cursor ends just past the last line: bottom padding to size
  local cardH = y - 2 + BOTTOM_PAD
  fr:SetHeight(cardH)
  c.contentH = cardH
end

------------------------------------------------------------
-- The driver: a separate frame owns OnUpdate, so the display frame can be
-- hidden by auto hide and still run.
--
-- Per tick (4 x a second):
--   1. a backwards run clock means a new run: reset all per-run state
--   2. when playing: sample totems + meter
--   3. collect the visible (not hidden in settings) totems, sort by name
--   4. empty: auto hide or draw the empty header
--   5. measured cards, one uniform width (side by side, COLS per row)
--   6. draw them at that width, center the header, place the cards in a
--      grid (a lone last card centered), size the frame to fit
------------------------------------------------------------
-- per tick the elapsed time must come from arg1 - which game 0.130 stopped
-- passing to OnUpdate (their own shipped addons carry "arg1 or 0") - so
-- without the argument the real frame gap is measured off GetTime()
local driver = CreateFrame("Frame", "TotemManagerDriver", UIParent)
local drawT, sampleT = 0, 0
local lastTick = nil

driver:SetScript("OnUpdate", function()
  local now = GetTime()
  local dt = 0
  if lastTick and now > lastTick and now - lastTick < 5 then
    dt = now - lastTick
  end
  lastTick = now
  drawT = drawT + (arg1 or dt)
  sampleT = sampleT + (arg1 or dt)
  if drawT < 0.25 then return end
  drawT = 0

  -- a new run: the run clock went backwards, reset everything per-run
  local r = AZS_RUN
  local playing = true
  if type(r) == "table" then
    if type(r.t) == "number" then
      if lastRunT and r.t < lastRunT - 1 then
        hist, capOf, durOf = {}, {}, {}
        spellOf = {}
        meterSt = {}
      end
      lastRunT = r.t
    end
    if r.ph ~= nil and r.ph ~= "playing" then playing = false end
  end

  local ok, list = false, nil
  if AZS_GetTotems then ok, list = pcall(AZS_GetTotems) end
  if not ok then list = nil end

  -- sample totem counts and meter damage at the same 0.25 s rhythm
  if sampleT >= SAMPLE_INTERVAL then
    sampleT = 0
    if playing then
      Sample(list)
      SampleMeter()
    end
  end

  -- collect the visible totems (the settings can hide types) and totals
  local vis = {}
  local total = 0
  local totalCap = 0
  if type(list) == "table" then
    for i = 1, table.getn(list) do
      local t = list[i]
      local k = KeyOf(t)
      -- the card renders unless this type's own Show switch turns it off
      if SwitchOf(k, "card", "card") == 1 then
        table.insert(vis, { t = t, k = k })
        total = total + (t.count or 0)
        totalCap = totalCap + (t.cap or 0)
      end
    end
  end

  -- stable order: alphabetical by name, ties by key, so the cards
  -- never swap places while the run goes
  table.sort(vis, function(a, b)
    local na = string.lower(tostring(a.t.name or a.k))
    local nb = string.lower(tostring(b.t.name or b.k))
    if na == nb then return tostring(a.k) < tostring(b.k) end
    return na < nb
  end)

  local n = table.getn(vis)
  if n == 0 then
    -- nothing standing: hide the cards, auto hide the frame, or draw the
    -- empty header ("Total Totems / 0") centered
    for i = 1, table.getn(cards) do cards[i].frame:Hide() end
    if Opt("autohide") == 1 then
      f:Hide()
      return
    end
    f:Show()
    headLabel:SetText("Total Totems")
    headValue:SetText("0")
    local tw = headValue:GetStringWidth() + PAD * 2
    if tw < MIN_CARD then tw = MIN_CARD end
    f:SetWidth(tw)
    f:SetHeight(HEADER_TOP + LABEL_H + TITLE_H + 2 + 10)
    local lw = headLabel:GetStringWidth()
    local vw = headValue:GetStringWidth()
    headLabel:ClearAllPoints()
    headLabel:SetPoint("TOPLEFT", f, "TOPLEFT", math.floor((tw - lw) / 2), -HEADER_TOP)
    headValue:ClearAllPoints()
    headValue:SetPoint("TOPLEFT", f, "TOPLEFT", math.floor((tw - vw) / 2), -(HEADER_TOP + LABEL_H + 2))
    return
  end

  f:Show()

  -- pass 1: measure every card
  for i = 1, n do
    MeasureCard(i, vis[i].t, vis[i].k)
  end

  -- one uniform card width: the widest card's need, so the grid looks tidy
  local uniform = 0
  for i = 1, n do
    if cards[i].needW > uniform then uniform = cards[i].needW end
  end
  local cardH = {}
  -- pass 2: draw at the final width
  for i = 1, n do
    DrawCard(i, vis[i].t, vis[i].k, uniform)
    cardH[i] = cards[i].contentH
  end

  -- the header: "Total Totems" and the live total over the sum of caps
  headLabel:SetText("Total Totems")
  if totalCap > 0 then
    headValue:SetText(total .. "/" .. totalCap)
  else
    -- no caps known: total alone
    headValue:SetText(tostring(total))
  end

  -- frame width: two cards side by side (COLS) or one, at least as wide as
  -- the header needs
  local cols = (n > 1) and COLS or 1
  local frameW = PAD * 2
  if cols == 2 then
    frameW = frameW + uniform * 2 + GAP
  else
    frameW = frameW + uniform
  end
  local headW = headLabel:GetStringWidth()
  local headVW = headValue:GetStringWidth()
  if frameW < headW + PAD * 2 then frameW = headW + PAD * 2 end
  if frameW < headVW + PAD * 2 then frameW = headVW + PAD * 2 end
  headLabel:ClearAllPoints()
  headLabel:SetPoint("TOPLEFT", f, "TOPLEFT", math.floor((frameW - headW) / 2), -HEADER_TOP)
  headValue:ClearAllPoints()
  headValue:SetPoint("TOPLEFT", f, "TOPLEFT", math.floor((frameW - headVW) / 2), -(HEADER_TOP + LABEL_H + 2))

  -- the grid: cards in COLS columns, rows sized to the tallest card, a lone
  -- last card centered
  local rows = math.ceil(n / cols)
  local y = HEADER_TOP + LABEL_H + 2 + TITLE_H + 4
  for rr = 0, rows - 1 do
    local rowMax = 0
    for j = 0, cols - 1 do
      local idx = rr * cols + j + 1
      if idx <= n and cardH[idx] > rowMax then rowMax = cardH[idx] end
    end
    for j = 0, cols - 1 do
      local idx = rr * cols + j + 1
      if idx <= n then
        local xoff = PAD + j * (uniform + GAP)
        if cols == 2 and idx == n and math.mod(n, 2) == 1 then
          xoff = PAD + math.floor((frameW - PAD * 2 - uniform) / 2)
        end
        local c = cards[idx]
        c.frame:ClearAllPoints()
        c.frame:SetPoint("TOPLEFT", f, "TOPLEFT", xoff, -y)
      end
    end
    y = y + rowMax + ROWGAP
  end

  -- cards beyond the current totem count go dark
  for i = n + 1, table.getn(cards) do cards[i].frame:Hide() end
  f:SetWidth(frameW)
  f:SetHeight(y - ROWGAP + 10)
end)

------------------------------------------------------------
-- Settings window: a dialog with the totem types ever seen (checkbox per
-- type, sorted by name), the display options, the yellow threshold, and
-- reset buttons. ESC closes it (it is in UISpecialFrames).
------------------------------------------------------------
local cfg = CreateFrame("Frame", "TotemManagerConfig", UIParent)
cfg:SetWidth(440)
cfg:SetHeight(668)
cfg:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
cfg:SetFrameStrata("DIALOG")
cfg:SetBackdrop({
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
cfg:EnableMouse(true)
cfg:SetMovable(true)
cfg:RegisterForDrag("LeftButton")
cfg:SetScript("OnDragStart", function() this:StartMoving() end)
cfg:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
cfg:Hide()
tinsert(UISpecialFrames, "TotemManagerConfig")

-- the window's title and close button
local title = cfg:CreateFontString("AZTotemManagerCfgTitle", "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", cfg, "TOP", 0, -18)
title:SetText("TotemManager - settings")

local closeBtn = CreateFrame("Button", "AZTotemManagerCfgClose", cfg, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", cfg, "TOPRIGHT", -5, -5)

-- a check button with its label to the right, placed inside the dialog;
-- the label region is named off the button's name
local function MakeCheck(name, x, y, label)
  local cb = CreateFrame("CheckButton", name, cfg)
  cb:SetWidth(26)
  cb:SetHeight(26)
  cb:SetPoint("TOPLEFT", cfg, "TOPLEFT", x, y)
  cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
  cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
  cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
  cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
  cb:SetDisabledCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check-Disabled")
  local l = cfg:CreateFontString(name .. "CfgLabel", "OVERLAY", "GameFontHighlight")
  l:SetPoint("LEFT", cb, "RIGHT", 6, 0)
  l:SetText(label)
  cb.label = l
  return cb
end

-- boolean helper for the 1/nil toggles
local function SetChecked(cb, on)
  if on then cb:SetChecked(1) else cb:SetChecked(nil) end
end

-- small section header (normal gold, the same font the row labels use)
local function MakeSec(name, y, text)
  local s = cfg:CreateFontString(name, "OVERLAY", "GameFontNormal")
  s:SetPoint("TOPLEFT", cfg, "TOPLEFT", 24, y)
  s:SetText(text)
  return s
end

-- section: the global defaults, applied to every card
local sec1 = MakeSec("AZTotemManagerCfgSec1", -40, "Every card (global defaults)")

local optChecks = {}
local function MakeOpt(key, y, label)
  local cb = MakeCheck("TotemManagerOpt" .. key, 24, y, label)
  cb:SetScript("OnClick", function()
    if this:GetChecked() then DB().opt[key] = 1 else DB().opt[key] = 0 end
  end)
  optChecks[key] = cb
end
MakeOpt("verdict", -64, "Show the verdict (are more upgrades still needed?)")
MakeOpt("details", -88, "Show remaining time and duration")
MakeOpt("trend", -112, "Show green and red dots when counts rise or fall")
MakeOpt("icons", -136, "Show the totem icons")
MakeOpt("dps", -160, "Show the DPS lines")
MakeOpt("autohide", -184, "Hide the frame when there are no totems")
MakeOpt("lock", -208, "Lock the position (no more dragging)")

-- the yellow threshold: where the fill bar stops being red
local yLabel = cfg:CreateFontString("AZTotemManagerCfgYLabel", "OVERLAY", "GameFontHighlight")
yLabel:SetPoint("TOPLEFT", cfg, "TOPLEFT", 28, -246)
yLabel:SetText("Yellow starts at")

local yBox = CreateFrame("EditBox", "TotemManagerYellowBox", cfg)
yBox:SetWidth(50)
yBox:SetHeight(22)
yBox:SetPoint("TOPLEFT", cfg, "TOPLEFT", 170, -242)
yBox:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
yBox:SetBackdropColor(0, 0, 0, 0.8)
-- ChatFontNormal is gone in game 0.130: the edit box uses a named object,
-- string form (the corpus style)
yBox:SetFontObject("GameFontNormal")
yBox:SetTextInsets(6, 6, 0, 0)
yBox:SetJustifyH("CENTER")
yBox:SetAutoFocus(false)
yBox:SetMaxLetters(3)

local yUnit = cfg:CreateFontString("AZTotemManagerCfgYUnit", "OVERLAY", "GameFontHighlight")
yUnit:SetPoint("LEFT", yBox, "RIGHT", 8, 0)
yUnit:SetText("% average fill")

-- apply the typed threshold: clamped to 1..99, Enter applies, Esc restores
local function CommitYellow()
  local n = tonumber(yBox:GetText())
  if n == nil then
    yBox:SetText(tostring(Opt("yellow")))
    return
  end
  n = math.floor(n)
  if n < 1 then n = 1 end
  if n > 99 then n = 99 end
  DB().opt.yellow = n
  yBox:SetText(tostring(n))
end
yBox:SetScript("OnEnterPressed", function() CommitYellow() this:ClearFocus() end)
yBox:SetScript("OnEscapePressed", function() this:SetText(tostring(Opt("yellow"))) this:ClearFocus() end)
yBox:SetScript("OnEditFocusLost", function() CommitYellow() end)

local hint = cfg:CreateFontString("AZTotemManagerCfgHint", "OVERLAY", "GameFontHighlight")
hint:SetPoint("TOPLEFT", cfg, "TOPLEFT", 28, -278)
hint:SetWidth(400)
hint:SetJustifyH("LEFT")
hint:SetJustifyV("TOP")
hint:SetText("Red = 100% (cap reached, no point taking more). Yellow = between this threshold and 99%. Green = below: there is still room. Press Enter to apply.")

-- section: the per-totem overrides, one row per known totem type:
-- Show (does the card render at all) / Icon / DPS; an untouched switch
-- follows the global default, a toggled one overrides it
local sec2 = MakeSec("AZTotemManagerCfgSec2", -334, "Per totem (overrides)")

local COL_CAPS = { { key = "card", global = "card", x = 244, cap = "Show" }, { key = "icon", global = "icons", x = 316, cap = "Icon" }, { key = "dps", global = "dps", x = 388, cap = "DPS" } }
for i, cc in ipairs(COL_CAPS) do
  local h = cfg:CreateFontString("AZTotemManagerCfgColHead" .. i, "OVERLAY", STAT_FONT)
  h:SetPoint("TOPLEFT", cfg, "TOPLEFT", cc.x, -360)
  h:SetText(cc.cap)
end

local typeRows = {}
for i = 1, 8 do
  local y = -386 - (i - 1) * 28
  local nm = cfg:CreateFontString("AZTotemManagerCfgType" .. i .. "Name", "OVERLAY", "GameFontHighlight")
  nm:SetPoint("TOPLEFT", cfg, "TOPLEFT", 28, y)
  nm:SetWidth(200)
  nm:SetText("")
  local row = { label = nm, checks = {} }
  for _, cc in ipairs(COL_CAPS) do
    local cb = MakeCheck("TotemManagerTypeCheck" .. i .. cc.key, cc.x, y, "")
    cb.key = cc.key
    cb:SetScript("OnClick", function()
      if row.key then
        local t = DB().type[row.key]
        if type(t) ~= "table" then t = {}; DB().type[row.key] = t end
        if this:GetChecked() then t[cc.key] = 1 else t[cc.key] = 0 end
      end
    end)
    row.checks[cc.key] = cb
  end
  typeRows[i] = row
end
-- nothing seen yet: the line under the per-totem header
local emptyText = cfg:CreateFontString("AZTotemManagerCfgEmpty", "OVERLAY", "GameFontHighlight")
emptyText:SetPoint("TOPLEFT", cfg, "TOPLEFT", 28, -384)
emptyText:SetWidth(400)
emptyText:SetJustifyH("LEFT")
emptyText:SetText("None for now: start a game and place a totem, and it will appear here.")

-- refill every control from the saved state: on show and once at load
-- (the engine's script-event delivery is not something to bet the layout on)
local function Refresh()
  local keys = {}
  for k, nm in pairs(DB().known) do table.insert(keys, k) end
  table.sort(keys, function(a, b) return tostring(DB().known[a]) < tostring(DB().known[b]) end)

  if table.getn(keys) == 0 then emptyText:Show() else emptyText:Hide() end

  -- the globals
  for key, cb in pairs(optChecks) do
    SetChecked(cb, Opt(key) == 1)
  end
  yBox:SetText(tostring(Opt("yellow")))

  -- the per-totem rows: up to 8 types; the Show switch's untouched state
  -- means shown (there is no global card toggle; hiding is per type)
  for i = 1, 8 do
    local row = typeRows[i]
    local k = keys[i]
    if k then
      row.key = k
      row.label:SetText(tostring(DB().known[k]))
      row.label:Show()
      for _, cc in ipairs(COL_CAPS) do
        local key = cc.key
        local cb = row.checks[key]
        -- the same effective switch the card render reads: own override
        -- when set, otherwise the column's global default
        SetChecked(cb, SwitchOf(k, key, cc.global) == 1)
        cb:Show()
      end
    else
      row.key = nil
      row.label:SetText("")
      row.label:Hide()
      for _, key in ipairs({ "card", "icon", "dps" }) do row.checks[key]:Hide() end
    end
  end
end

-- a plain dialog button
local function NewButton(name, width, label, onclick)
  local b = CreateFrame("Button", name, cfg, "UIPanelButtonTemplate")
  b:SetWidth(width)
  b:SetHeight(24)
  b:SetText(label)
  b:SetScript("OnClick", onclick)
  return b
end

-- reset to defaults: clear the options and the per-totem overrides; the
-- seen-type list stays
local defBtn = NewButton("TotemManagerDefaultsBtn", 170, "Reset to defaults", function()
  DB().opt = {}
  DB().type = {}
  Refresh()
end)
defBtn:SetPoint("BOTTOM", cfg, "BOTTOM", -95, 22)

-- reset the frame's position to its original anchor
local posBtn = NewButton("TotemManagerPosBtn", 170, "Reset position", function()
  ResetPosition()
end)
posBtn:SetPoint("BOTTOM", cfg, "BOTTOM", 95, 22)

cfg:SetScript("OnShow", function() Refresh() end)

-- also refresh once at load: the values must be right the first time the
-- window opens even if the engine's script events get lost
Refresh()

-- the forward-declared settings opener
ToggleConfig = function()
  if cfg:IsVisible() then cfg:Hide() else cfg:Show() end
end

------------------------------------------------------------
-- Commands: reset and the diagnostic dump; anything else opens settings.
------------------------------------------------------------
-- Commands: reset and the diagnostic dump; anything else opens settings.
SLASH_TOTEMMANAGER1 = "/tm"
SLASH_TOTEMMANAGER2 = "/totemmanager"
SlashCmdList["TOTEMMANAGER"] = function(msg)
  msg = string.lower(msg or "")
  if msg == "reset" then
    ResetPosition()
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100TotemManager|r: position reset to origin")
  elseif msg == "dump" then
    -- diagnostics: the live report also goes to a saved variable, so it
    -- lands in benilla-config/saved/AZTotemManager.lua when the addon saves
    -- (logout/exit), ready to copy and paste
    local probeList = {
      "AZS_GetTotems", "AZS_GetTotemCount", "AZS_GetMeter", "AZS_GetHealing",
      "AZS_GetBossMeter", "AZS_GetRunTime", "AZS_GetPhase", "AZS_GetRunLength",
      "AZS_GetRunSummary", "AZS_GetBosses", "AZS_GetGuardians", "AZS_GetDebuffs",
      "AZS_GetSummons", "AZS_GetSummonGroups", "AZS_GetSummonCount", "AZS_GetTimers",
      "AZS_GetUpcomingBosses", "AZS_GetLairs", "AZS_GetFlaggedLair", "AZS_GetRevive",
      "AZS_GetStoredLevels", "AZS_OpenStoredLevels", "AZS_IsStoringLevels",
      "AZS_SetStoringLevels", "AZS_SetHudShown", "AZS_IsHudShown", "AZS_UnitKind",
      "AZS_RegisterBannerHandler", "AZS_UnregisterBannerHandler",
      "AZS_TOTEMS", "AZS_RUN", "AZS_METER", "AZS_ZONE", "AZS_SPELLS",
      "AZS_BUFFS", "AZS_PETS", "AZS_SCHEDULE", "AZS_TIMERS",
    }
    local checked = 0
    local present = 0
    local report = "-- TotemManager dump (game " .. (GetBuildInfo and select(4, GetBuildInfo()) or "?") .. ")\n"
    for i = 1, table.getn(probeList) do
      local nm = probeList[i]
      checked = checked + 1
      local v = nil
      local chunk = loadstring("return " .. nm)
      if chunk then
        local ok, r = pcall(chunk)
        if ok then v = r end
      end
      local shape = type(v)
      if shape == "table" then
        shape = shape .. " (n=" .. table.getn(v) .. ")"
      end
      if shape ~= "nil" then
        present = present + 1
        DEFAULT_CHAT_FRAME:AddMessage(nm .. " : " .. shape)
        report = report .. nm .. " : " .. shape .. "\n"
      else
        DEFAULT_CHAT_FRAME:AddMessage(nm .. " : MISSING")
        report = report .. nm .. " : MISSING\n"
      end
    end

    -- live snapshot: phase, clock, and the totem list's own contents
    local phase = AZS_GetPhase and AZS_GetPhase() or "no-phase-function"
    local rt = AZS_GetRunTime and AZS_GetRunTime() or "nil"
    report = report .. "phase : " .. tostring(phase) .. "\n"
    report = report .. "run time : " .. tostring(rt) .. "\n"
    local raw = nil
    do
      local c2 = loadstring("return AZS_GetTotems()")
      if c2 then
        local ok, r = pcall(c2)
        if ok then raw = r end
      end
    end
    if type(raw) == "table" then
      report = report .. "AZS_GetTotems() : table (n=" .. table.getn(raw) .. ")\n"
      for i = 1, table.getn(raw) do
        local t = raw[i]
        report = report .. "  totem: key=" .. tostring(t.key) .. " name=" .. tostring(t.name)
          .. " icon=" .. tostring(t.icon) .. " count=" .. tostring(t.count)
          .. " cap=" .. tostring(t.cap) .. " dur=" .. tostring(t.duration or t.dur)
          .. " remaining=" .. tostring(t.remaining) .. " spell=" .. tostring(t.spell) .. "\n"
      end
    else
      report = report .. "AZS_GetTotems() : " .. type(raw) .. " (no totem list!)\n"
    end

    -- the meter's source names, so the DPS matching is checkable too
    do
      local ok, mlines, mtotal, mdps = false, nil, nil, nil
      if AZS_GetMeter then ok, mlines, mtotal, mdps = pcall(AZS_GetMeter) end
      if ok and type(mlines) == "table" then
        report = report .. "AZS_GetMeter() : table (n=" .. table.getn(mlines) .. ", total " .. tostring(mtotal) .. ", dps " .. tostring(mdps) .. ")\n"
        for i = 1, table.getn(mlines) do
          local ln = mlines[i]
          report = report .. "  meter: name=" .. tostring(ln.name) .. " dmg=" .. tostring(ln.dmg) .. " dps=" .. tostring(ln.dps) .. "\n"
        end
      else
        report = report .. "AZS_GetMeter() : MISSING or errored\n"
      end
    end

    -- the saved copy (lands in saved/AZTotemManager.lua when the addon saves)
    DB().dumpText = report
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100TotemManager|r: AZS probe - " .. present .. "/" .. checked
      .. " present; full report saved (exit the game, then open benilla-config/saved/AZTotemManager.lua)")
  else
    ToggleConfig()
  end
end

-- restore the saved position once the saved variables are loaded
driver:RegisterEvent("VARIABLES_LOADED")
driver:SetScript("OnEvent", function()
  if AZTotemManagerDB.left and AZTotemManagerDB.top then
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", AZTotemManagerDB.left, AZTotemManagerDB.top)
  end
end)