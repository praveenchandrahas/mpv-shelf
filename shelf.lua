-- shelf.lua: a Netflix-style film browser for mpv, over a LOCAL folder (for example a debrid mount). Part of mpv-shelf.
--
--   Ctrl+b (set by install-shelf.sh in input.conf: `Ctrl+b script-binding shelf/open`) opens and closes it.
--
-- What it does:
--   * shows the catalog that `shelf-index` wrote (posters, ratings, quality chips), a Continue Watching row, search and sorting
--   * plays by file PATH (loadfile of the real file), so other scripts that key on the path (seekthumbs' thumbnails, profile detection) keep working
--   * remembers where you stopped (history.json in the data folder; mpv's watch_later is not used)
--   * starts `shelf-index` in the background when the catalog is missing or old; it never blocks mpv
--
-- Drawing: text and shapes are ASS (mp.create_osd_overlay), posters are bitmaps (overlay-add) converted from the JPEGs by ffmpeg once per size.
-- Nothing is ever drawn UNDER a poster (it does not matter which layer mpv puts first); badges and bars sit beside or below them.
-- Keys while it is open: arrows move, Enter opens/plays, Esc/Backspace go back, / search, s sort, w watched, r start over, Tab next release,
-- i info (from Continue Watching), u refresh the catalog, q close. The mouse works: click, wheel, hover.
local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"
local options = require "mp.options"

local opts = {
    data_dir = "~/.local/share/mpv-shelf",
    indexer = "shelf-index",      -- the command that builds the catalog (on PATH, or a full path)
    python = "",                  -- set to run the indexer as `python3 shelf-index` when it is not executable
    ffmpeg = "ffmpeg",
    cols = 8,                     -- most posters per row (fewer when the window is narrow)
    max_posters = 28,             -- most poster bitmaps on screen at once
    refresh_hours = 6,            -- the catalog is rebuilt in the background when older than this
    resume_min_s = 60,            -- a film stopped before this is not offered as Continue Watching
    watched_pct = 92,             -- played this far counts as watched
    pause_on_open = false,        -- pause the film when the browser opens over it
    hide_video_when_open = false, -- black background while open (the video track is switched off and back on)
    accent = "FFB054",
}
options.read_options(opts, "shelf")

local VERSION = 1
local function expand(p)
    if p:sub(1, 2) == "~/" then return (os.getenv("HOME") or "") .. p:sub(2) end
    return p
end
local DATA = expand(opts.data_dir)
local function join(a, b) return utils.join_path(a, b) end

-- ------------------------------------------------------------------ files
local function read_json(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    if not s or s == "" then return nil end
    return utils.parse_json(s)
end

local function write_json(path, tbl)
    local s = utils.format_json(tbl)
    if not s then return false end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(s)
    f:close()
    return os.rename(tmp, path) and true or false
end

-- ------------------------------------------------------------------ state
local S = {
    open = false, view = "home", stack = {},
    cat = nil, cat_mtime = nil, byrel = {}, entries = {}, library = "",
    hist = read_json(join(DATA, "history.json")) or {},
    sort = "recent", query = nil,
    sec = 2, idx = 1, scroll = 0,           -- home cursor: section (1 continue, 2 library), index, first visible row of the library grid
    cur = nil,                               -- the entry on the title/show page
    rel_i = 1,                               -- selected release on a title page
    season = nil, ep_i = 1, ep_scroll = 0,   -- show page
    toast = nil, hits = {}, hover = nil, indexing_started = false,
    pos = 0, dur = 0, cur_rel = nil,
}
local load_catalog
local SORTS = { "recent", "title", "year", "rating" }
local SORT_LABEL = { recent = "Recently added", title = "Title", year = "Year", rating = "Rating" }

-- ------------------------------------------------------------------ formatting helpers
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function round(v) return math.floor(v + 0.5) end
local function ulen(s) return #(s:gsub("[\128-\191]", "")) end
local function fmt_time(sec)
    sec = math.floor(sec or 0)
    local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end
local function fmt_runtime(min)
    if not min or min <= 0 then return nil end
    if min < 60 then return min .. " min" end
    return string.format("%dh %dm", math.floor(min / 60), min % 60)
end
local function fmt_size(b)
    b = tonumber(b) or 0
    if b >= 1e9 then return string.format("%.1f GB", b / 1e9) end
    return string.format("%d MB", math.floor(b / 1e6))
end
local function esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "/"):gsub("[{}]", { ["{"] = "(", ["}"] = ")" }):gsub("[\r\n]+", " ")
    return s
end
-- the width of a text is estimated (an ASS overlay cannot measure it): about half the font size per letter
local function est_w(s, fs) return ulen(s) * fs * 0.52 end
local function fit(s, maxw, fs)
    s = tostring(s or "")
    if est_w(s, fs) <= maxw then return s end
    local n = math.max(1, math.floor(maxw / (fs * 0.52)) - 3)
    local out, count = {}, 0
    for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > n then break end
        out[#out + 1] = ch
    end
    return table.concat(out) .. "..."
end
local function wrap(s, maxw, fs, maxlines)
    local lines, line = {}, ""
    for word in tostring(s or ""):gmatch("%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if est_w(try, fs) > maxw and line ~= "" then
            lines[#lines + 1] = line
            line = word
            if #lines >= maxlines then break end
        else
            line = try
        end
    end
    if #lines < maxlines and line ~= "" then lines[#lines + 1] = line end
    local used = 0
    for _, l in ipairs(lines) do used = used + #l + 1 end
    if #lines >= maxlines and used < #(tostring(s or "")) then lines[#lines] = fit(lines[#lines] .. " ...", maxw, fs) end
    return lines
end

-- ------------------------------------------------------------------ ASS drawing
local function col(hex)             -- "RRGGBB" to ASS "&HBBGGRR&"
    local r, g, b = hex:sub(1, 2), hex:sub(3, 4), hex:sub(5, 6)
    return "&H" .. b .. g .. r .. "&"
end
local function alpha(a) return string.format("&H%02X&", clamp(round(a), 0, 255)) end
local C = { accent = opts.accent, text = "E9EEF5", muted = "8A96A8", faint = "566074", card = "1A202A", panel = "11151C", line = "2C3646", bad = "FB7185", ok = "4ADE80", black = "000000" }

local E, IMGS = {}, {}
local function add(s) E[#E + 1] = s end
local function rrect_path(w, h, r)
    w, h = round(w), round(h)
    r = clamp(round(r or 0), 0, math.floor(math.min(w, h) / 2))
    if r == 0 then return string.format("m 0 0 l %d 0 %d %d 0 %d", w, w, h, h) end
    return string.format("m %d 0 l %d 0 b %d 0 %d 0 %d %d l %d %d b %d %d %d %d %d %d l %d %d b 0 %d 0 %d 0 %d l 0 %d b 0 0 0 0 %d 0",
        r, w - r, w, w, w, r, w, h - r, w, h, w, h, w - r, h, r, h, h, h, h - r, r, r)
end
local function rect(x, y, w, h, color, a, r)
    add(string.format("{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c%s\\1a%s\\p1}%s{\\p0}", round(x), round(y), col(color), alpha(a or 0), rrect_path(w, h, r)))
end
local function ring(x, y, w, h, color, thick, r)       -- an outline only: the inside is left alone, the line is drawn outside the box
    add(string.format("{\\an7\\pos(%d,%d)\\1a&HFF&\\bord%d\\shad0\\3c%s\\3a&H00&\\p1}%s{\\p0}", round(x), round(y), round(thick), col(color), rrect_path(w, h, r)))
end
local function star(cx, cy, r, color)                  -- a five-point star drawn as a shape (no font glyph needed)
    local pts = {}
    for i = 0, 9 do
        local ang = -math.pi / 2 + i * math.pi / 5
        local rad = (i % 2 == 0) and r or r * 0.42
        pts[#pts + 1] = string.format("%d %d", round(r + rad * math.cos(ang)), round(r + rad * math.sin(ang)))
    end
    add(string.format("{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c%s\\p1}m %s l %s{\\p0}", round(cx - r), round(cy - r), col(color), pts[1], table.concat(pts, " ", 2)))
end
local function text(x, y, s, fs, color, o)
    o = o or {}
    local sh = o.shadow and "\\bord2\\3c&H000000&\\3a&H60&" or "\\bord0"
    add(string.format("{\\an%d\\pos(%d,%d)\\fs%d\\1c%s\\1a%s%s\\shad0%s%s}%s", o.an or 7, round(x), round(y), round(fs), col(color or C.text), alpha(o.a or 0), sh,
        o.bold and "\\b1" or "\\b0", o.sp and ("\\fsp" .. o.sp) or "", esc(s)))
end

-- ------------------------------------------------------------------ geometry
local G = {}
local function geometry()
    local W, H = mp.get_osd_size()
    if not W or W <= 0 or not H or H <= 0 then W, H = 1280, 720 end
    local sc = H / 1080
    G.W, G.H, G.sc = W, H, sc
    G.margin = round(90 * sc)
    G.gap = round(28 * sc)
    G.pw = round(H * 0.17)
    G.ph = round(G.pw * 1.5)
    G.label = round(74 * sc)
    local usable = W - 2 * G.margin
    G.cols = clamp(math.floor((usable + G.gap) / (G.pw + G.gap)), 2, math.max(2, tonumber(opts.cols) or 6))
    G.gx = round((W - (G.cols * G.pw + (G.cols - 1) * G.gap)) / 2)
    G.head = round(150 * sc)
    G.foot = round(74 * sc)
    G.section = round(46 * sc)
    return G
end
local function fs(v) return v * G.sc end

-- ------------------------------------------------------------------ catalog model
local function sort_entries(list)
    local k = S.sort
    table.sort(list, function(a, b)
        if k == "title" then
            local x, y = (a.title or ""):lower(), (b.title or ""):lower()
            if x ~= y then return x < y end
        elseif k == "year" then
            local x, y = a.year or 0, b.year or 0
            if x ~= y then return x > y end
        elseif k == "rating" then
            local x, y = (a.meta and a.meta.rating) or 0, (b.meta and b.meta.rating) or 0
            if x ~= y then return x > y end
        else
            if (a.added or 0) ~= (b.added or 0) then return (a.added or 0) > (b.added or 0) end
        end
        return (a.key or "") < (b.key or "")
    end)
end

local function subsequence(needle, hay)
    local i = 1
    for ch in hay:gmatch(".") do
        if ch == needle:sub(i, i) then i = i + 1; if i > #needle then return true end end
    end
    return #needle == 0
end
-- simple fuzzy match: each word of the query must be inside the title (a better score) or be a subsequence of it
local function match_score(entry, query)
    local hay = ((entry.title or "") .. " " .. (entry.key or "") .. " " .. tostring(entry.year or "")):lower()
    local score = 0
    for w in query:lower():gmatch("%S+") do
        local s, e = hay:find(w, 1, true)
        if s then
            score = score + 3 + ((s == 1 or hay:sub(s - 1, s - 1) == " ") and 2 or 0)
        elseif #w >= 3 and subsequence(w, hay) then
            score = score + 1
        else
            return nil
        end
    end
    return score
end

local function rebuild()
    local cat = S.cat or { entries = {} }
    S.library = cat.library or ""
    S.byrel, S.entries = {}, {}
    for _, e in ipairs(cat.entries or {}) do
        if e.kind == "film" then
            for _, r in ipairs(e.releases or {}) do S.byrel[r.rel] = { e = e, r = r } end
        else
            for sn, eps in pairs(e.seasons or {}) do
                for _, ep in ipairs(eps) do S.byrel[ep.rel] = { e = e, r = ep, season = tonumber(sn) } end
            end
        end
        S.entries[#S.entries + 1] = e
    end
    sort_entries(S.entries)
end

local function visible_entries()
    if not S.query or S.query == "" then return S.entries end
    local out = {}
    for _, e in ipairs(S.entries) do
        local sc = match_score(e, S.query)
        if sc then out[#out + 1] = { e = e, s = sc, i = #out } end
    end
    table.sort(out, function(a, b) if a.s ~= b.s then return a.s > b.s end return a.i < b.i end)
    local list = {}
    for _, x in ipairs(out) do list[#list + 1] = x.e end
    return list
end

local function season_list(e)
    local n = {}
    for sn in pairs(e.seasons or {}) do n[#n + 1] = tonumber(sn) end
    table.sort(n)
    return n
end
local function episodes_of(e, season) return (e.seasons or {})[tostring(season)] or {} end

local function hist_of(rel) return S.hist[rel] end
local function file_path(rel) return join(S.library, rel) end

-- Continue Watching: unfinished files (newest first), and the next episode of a show whose last episode was finished
local function continue_items()
    local items, shown_show = {}, {}
    local keys = {}
    for rel, h in pairs(S.hist) do
        if S.byrel[rel] then keys[#keys + 1] = rel end
    end
    table.sort(keys, function(a, b) return (S.hist[a].updated or 0) > (S.hist[b].updated or 0) end)
    for _, rel in ipairs(keys) do
        local h, b = S.hist[rel], S.byrel[rel]
        if b.e.kind == "show" then
            if not shown_show[b.e.id] then
                if not h.watched and (h.pos or 0) >= opts.resume_min_s then
                    shown_show[b.e.id] = true
                    items[#items + 1] = { e = b.e, rel = rel, r = b.r, season = b.season, pos = h.pos, dur = h.dur }
                elseif h.watched then
                    shown_show[b.e.id] = true            -- the newest thing for this show was finished: offer the next episode, if any
                    local eps = episodes_of(b.e, b.season)
                    local nxt
                    for i, ep in ipairs(eps) do if ep.rel == rel then nxt = eps[i + 1] end end
                    local ns = b.season
                    if not nxt then
                        for _, sn in ipairs(season_list(b.e)) do
                            if sn > b.season then nxt = episodes_of(b.e, sn)[1]; ns = sn; break end
                        end
                    end
                    if nxt and not (S.hist[nxt.rel] and S.hist[nxt.rel].watched) then
                        items[#items + 1] = { e = b.e, rel = nxt.rel, r = nxt, season = ns, pos = (S.hist[nxt.rel] or {}).pos or 0, dur = (S.hist[nxt.rel] or {}).dur or 0, next = true }
                    end
                end
            end
        elseif not h.watched and (h.pos or 0) >= opts.resume_min_s then
            items[#items + 1] = { e = b.e, rel = rel, r = b.r, pos = h.pos, dur = h.dur }
        end
        if #items >= 12 then break end
    end
    return items
end

-- ------------------------------------------------------------------ posters
local tmpdir, pcache, ppending, pcount = nil, {}, {}, 0
local function ensure_tmp()
    if tmpdir then return end
    local base = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
    tmpdir = join(base, "mpv-shelf-" .. tostring(mp.get_property("pid") or os.time()))
    mp.command_native({ name = "subprocess", playback_only = false, args = { "mkdir", "-p", tmpdir } })
end

local redraw
-- the converted bitmap of an entry's poster at a size, or nil (and a conversion is started; the screen is redrawn when it is ready)
local function poster(e, w, h)
    local pf = e.meta and e.meta.poster
    if not pf then return nil end
    local key = string.format("%s_%dx%d", e.id, w, h)
    if pcache[key] then return pcache[key] end
    if ppending[key] then return nil end
    ensure_tmp()
    ppending[key] = true
    local dst = join(tmpdir, key .. ".bgra")
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { opts.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", join(join(DATA, "posters"), pf), "-vf", string.format("scale=%d:%d", w, h),
                 "-f", "rawvideo", "-pix_fmt", "bgra", dst } },
        function(ok, res)
            ppending[key] = nil
            if not ok or not res or res.status ~= 0 then msg.verbose("poster conversion failed for " .. key); return end
            pcount = pcount + 1
            if pcount > 160 then
                for _, c in pairs(pcache) do os.remove(c.file) end
                pcache, pcount = {}, 0
            end
            pcache[key] = { file = dst, w = w, h = h }
            if S.open then redraw() end
        end)
    return nil
end

local shown = {}      -- overlay slot -> "file@x,y"
local function present_images()
    local base = 20
    local used = {}
    for i, im in ipairs(IMGS) do
        if i > clamp(tonumber(opts.max_posters) or 28, 1, 60) + 2 then break end
        local id = base + i
        local sig = string.format("%s@%d,%d", im.file, im.x, im.y)
        used[id] = true
        if shown[id] ~= sig then
            mp.commandv("overlay-add", tostring(id), tostring(round(im.x)), tostring(round(im.y)), im.file, "0", "bgra", tostring(im.w), tostring(im.h), tostring(im.w * 4))
            shown[id] = sig
        end
    end
    for id in pairs(shown) do
        if not used[id] then mp.commandv("overlay-remove", tostring(id)); shown[id] = nil end
    end
end

-- ------------------------------------------------------------------ pieces used by several views
local function image_or_card(e, x, y, w, h, selected)
    -- a poster bitmap at (x, y, w, h), or a text-only card in its place (a card has a fill, so it is drawn only where no poster will go)
    local p = poster(e, w, h)
    if p then
        IMGS[#IMGS + 1] = { file = p.file, x = x, y = y, w = p.w, h = p.h, sel = selected }
        return true
    end
    rect(x, y, w, h, C.card, 24, 10 * G.sc)
    local lines = wrap(e.title or "", w - 24 * G.sc, fs(26), 4)
    local ty = y + h * 0.5 - (#lines * fs(30)) / 2 - fs(10)
    for i, l in ipairs(lines) do text(x + w / 2, ty + (i - 1) * fs(30), l, fs(26), C.text, { an = 8, bold = true }) end
    if e.year then text(x + w / 2, ty + #lines * fs(30) + fs(8), tostring(e.year), fs(20), C.muted, { an = 8 }) end
    return false
end

local function stars_and_rating(x, y, rating, size)
    if not rating then return 0 end
    star(x + size, y + size, size, C.accent)
    text(x + size * 2 + fs(8), y - fs(2), string.format("%.1f", rating), size * 1.7, C.text, { bold = true })
    return size * 2 + fs(8) + est_w(string.format("%.1f", rating), size * 1.7)
end

local function chip(x, y, label, color)
    local w = est_w(label, fs(18)) + fs(22)
    rect(x, y, w, fs(30), C.line, 30, fs(15))
    text(x + w / 2, y + fs(15), label, fs(18), color or C.text, { an = 5, bold = true })
    return w + fs(8)
end

local function toast_draw()
    if not S.toast then return end
    local w = est_w(S.toast.text, fs(24)) + fs(60)
    local x = (G.W - w) / 2
    rect(x, G.H - G.foot - fs(70), w, fs(48), C.panel, 20, fs(24))
    text(G.W / 2, G.H - G.foot - fs(46), S.toast.text, fs(24), C.text, { an = 5 })
end

local function header(title, right)
    rect(0, 0, G.W, G.head - fs(30), C.panel, 60)
    text(G.margin, fs(46), "SHELF", fs(30), C.accent, { bold = true, sp = 6 })
    text(G.margin + est_w("SHELF", fs(30)) + fs(40), fs(54), title or "", fs(24), C.muted)
    if right then text(G.W - G.margin, fs(54), right, fs(22), C.muted, { an = 9 }) end
end

local function footer(hints)
    rect(0, G.H - G.foot, G.W, G.foot, C.panel, 60)
    text(G.margin, G.H - G.foot + fs(24), hints, fs(21), C.muted)
    local st = S.cat and S.cat.state
    local note = nil
    if not S.cat then note = "No catalog yet"
    elseif st == "listing" or st == "metadata" then note = (st == "metadata" and (S.cat.pending or 0) > 0) and string.format("Fetching artwork, %d to go", S.cat.pending) or "Indexing..." end
    if note then text(G.W - G.margin, G.H - G.foot + fs(24), note, fs(21), C.accent, { an = 9 }) end
end

-- ------------------------------------------------------------------ home
local function home_layout()
    geometry()
    local items = visible_entries()
    local cont = (S.query and S.query ~= "") and {} or continue_items()
    local rowh = G.ph + G.label + fs(24)
    local avail = G.H - G.head - G.foot - G.section * (#cont > 0 and 2 or 1)
    local rows_fit = math.max(1, math.floor(avail / rowh))
    local max_rows = math.max(1, math.floor(clamp(tonumber(opts.max_posters) or 28, 1, 60) / G.cols))
    local vis = math.max(1, math.min(rows_fit, max_rows) - (#cont > 0 and 1 or 0))
    return items, cont, vis
end

local function card(item, x, y, selected, kind)
    local e = item.e
    local pw, ph = G.pw, G.ph
    local px, py, w, h = x, y, pw, ph
    if selected then
        local k = 1.1
        w, h = round(pw * k), round(ph * k)
        px, py = round(x - (w - pw) / 2), round(y - (h - ph) / 2)
    end
    image_or_card(e, px, py, w, h, selected)
    if selected then ring(px - 1, py - 1, w + 2, h + 2, C.accent, 3 * G.sc, 6 * G.sc) end
    local ly = y + ph + (selected and fs(16) or fs(8)) + (kind == "continue" and fs(10) or 0)
    text(x, ly, fit(e.title or "", pw, fs(23)), fs(23), selected and C.text or C.muted, { bold = selected })
    local sub = {}
    if e.kind == "show" then
        sub[#sub + 1] = "TV · " .. #season_list(e) .. (#season_list(e) == 1 and " season" or " seasons")
    else
        if e.year then sub[#sub + 1] = tostring(e.year) end
    end
    local line2 = table.concat(sub, " · ")
    local rx = x
    if e.meta and e.meta.rating then
        local used = stars_and_rating(x, ly + fs(31), e.meta.rating, fs(9))
        rx = x + used + fs(14)
    end
    text(rx, ly + fs(29), fit(line2, pw - (rx - x), fs(19)), fs(19), C.faint)
    if kind == "continue" then
        if item.dur and item.dur > 0 then
            local frac = clamp((item.pos or 0) / item.dur, 0, 1)
            local by = y + ph + (selected and fs(15) or fs(3))        -- below the (possibly enlarged) poster, which is drawn on top of anything under it
            rect(x, by, pw, fs(5), C.line, 0, fs(2))
            rect(x, by, math.max(fs(5), pw * frac), fs(5), C.accent, 0, fs(2))
        end
        if item.next then text(x + pw, ly, "next", fs(18), C.accent, { an = 9, bold = true })
        elseif item.e.kind == "show" and item.season then text(x + pw, ly, string.format("S%dE%d", item.season, item.r.episode or 0), fs(18), C.accent, { an = 9, bold = true }) end
    elseif e.kind == "film" then
        local all = #(e.releases or {}) > 0
        for _, r in ipairs(e.releases or {}) do if not (S.hist[r.rel] and S.hist[r.rel].watched) then all = false end end
        if all then text(x + pw, ly, "Watched", fs(18), C.ok, { an = 9, bold = true }) end
    end
    S.hits[#S.hits + 1] = { x = x, y = y, w = pw, h = ph + G.label, kind = kind, item = item }
end

local function render_home()
    local items, cont, vis = home_layout()
    local right = string.format("%s  ·  %d title%s", SORT_LABEL[S.sort], #items, #items == 1 and "" or "s")
    local title = (S.query and S.query ~= "") and string.format('Search: "%s"   (Esc clears)', S.query) or "Library"
    header(title, right)
    if #S.entries == 0 then
        text(G.W / 2, G.H / 2 - fs(40), S.cat and "The catalog is empty." or "No catalog yet.", fs(40), C.text, { an = 5, bold = true })
        text(G.W / 2, G.H / 2 + fs(10), S.cat and "Check `library` in ~/.config/seekthumbs/config.ini, then press u to rebuild it." or "It is being built in the background; this window fills in when it is ready. Press u to start it again.", fs(24), C.muted, { an = 5 })
        footer("u refresh   q close")
        return
    end
    local y = G.head
    local rowh = G.ph + G.label + fs(24)
    if #cont > 0 then
        text(G.gx, y, "Continue watching", fs(26), C.text, { bold = true })
        y = y + G.section
        for i = 1, math.min(#cont, G.cols) do
            card(cont[i], G.gx + (i - 1) * (G.pw + G.gap), y, S.sec == 1 and S.idx == i, "continue")
        end
        y = y + rowh
    end
    text(G.gx, y, (S.query and S.query ~= "") and "Results" or "All titles", fs(26), C.text, { bold = true })
    y = y + G.section
    if #items == 0 then
        text(G.gx, y + fs(10), "Nothing matches. Esc clears the search.", fs(26), C.muted)
    end
    local total_rows = math.ceil(#items / G.cols)
    S.scroll = clamp(S.scroll, 0, math.max(0, total_rows - vis))
    for r = 0, vis - 1 do
        for c = 1, G.cols do
            local i = (S.scroll + r) * G.cols + c
            local it = items[i]
            if it then card({ e = it }, G.gx + (c - 1) * (G.pw + G.gap), y + r * rowh, S.sec == 2 and S.idx == i, "grid") end
        end
    end
    if total_rows > vis then text(G.W - G.margin, y - fs(34), string.format("row %d of %d", S.scroll + 1, total_rows), fs(20), C.faint, { an = 9 }) end
    footer("Arrows move   Enter open   / search   s sort   w watched   u refresh   q close")
end

-- ------------------------------------------------------------------ title page
local function best_index(e)
    return 1             -- the catalog lists releases best first (resolution, then REMUX, then size)
end

local function button(x, y, label, key, primary)
    local w = est_w(label, fs(24)) + est_w(key, fs(18)) + fs(70)
    rect(x, y, w, fs(56), primary and C.accent or C.line, primary and 0 or 20, fs(28))
    text(x + fs(26), y + fs(28), label, fs(24), primary and "1A1004" or C.text, { an = 4, bold = true })
    text(x + w - fs(22), y + fs(28), key, fs(18), primary and "5A3A10" or C.faint, { an = 6 })
    S.hits[#S.hits + 1] = { x = x, y = y, w = w, h = fs(56), kind = "button", key = key }
    return w + fs(16)
end

local function release_resume(r)
    local h = hist_of(r.rel)
    if h and not h.watched and (h.pos or 0) >= opts.resume_min_s then return h.pos end
    return nil
end

local function render_title()
    local e = S.cur
    header(e.title or "", nil)
    local ph = round(G.H * 0.6)
    local pw = round(ph * 2 / 3)
    local px, py = G.margin, G.head + fs(10)
    image_or_card(e, px, py, pw, ph, false)
    local x = px + pw + fs(70)
    local w = G.W - x - G.margin
    local y = py
    text(x, y, fit(e.title or "", w, fs(54)), fs(54), C.text, { bold = true })
    y = y + fs(78)
    local parts = {}
    if e.year then parts[#parts + 1] = tostring(e.year) end
    local rt = e.meta and fmt_runtime(e.meta.runtime)
    if rt then parts[#parts + 1] = rt end
    local mx = x
    if e.meta and e.meta.rating then mx = x + stars_and_rating(x, y + fs(2), e.meta.rating, fs(11)) + fs(16) end
    text(mx, y, table.concat(parts, " · "), fs(26), C.muted)
    y = y + fs(44)
    if e.meta and e.meta.genres and #e.meta.genres > 0 then
        local cx = x
        for i, g in ipairs(e.meta.genres) do
            if i > 4 then break end
            cx = cx + chip(cx, y, g, C.muted)
        end
        y = y + fs(48)
    end
    local ov = e.meta and e.meta.overview or ""
    if ov == "" then ov = (e.meta and "" or "No artwork or synopsis yet. Add a TMDB key (see the README) and run shelf-index.") end
    for _, l in ipairs(wrap(ov, w, fs(24), 5)) do text(x, y, l, fs(24), C.text, { a = 40 }); y = y + fs(34) end
    y = y + fs(14)
    text(x, y, "Releases", fs(22), C.muted, { bold = true, sp = 2 })
    y = y + fs(34)
    local rels = e.releases or {}
    S.rel_i = clamp(S.rel_i, 1, math.max(1, #rels))
    local shown_n = math.min(#rels, 5)
    local first = clamp(S.rel_i - shown_n + 1, 1, math.max(1, #rels - shown_n + 1))
    for i = first, first + shown_n - 1 do
        local r = rels[i]
        if not r then break end
        local sel = (i == S.rel_i)
        if sel then rect(x - fs(14), y - fs(6), w + fs(28), fs(46), C.card, 10, fs(10)); rect(x - fs(14), y - fs(6), fs(4), fs(46), C.accent, 0, fs(2)) end
        local cx = x
        for _, c in ipairs(r.chips or {}) do
            if cx - x + est_w(c, fs(18)) + fs(30) > w - fs(180) then break end
            cx = cx + chip(cx, y, c, sel and C.text or C.muted)
        end
        local rs = release_resume(r)
        local hh = hist_of(r.rel)
        local tag = hh and hh.watched and "Watched" or (rs and ("Resume " .. fmt_time(rs)) or nil)
        if tag then text(x + w - fs(130), y + fs(15), tag, fs(18), (hh and hh.watched) and C.ok or C.accent, { an = 6, bold = true }) end
        text(x + w, y + fs(15), fmt_size(r.size), fs(19), C.faint, { an = 6 })
        S.hits[#S.hits + 1] = { x = x - fs(14), y = y - fs(6), w = w + fs(28), h = fs(46), kind = "release", i = i }
        y = y + fs(52)
    end
    if #rels > shown_n then text(x, y - fs(4), string.format("%d releases: Tab or the mouse wheel switches", #rels), fs(18), C.faint) end
    y = G.H - G.foot - fs(100)
    local r = rels[S.rel_i]
    local rs = r and release_resume(r)
    local bx = x
    bx = bx + button(bx, y, rs and ("Resume " .. fmt_time(rs)) or "Play", "Enter", true)
    if rs then bx = bx + button(bx, y, "Start over", "r", false) end
    local wm = r and hist_of(r.rel) and hist_of(r.rel).watched
    button(bx, y, wm and "Mark unwatched" or "Mark watched", "w", false)
    footer("Enter play   r start over   Tab next release   w watched   Backspace back   q close")
end

-- ------------------------------------------------------------------ show page (seasons, episodes)
local function render_show()
    local e = S.cur
    header(e.title or "", nil)
    local seasons = season_list(e)
    S.season = S.season or seasons[1]
    local eps = episodes_of(e, S.season)
    local ph = round(G.H * 0.5)
    local pw = round(ph * 2 / 3)
    local px, py = G.margin, G.head + fs(10)
    image_or_card(e, px, py, pw, ph, false)
    local x = px + pw + fs(70)
    local w = G.W - x - G.margin
    local y = py
    text(x, y, fit(e.title or "", w, fs(50)), fs(50), C.text, { bold = true })
    y = y + fs(72)
    local mx = x
    if e.meta and e.meta.rating then mx = x + stars_and_rating(x, y + fs(2), e.meta.rating, fs(11)) + fs(16) end
    text(mx, y, "TV" .. (e.year and (" · " .. e.year) or ""), fs(26), C.muted)
    y = y + fs(48)
    local sx = x
    for _, sn in ipairs(seasons) do
        local label = "Season " .. sn
        local cw = est_w(label, fs(24)) + fs(40)
        local sel = (sn == S.season)
        rect(sx, y, cw, fs(46), sel and C.accent or C.line, sel and 0 or 20, fs(23))
        text(sx + cw / 2, y + fs(23), label, fs(24), sel and "1A1004" or C.text, { an = 5, bold = true })
        S.hits[#S.hits + 1] = { x = sx, y = y, w = cw, h = fs(46), kind = "season", season = sn }
        sx = sx + cw + fs(10)
    end
    y = y + fs(70)
    local rowh = fs(52)
    local vis = math.max(3, math.floor((G.H - G.foot - fs(20) - y) / rowh))
    S.ep_i = clamp(S.ep_i, 1, math.max(1, #eps))
    S.ep_scroll = clamp(S.ep_scroll, 0, math.max(0, #eps - vis))
    if S.ep_i <= S.ep_scroll then S.ep_scroll = S.ep_i - 1 end
    if S.ep_i > S.ep_scroll + vis then S.ep_scroll = S.ep_i - vis end
    for i = S.ep_scroll + 1, math.min(#eps, S.ep_scroll + vis) do
        local ep = eps[i]
        local sel = (i == S.ep_i)
        if sel then rect(x - fs(14), y - fs(6), w + fs(28), rowh - fs(4), C.card, 10, fs(10)); rect(x - fs(14), y - fs(6), fs(4), rowh - fs(4), C.accent, 0, fs(2)) end
        text(x, y + fs(4), string.format("Episode %d", ep.episode or i), fs(24), sel and C.text or C.muted, { bold = sel })
        local cx = x + fs(190)
        for _, c in ipairs(ep.chips or {}) do
            if cx - x + est_w(c, fs(18)) + fs(30) > w - fs(210) then break end
            cx = cx + chip(cx, y, c, C.muted)
        end
        local h = hist_of(ep.rel)
        local tag = h and h.watched and "Watched" or ((h and (h.pos or 0) >= opts.resume_min_s) and ("Resume " .. fmt_time(h.pos)) or nil)
        if tag then text(x + w, y + fs(8), tag, fs(18), (h and h.watched) and C.ok or C.accent, { an = 9, bold = true }) end
        S.hits[#S.hits + 1] = { x = x - fs(14), y = y - fs(6), w = w + fs(28), h = rowh - fs(4), kind = "episode", i = i }
        y = y + rowh
    end
    if #eps == 0 then text(x, y, "No episodes in this season.", fs(24), C.muted) end
    footer("Enter play (the rest of the season follows)   Left/Right season   w watched   Backspace back   q close")
end

-- ------------------------------------------------------------------ drawing
local ov = mp.create_osd_overlay("ass-events")
local last_size = ""
redraw = function()
    if not S.open then return end
    geometry()
    E, IMGS, S.hits = {}, {}, {}
    if S.view == "home" then render_home() elseif S.view == "title" then render_title() else render_show() end
    toast_draw()
    -- the selected poster goes last: it is drawn larger and must be on top of its neighbours
    table.sort(IMGS, function(a, b) return (a.sel and 1 or 0) < (b.sel and 1 or 0) end)
    ov.res_x, ov.res_y = G.W, G.H
    ov.data = table.concat(E, "\n")
    ov:update()
    present_images()
end

local function clear_all()
    ov:remove()
    for id in pairs(shown) do mp.commandv("overlay-remove", tostring(id)) end
    shown = {}
end

local function say(text_, secs)
    S.toast = { text = text_ }
    local mine = S.toast
    mp.add_timeout(secs or 3, function() if S.toast == mine then S.toast = nil; redraw() end end)
    redraw()
end

-- ------------------------------------------------------------------ history
local function save_history() write_json(join(DATA, "history.json"), S.hist) end

local function finalize(reason)
    local rel = S.cur_rel
    if not rel then return end
    S.cur_rel = nil
    local pos, dur = S.pos or 0, S.dur or 0
    local h = S.hist[rel] or {}
    if reason == "eof" or (dur > 0 and pos / dur * 100 >= opts.watched_pct) then
        h.watched, h.pos = true, 0
    elseif pos >= opts.resume_min_s then
        h.watched, h.pos, h.dur = false, pos, dur
    else
        h.pos = 0
        if not h.watched then h.dur = dur end
    end
    h.updated = os.time()
    S.hist[rel] = h
    save_history()
end

local function rel_of_path(path)
    if not path or S.library == "" then return nil end
    local lib = S.library:gsub("/+$", "")
    if path:sub(1, #lib + 1) ~= lib .. "/" then return nil end
    return path:sub(#lib + 2)
end

mp.register_event("file-loaded", function()
    S.pos, S.dur = 0, tonumber(mp.get_property("duration")) or 0
    if S.library == "" then load_catalog(false) end          -- played from the command line before the shelf was ever opened
    S.cur_rel = rel_of_path(mp.get_property("path"))
end)
mp.register_event("end-file", function(e) finalize(e and e.reason) end)
mp.register_event("shutdown", function() finalize("quit") end)
mp.observe_property("time-pos", "number", function(_, v) if v then S.pos = v end end)
mp.observe_property("duration", "number", function(_, v) if v then S.dur = v end end)
mp.add_periodic_timer(30, function()           -- a crash should not lose the position
    local rel = S.cur_rel
    if rel and (S.pos or 0) >= opts.resume_min_s then
        local h = S.hist[rel] or {}
        if not h.watched and math.abs((h.pos or 0) - S.pos) >= 10 then
            h.pos, h.dur, h.updated = S.pos, S.dur, os.time()
            S.hist[rel] = h
            save_history()
        end
    end
end)

-- ------------------------------------------------------------------ playback
local function play(entry, r, start, queue)
    if S.library == "" then say("No library path in the catalog") return end
    local path = file_path(r.rel)
    if start and start > 0 then
        mp.commandv("loadfile", path, "replace", "-1", "start=" .. string.format("%.0f", start))
    else
        mp.commandv("loadfile", path, "replace")
    end
    for _, q in ipairs(queue or {}) do mp.commandv("loadfile", file_path(q.rel), "append") end
    S.close()
end

local function episodes_after(e, season, i)
    local out = {}
    local eps = episodes_of(e, season)
    for k = i + 1, #eps do out[#out + 1] = eps[k] end
    for _, sn in ipairs(season_list(e)) do
        if sn > season then for _, ep in ipairs(episodes_of(e, sn)) do out[#out + 1] = ep end end
    end
    return out
end

-- ------------------------------------------------------------------ catalog loading and the indexer
load_catalog = function(force)
    local path = join(DATA, "catalog.json")
    local info = utils.file_info(path)
    if not info then return false end
    if not force and S.cat_mtime == info.mtime then return false end
    local cat = read_json(path)
    if not cat then return false end
    S.cat, S.cat_mtime = cat, info.mtime
    rebuild()
    return true
end

local function start_indexer(force)
    local info = utils.file_info(join(DATA, "catalog.json"))
    local age = info and (os.time() - info.mtime) or math.huge
    if not force and (S.indexing_started or age < (tonumber(opts.refresh_hours) or 6) * 3600) then return false end
    S.indexing_started = true
    local args = { "run" }
    if opts.python ~= "" then args[#args + 1] = opts.python end
    args[#args + 1] = expand(opts.indexer)
    args[#args + 1] = "scan"
    mp.commandv((table.unpack or unpack)(args))
    msg.info("shelf: started the indexer in the background")
    return true
end

-- ------------------------------------------------------------------ navigation
local function push_view()
    S.stack[#S.stack + 1] = { view = S.view, sec = S.sec, idx = S.idx, scroll = S.scroll, cur = S.cur }
end
local function pop_view()
    local t = table.remove(S.stack)
    if not t then return false end
    S.view, S.sec, S.idx, S.scroll, S.cur = t.view, t.sec, t.idx, t.scroll, t.cur
    return true
end

local function open_entry(e)
    push_view()
    S.cur = e
    if e.kind == "show" then
        S.view = "show"
        local seasons = season_list(e)
        S.season, S.ep_i, S.ep_scroll = seasons[1], 1, 0
        -- start on the episode that is next to watch
        for _, sn in ipairs(seasons) do
            for i, ep in ipairs(episodes_of(e, sn)) do
                local h = hist_of(ep.rel)
                if h and not h.watched and (h.pos or 0) >= opts.resume_min_s then S.season, S.ep_i = sn, i; return end
            end
        end
        local last
        for _, sn in ipairs(seasons) do
            for i, ep in ipairs(episodes_of(e, sn)) do
                if hist_of(ep.rel) and hist_of(ep.rel).watched then last = { sn, i } end
            end
        end
        if last then
            local sn, i = last[1], last[2]
            if i < #episodes_of(e, sn) then S.season, S.ep_i = sn, i + 1 else S.season, S.ep_i = sn, i end
        end
    else
        S.view, S.rel_i = "title", best_index(e)
    end
end

local function grid_items()
    local items, cont, vis = home_layout()
    return items, cont, vis
end

local function move_home(dx, dy)
    local items, cont, vis = grid_items()
    local cols = G.cols
    if S.sec == 1 then
        if dx ~= 0 then S.idx = clamp(S.idx + dx, 1, math.min(#cont, cols)) end
        if dy > 0 and #items > 0 then S.sec = 2; S.idx = math.min(S.idx, #items); S.scroll = 0 end
        return
    end
    if #items == 0 then if dy < 0 and #cont > 0 then S.sec = 1; S.idx = 1 end return end
    local i = S.idx
    if dx ~= 0 then i = clamp(i + dx, 1, #items) end
    if dy ~= 0 then
        local row = math.ceil(i / cols)
        if dy < 0 and row == 1 then
            if #cont > 0 then S.sec = 1; S.idx = math.min(((i - 1) % cols) + 1, #cont); return end
        else
            i = clamp(i + dy * cols, 1, #items)
            if dy > 0 and i == S.idx and row < math.ceil(#items / cols) then i = #items end
        end
    end
    S.idx = i
    local row = math.ceil(i / cols) - 1
    if row < S.scroll then S.scroll = row elseif row >= S.scroll + vis then S.scroll = row - vis + 1 end
end

local function ensure_visible()
    local items, cont, vis = grid_items()
    if S.sec ~= 2 then return end
    S.idx = clamp(S.idx, 1, math.max(1, #items))
    local row = math.ceil(S.idx / G.cols) - 1
    if row < S.scroll then S.scroll = row elseif row >= S.scroll + vis then S.scroll = row - vis + 1 end
end

local function selected_home()
    local items, cont = grid_items()
    if S.sec == 1 then return cont[S.idx], "continue" end
    local e = items[S.idx]
    return e and { e = e } or nil, "grid"
end

local function toggle_watched(rel)
    local h = S.hist[rel] or {}
    h.watched = not h.watched
    if h.watched then h.pos = 0 end
    h.updated = os.time()
    S.hist[rel] = h
    save_history()
end

local function do_search()
    local ok, input = pcall(require, "mp.input")
    if not ok or not input or not input.get then
        say("Search needs mpv 0.38 or newer", 4)
        return
    end
    input.get({
        prompt = "Search: ",
        default_text = S.query or "",
        submit = function(t)
            input.terminate()
            S.query = (t and t ~= "") and t or nil
            S.sec, S.idx, S.scroll = 2, 1, 0
            S.view = "home"
            S.stack = {}
            redraw()
        end,
    })
end

local function cycle_sort()
    for i, k in ipairs(SORTS) do
        if k == S.sort then S.sort = SORTS[i % #SORTS + 1]; break end
    end
    rebuild()
    S.idx, S.scroll = 1, 0
    say("Sorted by " .. SORT_LABEL[S.sort], 2)
end

local function back()
    if S.view == "home" then
        if S.query then S.query = nil; S.idx, S.scroll, S.sec = 1, 0, 2; redraw() else S.close() end
        return
    end
    if not pop_view() then S.view = "home" end
    redraw()
end

-- keys. One handler for every key, because what a key does depends on the page.
local KEYS = { "UP", "DOWN", "LEFT", "RIGHT", "ENTER", "KP_ENTER", "ESC", "BS", "/", "s", "w", "r", "TAB", "Shift+TAB", "i", "u", "q", "PGUP", "PGDWN",
               "HOME", "END", "WHEEL_UP", "WHEEL_DOWN", "MBTN_LEFT", "MBTN_RIGHT", "MOUSE_MOVE" }

local function activate_title()
    local e, rels = S.cur, S.cur.releases or {}
    local r = rels[S.rel_i]
    if not r then return end
    play(e, r, release_resume(r), nil)
end

local function activate_show(start_over)
    local e = S.cur
    local eps = episodes_of(e, S.season)
    local ep = eps[S.ep_i]
    if not ep then return end
    local h = hist_of(ep.rel)
    local start = (not start_over and h and not h.watched and (h.pos or 0) >= opts.resume_min_s) and h.pos or nil
    play(e, ep, start, episodes_after(e, S.season, S.ep_i))
end

local function on_key(k)
    if k == "q" then S.close(); return end
    if k == "u" then
        if start_indexer(true) then say("Rebuilding the catalog in the background", 3) else say("Could not start the indexer", 3) end
        return
    end
    if k == "ESC" or k == "BS" or k == "MBTN_RIGHT" then back(); return end
    if S.view == "home" then
        local items, cont = grid_items()
        if k == "UP" then move_home(0, -1) elseif k == "DOWN" then move_home(0, 1)
        elseif k == "LEFT" then move_home(-1, 0) elseif k == "RIGHT" then move_home(1, 0)
        elseif k == "PGUP" or k == "WHEEL_UP" then
            if S.sec == 2 then S.idx = math.max(1, S.idx - G.cols * (k == "PGUP" and 3 or 1)); if S.idx <= G.cols and #cont > 0 and k == "WHEEL_UP" and S.scroll == 0 then S.sec = 1; S.idx = 1 end end
            ensure_visible()
        elseif k == "PGDWN" or k == "WHEEL_DOWN" then
            if S.sec == 1 then S.sec, S.idx = 2, 1 else S.idx = math.min(#items, S.idx + G.cols * (k == "PGDWN" and 3 or 1)) end
            ensure_visible()
        elseif k == "HOME" then S.sec, S.idx, S.scroll = (#cont > 0 and 1 or 2), 1, 0
        elseif k == "END" then S.sec, S.idx = 2, math.max(1, #items); ensure_visible()
        elseif k == "/" then do_search(); return
        elseif k == "s" then cycle_sort(); return
        elseif k == "ENTER" or k == "KP_ENTER" or k == "i" or k == "MBTN_LEFT" then
            local it, kind = selected_home()
            if it then
                if kind == "continue" and k ~= "i" and k ~= "MBTN_LEFT" then
                    if it.e.kind == "show" then
                        local eps = episodes_of(it.e, it.season)
                        local idx = 1
                        for n, ep in ipairs(eps) do if ep.rel == it.rel then idx = n end end
                        play(it.e, it.r, it.pos and it.pos > 0 and it.pos or nil, episodes_after(it.e, it.season, idx))
                    else
                        play(it.e, it.r, it.pos, nil)
                    end
                else
                    open_entry(it.e)
                end
            end
        elseif k == "w" then
            local it = selected_home()
            if it and it.e.kind == "film" then
                for _, r in ipairs(it.e.releases or {}) do toggle_watched(r.rel) end
                say("Marked", 2)
            end
        end
        redraw()
        return
    end
    if S.view == "title" then
        local rels = S.cur.releases or {}
        if k == "ENTER" or k == "KP_ENTER" then activate_title(); return
        elseif k == "r" then local r = rels[S.rel_i]; if r then play(S.cur, r, nil, nil) end return
        elseif k == "TAB" or k == "DOWN" or k == "WHEEL_DOWN" then S.rel_i = S.rel_i % math.max(1, #rels) + 1
        elseif k == "Shift+TAB" or k == "UP" or k == "WHEEL_UP" then S.rel_i = (S.rel_i - 2) % math.max(1, #rels) + 1
        elseif k == "w" then local r = rels[S.rel_i]; if r then toggle_watched(r.rel) end
        end
        redraw()
        return
    end
    -- show page
    local eps = episodes_of(S.cur, S.season)
    local seasons = season_list(S.cur)
    local function season_step(d)
        for i, sn in ipairs(seasons) do
            if sn == S.season then
                local n = seasons[clamp(i + d, 1, #seasons)]
                if n ~= S.season then S.season, S.ep_i, S.ep_scroll = n, 1, 0 end
                return
            end
        end
    end
    if k == "ENTER" or k == "KP_ENTER" then activate_show(false); return
    elseif k == "r" then activate_show(true); return
    elseif k == "UP" or k == "WHEEL_UP" then S.ep_i = math.max(1, S.ep_i - 1)
    elseif k == "DOWN" or k == "WHEEL_DOWN" then S.ep_i = math.min(#eps, S.ep_i + 1)
    elseif k == "LEFT" then season_step(-1)
    elseif k == "RIGHT" then season_step(1)
    elseif k == "PGUP" then S.ep_i = math.max(1, S.ep_i - 8)
    elseif k == "PGDWN" then S.ep_i = math.min(#eps, S.ep_i + 8)
    elseif k == "w" then local ep = eps[S.ep_i]; if ep then toggle_watched(ep.rel) end
    end
    redraw()
end

local function hit_at(x, y)
    for i = #S.hits, 1, -1 do
        local h = S.hits[i]
        if x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then return h end
    end
    return nil
end

local function on_mouse(k)
    local mx, my = mp.get_mouse_pos()
    local sx, sy = mx or 0, my or 0
    local h = hit_at(sx, sy)
    if k == "MOUSE_MOVE" then
        if S.view == "home" and h and h.kind ~= "button" and h.item then
            local items, cont = grid_items()
            local new_sec, new_idx
            if h.kind == "continue" then
                for i, c in ipairs(cont) do if c == h.item then new_sec, new_idx = 1, i end end
            else
                for i, e in ipairs(items) do if e == h.item.e then new_sec, new_idx = 2, i end end
            end
            if new_idx and (new_sec ~= S.sec or new_idx ~= S.idx) then S.sec, S.idx = new_sec, new_idx; redraw() end
        end
        return
    end
    if k ~= "MBTN_LEFT" then on_key(k); return end
    if not h then return end
    if h.kind == "continue" or h.kind == "grid" then
        local items, cont = grid_items()
        if h.kind == "continue" then
            for i, c in ipairs(cont) do if c == h.item then S.sec, S.idx = 1, i end end
        else
            for i, e in ipairs(items) do if e == h.item.e then S.sec, S.idx = 2, i end end
        end
        on_key("ENTER")
    elseif h.kind == "release" then
        S.rel_i = h.i
        activate_title()
    elseif h.kind == "episode" then
        S.ep_i = h.i
        activate_show(false)
    elseif h.kind == "season" then
        S.season, S.ep_i, S.ep_scroll = h.season, 1, 0
        redraw()
    elseif h.kind == "button" then
        on_key(h.key == "Enter" and "ENTER" or h.key)
    end
end

local bound = false
local function bind_keys()
    if bound then return end
    bound = true
    for _, k in ipairs(KEYS) do
        local f
        if k == "MOUSE_MOVE" or k == "MBTN_LEFT" then f = function() on_mouse(k) end
        else f = function() on_key(k) end end
        mp.add_forced_key_binding(k, "shelf-key-" .. k, f, { repeatable = (k == "UP" or k == "DOWN" or k == "LEFT" or k == "RIGHT" or k == "WHEEL_UP" or k == "WHEEL_DOWN" or k == "PGUP" or k == "PGDWN") })
    end
end
local function unbind_keys()
    if not bound then return end
    bound = false
    for _, k in ipairs(KEYS) do mp.remove_key_binding("shelf-key-" .. k) end
end

local reload_timer, paused_by_us, vid_before
function S.close()
    if not S.open then return end
    S.open = false
    unbind_keys()
    clear_all()
    if reload_timer then reload_timer:kill(); reload_timer = nil end
    if paused_by_us then mp.set_property_native("pause", false); paused_by_us = false end
    if vid_before then mp.set_property("vid", vid_before); vid_before = nil end
end

local function open()
    if S.open then return end
    S.open = true
    S.stack, S.view = {}, "home"
    if not load_catalog(true) then rebuild() end
    S.sec = 2
    S.idx, S.scroll = 1, 0
    local _, cont = grid_items()
    S.cur = nil
    if #cont > 0 then S.sec = 1 end
    start_indexer(false)
    bind_keys()
    if opts.pause_on_open and not mp.get_property_native("pause") and mp.get_property("path") then
        mp.set_property_native("pause", true); paused_by_us = true
    end
    if opts.hide_video_when_open and mp.get_property("path") then
        vid_before = mp.get_property("vid") or "auto"
        mp.set_property("vid", "no")
    end
    reload_timer = mp.add_periodic_timer(5, function()
        if load_catalog(false) then redraw() end
    end)
    redraw()
end

mp.add_key_binding(nil, "open", function() if S.open then S.close() else open() end end)
mp.observe_property("osd-dimensions", "native", function() if S.open then redraw() end end)
mp.add_timeout(3, function() start_indexer(false) end)         -- a catalog that is old (or missing) is rebuilt in the background, whether or not the browser is opened
msg.info("shelf loaded: bind `Ctrl+b script-binding " .. mp.get_script_name() .. "/open`")

-- for the tests
return { state = S, open = open, redraw = redraw, images = function() return IMGS end }
