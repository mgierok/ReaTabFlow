-- @description ReaTabFlow - Guitar tablature on MIDI tracks
-- @version 1.1
-- @about Display tablature in the arrange view for tracks selected when the action starts.
local r = reaper
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local tuning = {64, 59, 55, 50, 45, 40} -- high E to low E, sounding MIDI pitches
local lastFret = 24

-- For each occupied-string mask, retain the cheapest fingering of this chord.
-- Skipping a note costs more than any six playable fingerings combined.
local function assignChord(notes, first, last, busy, position)
  local onset = notes[first].start
  local states = {[0] = {cost = 0}}
  for index = first, last do
    local note, nextStates = notes[index], {}
    for mask, state in pairs(states) do
      if not nextStates[mask] or state.cost + 1000 < nextStates[mask].cost then
        nextStates[mask] = {cost = state.cost + 1000, parent = state}
      end
      for row, openPitch in ipairs(tuning) do
        local bit = 2 ^ (row - 1)
        local fret = note.pitch - openPitch
        if fret >= 0 and fret <= lastFret and (busy[row] or -math.huge) <= onset
            and floor(mask / bit) % 2 == 0 then
          local travel = fret == 0 and 0 or math.abs(fret - position)
          local cost = state.cost + fret + 2 * travel
          local target = mask + bit
          if not nextStates[target] or cost < nextStates[target].cost then
            nextStates[target] = {cost = cost, parent = state, note = note, row = row, fret = fret}
          end
        end
      end
    end
    states = nextStates
  end
  local best
  for mask = 0, 63 do
    local state = states[mask]
    if state and (not best or state.cost < best.cost) then best = state end
  end
  local chord = {start = onset, missed = 0}
  local total, count = 0, 0
  while best.parent do
    if best.row then
      chord[best.row] = best.fret
      busy[best.row] = best.note.stop
      if best.fret > 0 then total, count = total + best.fret, count + 1 end
    else
      chord.missed = chord.missed + 1
    end
    best = best.parent
  end
  return chord, count > 0 and total / count or position
end

-- konst_Import MusicXML writes the tuning low to high. Its guitar channel
-- (zero-based) is 6 - string number; bass uses one channel lower.
local function importedChord(notes, first, last, strings, topChannel)
  local chord = {start = notes[first].start, missed = 0}
  for i = first, last do
    local note = notes[i]
    local row = topChannel - note.channel + 1
    local openPitch = strings[#strings - row + 1]
    if openPitch and note.pitch >= openPitch and chord[row] == nil then
      chord[row] = note.pitch - openPitch
    else
      chord.missed = chord.missed + 1
    end
  end
  return chord
end

local function parseStrings(state)
  local list = state:match("strings%s*=%s*{([^}]*)}")
  if not list then return end
  local strings = {}
  for field in (list .. ","):gmatch("([^,]*),") do
    local pitch = tonumber(field:match("^%s*(%d+)%s*$"))
    if not pitch or pitch > 127 then return end
    strings[#strings + 1] = pitch
  end
  -- The importer also stores a nine-lane percussion map under this key.
  if #strings >= 1 and #strings <= 6 then return strings end
end

local function importSettings(take)
  local _, ppq = r.GetSetMediaItemTakeInfo_String(take, "P_EXT:XMLREMAP_PPQ", "", false)
  if not tonumber(ppq) then return "", 5 end
  local track = r.GetMediaItemTake_Track(take)
  local _, state = r.GetSetMediaTrackInfo_String(track, "P_EXT:XR_ReaTabHero", "", false)
  local _, trackName = r.GetTrackName(track)
  local bass = r.GetTakeName(take):lower():find("bass", 1, true) or trackName:lower():find("bass", 1, true)
  return state, bass and 4 or 5
end

local function readChords(take, transpose, strings, topChannel)
  local _, count = r.MIDI_CountEvts(take)
  local notes = {}
  for i = 0, count - 1 do
    local ok, _, muted, start, stop, channel, pitch = r.MIDI_GetNote(take, i)
    if ok and not muted then
      notes[#notes + 1] = {start = start, stop = stop, pitch = pitch + transpose, channel = channel, index = i}
    end
  end
  table.sort(notes, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    if a.pitch ~= b.pitch then return a.pitch < b.pitch end
    return a.index < b.index
  end)
  local chords, busy, position, first = {}, {}, 1, 1
  while first <= #notes do
    local last = first
    while last < #notes and notes[last + 1].start == notes[first].start do last = last + 1 end
    if strings then
      chords[#chords + 1] = importedChord(notes, first, last, strings, topChannel)
    else
      chords[#chords + 1], position = assignChord(notes, first, last, busy, position)
    end
    first = last + 1
  end
  return chords
end

-- The final packed event is REAPER's source end, including trailing silence.
local function sourceTicks(take)
  if r.BR_GetMidiSourceLenPPQ then return r.BR_GetMidiSourceLenPPQ(take) end
  local ok, stream = r.MIDI_GetAllEvts(take, "")
  local tick, offset = 0, 1
  while ok and offset <= #stream do
    local delta, length, payload = string.unpack("i4xI4", stream, offset)
    tick, offset = tick + delta, payload + length
  end
  return tick
end

local function lowerBound(chords, tick)
  local lo, hi = 1, #chords + 1
  while lo < hi do
    local mid = floor((lo + hi) / 2)
    if chords[mid].start < tick then lo = mid + 1 else hi = mid end
  end
  return lo
end

local function visibleChords(model, take, fromTime, toTime, looped, zoom, draw)
  if #model.chords == 0 then return end
  local left = r.MIDI_GetPPQPosFromProjTime(take, fromTime)
  local right = r.MIDI_GetPPQPosFromProjTime(take, toTime)
  local period = looped and model.period or 0
  local cycle = period > 0 and floor(left / period) or 0
  local final = period > 0 and floor(right / period) or 0
  while cycle <= final do
    local shift = cycle * period
    local i = lowerBound(model.chords, left - shift - 1e-7)
    while i <= #model.chords do
      local chord = model.chords[i]
      local tick = shift + chord.start
      if tick >= right - 1e-7 or (period > 0 and chord.start >= period) then break end
      draw(chord, r.MIDI_GetProjTimeFromPPQPos(take, tick))
      i = i + 1
    end
    if cycle == final then break end
    -- When many whole repetitions occupy one pixel, sample one per pixel.
    local time = r.MIDI_GetProjTimeFromPPQPos(take, shift)
    cycle = max(cycle + 1, floor(r.MIDI_GetPPQPosFromProjTime(take, time + 1 / zoom) / period))
  end
end

if not r.APIExists("JS_Composite") then
  r.MB("Install js_ReaScriptAPI through ReaPack, then restart REAPER.", "ReaTabFlow", 0)
  return
end
local project = r.EnumProjects(-1, "")
local tracks = {}
for i = 0, r.CountSelectedTracks(project) - 1 do
  tracks[#tracks + 1] = r.GetSelectedTrack(project, i)
end
if #tracks == 0 then
  r.MB("Select a guitar track in the track control panel and run ReaTabFlow again.", "ReaTabFlow", 0)
  return
end
local arrange = r.JS_Window_FindChildByID(r.GetMainHwnd(), 1000)
if not arrange then r.MB("Could not find the arrange view.", "ReaTabFlow", 0) return end

local overlays, fonts = {}, {}
local function release(overlay)
  if overlay.front then
    r.JS_Composite_Unlink(arrange, overlay.front, true)
    r.JS_LICE_DestroyBitmap(overlay.front)
  end
  if overlay.base then r.JS_LICE_DestroyBitmap(overlay.base) end
end
r.atexit(function()
  for _, overlay in pairs(overlays) do release(overlay) end
  for _, font in pairs(fonts) do
    r.JS_LICE_DestroyFont(font.lice)
    r.JS_GDI_DeleteObject(font.gdi)
  end
  r.UpdateArrange()
end)
r.set_action_options(5) -- display toggle state, stop on second invocation

local function getFont(size)
  if not fonts[size] then
    local gdi = assert(r.JS_GDI_CreateFont(size, 700, 0, false, false, false, "Arial"))
    local lice = assert(r.JS_LICE_CreateFont())
    r.JS_LICE_SetFontFromGDI(lice, gdi, "")
    fonts[size] = {gdi = gdi, lice = lice}
  end
  return fonts[size].lice
end

local function rect(bitmap, x, y, w, h, color)
  r.JS_LICE_FillRect(bitmap, x, y, w, h, color, 1, "COPY")
end

local function drawStaff(o, take, view, top, height, start, stop, looped, selected)
  local bitmap, w, h = o.base, o.w, o.h
  local bg = selected and 0xff253947 or 0xff202a31
  r.JS_LICE_Clear(bitmap, bg)
  local rows = o.model.rows
  if height < rows * 6 + 10 then
    local hint = "TAB  ·  Increase track height"
    local font = getFont(11)
    r.JS_LICE_SetFontColor(font, 0xfff6f5eb)
    r.JS_LICE_DrawText(bitmap, font, hint, #hint, 3, max(0, floor((h - 12) / 2)), w, h)
    r.JS_LICE_Blit(o.front, 0, 0, bitmap, 0, 0, w, h, 1, "COPY")
    return
  end
  local step = min(24, (height - 9) / rows)
  local size = max(7, min(19, floor(step)))
  local font = getFont(size)
  local firstY = top - o.y + floor((height - (rows - 1) * step) / 2)
  local function xAt(t) return floor((t - view.start) * view.zoom + 0.5) - o.x end
  local from, to = max(start, view.start), min(stop, view.stop)

  local _, measure = r.TimeMap2_timeToBeats(project, from)
  while true do
    local barTime = r.TimeMap2_beatsToTime(project, 0, measure)
    if barTime >= to then break end
    local x = xAt(barTime)
    if x >= 0 then rect(bitmap, x, 0, 1, h, 0xff546875) end
    local _, nextMeasure = r.TimeMap2_timeToBeats(project, barTime + 8 / view.zoom)
    measure = max(measure + 1, nextMeasure)
  end
  for row = 1, rows do
    rect(bitmap, 0, floor(firstY + (row - 1) * step), w, 1, 0xff778993)
  end
  local lastEnd = {}
  r.JS_LICE_SetFontColor(font, 0xfff6f5eb)
  visibleChords(o.model, take, from, to, looped, view.zoom, function(chord, time)
    local x = max(0, xAt(time))
    for row = 1, rows do
      local fret = chord[row]
      if fret and x >= (lastEnd[row] or 0) then
        local label = tostring(fret)
        local width = ceil(size * 0.65 * #label) + 2
        local y = floor(firstY + (row - 1) * step - size / 2)
        rect(bitmap, x, y, width, size + 1, bg)
        r.JS_LICE_DrawText(bitmap, font, label, #label, x + 1, y, x + width + 1, y + size + 3)
        lastEnd[row] = x + width
      end
    end
    if chord.missed > 0 then
      rect(bitmap, x + 1, firstY - floor(size / 2) - 4, 4, 3, 0xffffac56)
    end
  end)
  r.JS_LICE_Blit(o.front, 0, 0, bitmap, 0, 0, w, h, 1, "COPY")
end

local function updateItem(item, trackY, view, seen)
  local value = r.GetMediaItemInfo_Value
  local start = value(item, "D_POSITION")
  local stop = start + value(item, "D_LENGTH")
  if start >= view.stop or stop <= view.start or value(item, "B_FIXEDLANE_HIDDEN") ~= 0 then return end
  local take = r.GetActiveTake(item)
  if not take or not r.TakeIsMIDI(take) then return end
  if r.BR_IsMidiOpenInInlineEditor and r.BR_IsMidiOpenInInlineEditor(take) then return end
  local itemTop = trackY + value(item, "I_LASTY")
  local takeTop = trackY + r.GetMediaItemTakeInfo_Value(take, "I_LASTY")
  local takeHeight = r.GetMediaItemTakeInfo_Value(take, "I_LASTH")
  local itemHeight = value(item, "I_LASTH")
  if takeHeight <= 0 and r.CountTakes(item) == 1 then
    takeTop, takeHeight = itemTop, itemHeight
  end
  local top = max(itemTop + 2, takeTop)
  local bottom = min(itemTop + itemHeight, takeTop + takeHeight) - 2
  local height = bottom - top
  if height < 12 or bottom <= 0 or top >= view.h then return end
  local x = max(0, floor((start - view.start) * view.zoom))
  local y = max(0, top)
  local w = min(view.w, ceil((stop - view.start) * view.zoom)) - x
  local h = min(view.h, bottom) - y
  if w < 3 or h <= 0 then return end
  seen[take] = true
  local o = overlays[take] or {}
  overlays[take] = o
  local transpose = floor(r.GetMediaItemTakeInfo_Value(take, "D_PITCH") + 0.5)
  if not o.model or view.now >= o.checkAt or o.change ~= view.change or transpose ~= o.transpose then
    local ok, hash = r.MIDI_GetHash(take, false, "")
    if not ok then seen[take] = nil return end
    local state, topChannel = importSettings(take)
    if not o.model or hash ~= o.hash or transpose ~= o.transpose or state ~= o.state or topChannel ~= o.topChannel then
      local strings = parseStrings(state)
      o.model = {chords = readChords(take, transpose, strings, topChannel),
        rows = strings and #strings or #tuning, period = sourceTicks(take)}
      o.state, o.topChannel = state, topChannel
      o.hash, o.transpose, o.key = hash, transpose, nil
    end
    o.change, o.checkAt = view.change, view.now + 0.25
  end
  local looped = value(item, "B_LOOPSRC") ~= 0
  local selected = r.IsMediaItemSelected(item)
  local key = table.concat({x, y, w, h, top, height, view.start, view.zoom, view.change,
    start, stop, r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"), tostring(selected), tostring(looped)}, "/")
  local redraw = key ~= o.key
  if redraw then
    if o.w ~= w or o.h ~= h then
      release(o)
      o.front, o.base = nil, nil
      o.front = assert(r.JS_LICE_CreateBitmap(true, w, h))
      o.base = assert(r.JS_LICE_CreateBitmap(false, w, h))
    end
    o.x, o.y, o.w, o.h, o.key = x, y, w, h, key
    drawStaff(o, take, view, top, height, start, stop, looped, selected)
    o.cursor = nil
    assert(r.JS_Composite(arrange, x, y, w, h, o.front, 0, 0, w, h, true) == 1,
      "Could not display tablature in the arrange view.")
  end
  local cursor = view.cursor - x
  if cursor < 0 or cursor >= w then cursor = nil end
  if cursor ~= o.cursor then
    if o.cursor then
      r.JS_LICE_Blit(o.front, o.cursor, 0, o.base, o.cursor, 0, 1, h, 1, "COPY")
    end
    if cursor then rect(o.front, cursor, 0, 1, h, 0xffffc880) end
    local lo, hi = cursor or o.cursor, o.cursor or cursor
    r.JS_Window_InvalidateRect(arrange, x + min(lo, hi), y, x + max(lo, hi) + 1, y + h, false)
    o.cursor = cursor
  end
end

local function frame()
  local seen = {}
  local active = r.EnumProjects(-1, "")
  if active == project then
    local ok, w, h = r.JS_Window_GetClientSize(arrange)
    if ok and w > 0 and h > 0 then
      local start, stop = r.GetSet_ArrangeView2(project, false, 0, 0)
      local zoom = r.GetHZoomLevel()
      local playing = r.GetPlayStateEx(project) % 2 == 1
      local cursor = playing and r.GetPlayPositionEx(project) or r.GetCursorPositionEx(project)
      local view = {start = start, stop = stop, zoom = zoom, w = w, h = h, now = r.time_precise(),
        change = r.GetProjectStateChangeCount(project), cursor = floor((cursor - start) * zoom + 0.5)}
      for _, track in ipairs(tracks) do
        if r.ValidatePtr2(project, track, "MediaTrack*") and r.IsTrackVisible(track, false) then
          local y = r.GetMediaTrackInfo_Value(track, "I_TCPY")
          if y < h and y + r.GetMediaTrackInfo_Value(track, "I_TCPH") > 0 then
            for i = 0, r.CountTrackMediaItems(track) - 1 do
              updateItem(r.GetTrackMediaItem(track, i), y, view, seen)
            end
          end
        end
      end
    end
  end
  for take, o in pairs(overlays) do
    if not seen[take] then release(o) overlays[take] = nil end
  end
  if active ~= project and not r.ValidatePtr(project, "ReaProject*") then return end
  r.defer(frame)
end
frame()
