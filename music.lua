-- MC-CC-Music: ComputerCraft YouTube Music Player
-- Features: Playlist support, Shuffle, Save/Load, Library,
--           Monitor Visualizer, Networked Speakers
-- Requires: CC:Tweaked 1.100.0+, Advanced Computer, Speaker

local api_base_url = "https://ipod-2to6magyna-uc.a.run.app/"
local piped_api = "https://pipedapi.kavin.rocks"
local version = "2.1"
local SAVE_DIR = "playlists"

local width, height = term.getSize()
local tab = 1

-- Search state
local waiting_for_input = false
local last_search = nil
local last_search_url = nil
local search_results = nil
local search_error = false
local search_mode = 1
local in_search_result = false
local clicked_result = nil
local clicked_result_data = nil
local search_scroll = 0
local is_piped_search = false

-- Playlist detail loading
local playlist_detail_url = nil
local playlist_loading = false

-- Playback state
local playing = false
local queue = {}
local now_playing = nil
local looping = 0
local volume = 1.5
local queue_scroll = 0

-- Library state
local saved_playlists = {}
local library_scroll = 0
local in_library_menu = false
local clicked_library_idx = nil

-- Save name input
local waiting_for_save_name = false

-- Toast message
local toast_msg = nil
local toast_timer = nil

-- Visualizer state
local viz_mode = 0  -- 0=Off, 1=Bars, 2=Wave, 3=Fire, 4=Rain, 5=Aurora
local viz_names = { "Off", "Bars", "Wave", "Fire", "Rain", "Aurora" }
local audio_level = 0
local audio_peak = 0
local audio_bands = {}
local audio_history = {}
local beat_detected = false
local viz_state = {
    bar_heights = {},
    bar_peaks = {},
    bar_peak_hold = {},
    wave_buf = {},
    fire = nil,
    fire_w = 0,
    fire_h = 0,
    sparks = {},
    stars = {},
    rain_drops = {},
    rain_chars = {},
}

-- Audio state
local playing_id = nil
local last_download_url = nil
local playing_status = 0
local is_loading = false
local is_error = false

local player_handle = nil
local start = nil
local size = nil
local decoder = require("cc.audio.dfpwm").make_decoder()
local needs_next_chunk = 0
local buffer

-- Find all speakers (local + networked)
local function findAllSpeakers()
    local spks = {}
    local names_seen = {}
    -- Find directly attached and network-wrapped speakers
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "speaker" and not names_seen[name] then
            table.insert(spks, peripheral.wrap(name))
            names_seen[name] = true
        end
    end
    return spks
end

local speakers = findAllSpeakers()
if #speakers == 0 then
    error("No speakers found. Attach a speaker directly or via network cable.", 0)
end

-- Find monitors
local function findMonitor()
    return peripheral.find("monitor")
end

local monitor = findMonitor()

---------------------------------------------------------------------------
-- Utility
---------------------------------------------------------------------------
local function truncStr(s, maxlen)
    if not s then return "" end
    if #s > maxlen then return s:sub(1, maxlen - 2) .. ".." end
    return s
end

local function cleanStr(s)
    if not s then return "" end
    return s:gsub("[^\32-\126]", "?")
end

local function shuffleQueue()
    for i = #queue, 2, -1 do
        local j = math.random(1, i)
        queue[i], queue[j] = queue[j], queue[i]
    end
end

---------------------------------------------------------------------------
-- Playlist save/load
---------------------------------------------------------------------------
local function savePlaylist(name, tracks)
    if not fs.exists(SAVE_DIR) then fs.makeDir(SAVE_DIR) end
    name = name:gsub("[^%w%s%-_]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #name == 0 then name = "Untitled" end
    local path = SAVE_DIR .. "/" .. name .. ".json"
    local f = fs.open(path, "w")
    f.write(textutils.serialiseJSON(tracks))
    f.close()
    return name
end

local function loadPlaylistFile(name)
    local path = SAVE_DIR .. "/" .. name .. ".json"
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    local raw = f.readAll()
    f.close()
    return textutils.unserialiseJSON(raw)
end

local function refreshSavedPlaylists()
    saved_playlists = {}
    if not fs.exists(SAVE_DIR) then return end
    local files = fs.list(SAVE_DIR)
    for _, file in ipairs(files) do
        if file:match("%.json$") then
            local name = file:gsub("%.json$", "")
            local path = SAVE_DIR .. "/" .. file
            local f = fs.open(path, "r")
            local data = textutils.unserialiseJSON(f.readAll())
            f.close()
            table.insert(saved_playlists, { name = name, count = data and #data or 0 })
        end
    end
    table.sort(saved_playlists, function(a, b) return a.name < b.name end)
end

local function deleteSavedPlaylist(name)
    local path = SAVE_DIR .. "/" .. name .. ".json"
    if fs.exists(path) then fs.delete(path) end
    refreshSavedPlaylists()
end

---------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------
local function drawBtn(x, y, label, active, enabled)
    if active then
        term.setTextColor(colors.black)
        term.setBackgroundColor(colors.white)
    elseif enabled == false then
        term.setTextColor(colors.lightGray)
        term.setBackgroundColor(colors.gray)
    else
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.gray)
    end
    term.setCursorPos(x, y)
    term.write(label)
    return #label
end

---------------------------------------------------------------------------
-- Drawing: Tab bar + dispatch
---------------------------------------------------------------------------
function redrawScreen()
    if waiting_for_input or waiting_for_save_name then return end
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.clear()

    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    local tabs = { " Now Playing ", " Search ", " Library " }
    for i = 1, #tabs do
        if tab == i then
            term.setTextColor(colors.black)
            term.setBackgroundColor(colors.white)
        else
            term.setTextColor(colors.white)
            term.setBackgroundColor(colors.gray)
        end
        term.setCursorPos(math.floor((width / #tabs) * (i - 0.5)) - math.ceil(#tabs[i] / 2) + 1, 1)
        term.write(tabs[i])
    end

    if tab == 1 then drawNowPlaying()
    elseif tab == 2 then drawSearch()
    elseif tab == 3 then drawLibrary()
    end

    if toast_msg then
        local tw = #toast_msg + 4
        local tx = math.floor((width - tw) / 2) + 1
        term.setCursorPos(tx, height)
        term.setBackgroundColor(colors.green)
        term.setTextColor(colors.white)
        term.write("  " .. toast_msg .. "  ")
    end
end

---------------------------------------------------------------------------
-- Drawing: Now Playing
---------------------------------------------------------------------------
function drawNowPlaying()
    term.setBackgroundColor(colors.black)

    if now_playing ~= nil then
        term.setTextColor(colors.cyan)
        term.setCursorPos(2, 3)
        term.write("\16 ")
        term.setTextColor(colors.white)
        term.write(truncStr(now_playing.name, width - 4))
        term.setTextColor(colors.lightGray)
        term.setCursorPos(4, 4)
        term.write(truncStr(now_playing.artist, width - 4))
    else
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 3)
        term.write("Nothing playing")
        term.setCursorPos(2, 4)
        term.setTextColor(colors.gray)
        term.write("Search for a song to get started")
    end

    if is_loading then
        term.setTextColor(colors.yellow)
        term.setCursorPos(2, 5)
        term.write("Loading...")
    elseif is_error then
        term.setTextColor(colors.red)
        term.setCursorPos(2, 5)
        term.write("Network error")
    end

    -- Controls row
    local has_content = now_playing ~= nil or #queue > 0
    local bx = 2
    if playing then
        bx = bx + drawBtn(bx, 6, " Stop ", false) + 1
    else
        bx = bx + drawBtn(bx, 6, " Play ", false, has_content) + 1
    end
    bx = bx + drawBtn(bx, 6, " Skip ", false, has_content) + 1
    bx = bx + drawBtn(bx, 6, " Shuf ", false, #queue > 1) + 1
    if looping == 0 then
        drawBtn(bx, 6, " Loop Off ", false)
    elseif looping == 1 then
        drawBtn(bx, 6, " Loop All ", true)
    else
        drawBtn(bx, 6, " Loop One ", true)
    end

    -- Volume slider (row 7)
    paintutils.drawBox(2, 7, 25, 7, colors.gray)
    local vw = math.floor(24 * (volume / 3) + 0.5) - 1
    if vw >= 0 then
        paintutils.drawBox(2, 7, 2 + vw, 7, colors.cyan)
    end
    local pct = math.floor(100 * (volume / 3) + 0.5) .. "%"
    if volume < 0.6 then
        term.setCursorPos(2 + vw + 2, 7)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
    else
        term.setCursorPos(2 + vw - 3 - (volume == 3 and 1 or 0), 7)
        term.setBackgroundColor(colors.cyan)
        term.setTextColor(colors.black)
    end
    term.write(pct)

    -- Speakers count (right side of row 7)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.gray)
    term.setCursorPos(27, 7)
    term.write(#speakers .. " speaker" .. (#speakers > 1 and "s" or ""))

    -- Row 8: Viz selector + Save + Clear
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2, 8)
    if #queue > 0 then
        term.write("Queue (" .. #queue .. ")")
    else
        term.write("Queue")
    end

    -- Visualizer button (only when monitor detected)
    monitor = findMonitor()
    if monitor then
        local viz_label = " Viz:" .. viz_names[viz_mode + 1] .. " "
        drawBtn(width - 21, 8, viz_label, viz_mode > 0)
    end

    local clear_label = " Clear "
    local save_label = " Save "
    local clear_x = width - #clear_label
    local save_x = clear_x - #save_label - 1
    drawBtn(save_x, 8, save_label, false, has_content)
    drawBtn(clear_x, 8, clear_label, false, #queue > 0)

    -- Queue list (row 9+)
    if #queue > 0 then
        local max_visible = math.floor((height - 9) / 2)
        if max_visible < 1 then max_visible = 1 end
        if queue_scroll > math.max(0, #queue - max_visible) then
            queue_scroll = math.max(0, #queue - max_visible)
        end
        for i = 1, max_visible do
            local idx = i + queue_scroll
            if idx > #queue then break end
            local num = tostring(idx) .. "."
            term.setTextColor(colors.gray)
            term.setCursorPos(2, 9 + (i - 1) * 2)
            term.write(num)
            term.setTextColor(colors.white)
            term.setCursorPos(2 + #num + 1, 9 + (i - 1) * 2)
            term.write(truncStr(queue[idx].name, width - 3 - #num))
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2 + #num + 1, 10 + (i - 1) * 2)
            term.write(truncStr(queue[idx].artist, width - 3 - #num))
        end
        if queue_scroll > 0 then
            term.setTextColor(colors.cyan)
            term.setCursorPos(width, 9)
            term.write("\24")
        end
        if queue_scroll + max_visible < #queue then
            term.setTextColor(colors.cyan)
            term.setCursorPos(width, height)
            term.write("\25")
        end
    else
        term.setTextColor(colors.gray)
        term.setCursorPos(2, 9)
        term.write("Queue is empty")
    end
end

---------------------------------------------------------------------------
-- Drawing: Search
---------------------------------------------------------------------------
function drawSearch()
    paintutils.drawFilledBox(2, 3, width - 1, 3, colors.lightGray)
    term.setBackgroundColor(colors.lightGray)
    term.setCursorPos(3, 3)
    term.setTextColor(colors.black)
    term.write(truncStr(last_search or "Search...", width - 4))

    local bx = 2
    if search_mode == 1 then
        bx = bx + drawBtn(bx, 5, " Songs ", true) + 1
        drawBtn(bx, 5, " Playlists ", false)
    else
        bx = bx + drawBtn(bx, 5, " Songs ", false) + 1
        drawBtn(bx, 5, " Playlists ", true)
    end

    local rsy = 7
    if search_results ~= nil and #search_results > 0 then
        term.setBackgroundColor(colors.black)
        local mv = math.floor((height - rsy) / 2)
        if mv < 1 then mv = 1 end
        if search_scroll > math.max(0, #search_results - mv) then
            search_scroll = math.max(0, #search_results - mv)
        end
        for i = 1, mv do
            local idx = i + search_scroll
            if idx > #search_results then break end
            local r = search_results[idx]
            term.setCursorPos(2, rsy + (i - 1) * 2)
            if r.type == "playlist" or r.type == "playlist_search" then
                term.setTextColor(colors.cyan)
                term.write(truncStr("[PL] " .. (r.name or ""), width - 2))
            else
                term.setTextColor(colors.white)
                term.write(truncStr(r.name or "", width - 2))
            end
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2, rsy + 1 + (i - 1) * 2)
            term.write(truncStr(r.artist or "", width - 2))
        end
        if search_scroll > 0 then
            term.setTextColor(colors.cyan)
            term.setCursorPos(width, rsy)
            term.write("\24")
        end
        if search_scroll + mv < #search_results then
            term.setTextColor(colors.cyan)
            term.setCursorPos(width, height)
            term.write("\25")
        end
    elseif search_results ~= nil and #search_results == 0 then
        term.setCursorPos(2, rsy)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        term.write("No results found")
    else
        term.setCursorPos(2, rsy)
        term.setBackgroundColor(colors.black)
        if search_error then
            term.setTextColor(colors.red)
            term.write("Network error")
        elseif last_search_url ~= nil then
            term.setTextColor(colors.lightGray)
            term.write("Searching...")
        else
            term.setTextColor(colors.lightGray)
            term.write("Search for songs or paste a")
            term.setCursorPos(2, rsy + 1)
            term.write("YouTube video/playlist URL.")
            term.setCursorPos(2, rsy + 3)
            term.setTextColor(colors.gray)
            term.write("Switch to Playlists mode to")
            term.setCursorPos(2, rsy + 4)
            term.write("search for playlists by name.")
        end
    end

    if in_search_result then drawResultMenu() end
end

function drawResultMenu()
    term.setBackgroundColor(colors.black)
    term.clear()
    if playlist_loading then
        term.setCursorPos(2, height / 2)
        term.setTextColor(colors.yellow)
        term.write("Loading playlist details...")
        return
    end
    local data = clicked_result_data or search_results[clicked_result]
    if not data then in_search_result = false; return end

    term.setCursorPos(2, 2)
    term.setTextColor(colors.white)
    term.write(truncStr(data.name or "", width - 2))
    term.setCursorPos(2, 3)
    term.setTextColor(colors.lightGray)
    term.write(truncStr(data.artist or "", width - 2))

    local is_pl = (data.type == "playlist") and data.playlist_items
    if is_pl then
        term.setCursorPos(2, 4)
        term.setTextColor(colors.cyan)
        term.write(#data.playlist_items .. " tracks")
    end

    local pfx = is_pl and "all " or ""
    drawBtn(2, 6, " Play " .. pfx .. "now" .. string.rep(" ", 20 - #pfx), false)
    drawBtn(2, 8, " Play " .. pfx .. "next" .. string.rep(" ", 19 - #pfx), false)
    drawBtn(2, 10, " Add " .. pfx .. "to queue" .. string.rep(" ", 16 - #pfx), false)
    drawBtn(2, 13, " Cancel" .. string.rep(" ", 21), false)
end

---------------------------------------------------------------------------
-- Drawing: Library
---------------------------------------------------------------------------
function drawLibrary()
    term.setBackgroundColor(colors.black)
    term.setCursorPos(2, 3)
    term.setTextColor(colors.white)
    term.write("Saved Playlists")

    if #saved_playlists == 0 then
        term.setCursorPos(2, 5)
        term.setTextColor(colors.gray)
        term.write("No saved playlists yet.")
        term.setCursorPos(2, 7)
        term.write("Use the Save button on the")
        term.setCursorPos(2, 8)
        term.write("Now Playing tab to save your")
        term.setCursorPos(2, 9)
        term.write("current queue as a playlist.")
        return
    end

    local lsy = 5
    local mv = height - lsy
    if mv < 1 then mv = 1 end
    if library_scroll > math.max(0, #saved_playlists - mv) then
        library_scroll = math.max(0, #saved_playlists - mv)
    end
    for i = 1, mv do
        local idx = i + library_scroll
        if idx > #saved_playlists then break end
        local pl = saved_playlists[idx]
        term.setCursorPos(2, lsy + (i - 1))
        term.setTextColor(colors.cyan)
        term.write("\16 ")
        term.setTextColor(colors.white)
        local count_str = " (" .. pl.count .. ")"
        term.write(truncStr(pl.name, width - 4 - #count_str))
        term.setTextColor(colors.gray)
        term.write(count_str)
    end
    if library_scroll > 0 then
        term.setTextColor(colors.cyan)
        term.setCursorPos(width, lsy)
        term.write("\24")
    end
    if library_scroll + mv < #saved_playlists then
        term.setTextColor(colors.cyan)
        term.setCursorPos(width, height)
        term.write("\25")
    end

    if in_library_menu then drawLibraryMenu() end
end

function drawLibraryMenu()
    term.setBackgroundColor(colors.black)
    term.clear()
    local pl = saved_playlists[clicked_library_idx]
    if not pl then in_library_menu = false; return end
    term.setCursorPos(2, 2)
    term.setTextColor(colors.white)
    term.write(truncStr(pl.name, width - 2))
    term.setCursorPos(2, 3)
    term.setTextColor(colors.gray)
    term.write(pl.count .. " tracks")

    drawBtn(2, 5, " Play now                  ", false)
    drawBtn(2, 7, " Add to queue              ", false)
    drawBtn(2, 9, " Delete                    ", false)
    drawBtn(2, 12, " Cancel                    ", false)
end

---------------------------------------------------------------------------
-- Search + Actions
---------------------------------------------------------------------------
local function doSearch(input)
    if string.len(input) == 0 then
        last_search, last_search_url, search_results, search_error = nil, nil, nil, false
        is_piped_search = false
        return
    end
    last_search = input
    search_results, search_error, search_scroll = nil, false, 0

    local has_list = input:match("[?&]list=([%w_%-]+)")
    local has_video = input:match("youtu") and (input:match("v=([%w_%-]+)") or input:match("youtu%.be/([%w_%-]+)"))

    if has_list or has_video or search_mode == 1 then
        is_piped_search = false
        last_search_url = api_base_url .. "?v=" .. version .. "&search=" .. textutils.urlEncode(input)
        http.request(last_search_url)
    else
        is_piped_search = true
        last_search_url = piped_api .. "/search?q=" .. textutils.urlEncode(input) .. "&filter=playlists"
        http.request(last_search_url)
    end
end

local function showToast(msg)
    toast_msg = msg
    toast_timer = os.startTimer(2)
    os.queueEvent("redraw_screen")
end

local function actionPlayNow(data)
    for _, speaker in ipairs(speakers) do
        speaker.stop()
        os.queueEvent("playback_stopped")
    end
    playing, is_error, playing_id = true, false, nil
    if data.type == "playlist" and data.playlist_items and #data.playlist_items > 0 then
        now_playing = data.playlist_items[1]
        queue = {}
        for i = 2, #data.playlist_items do table.insert(queue, data.playlist_items[i]) end
    else
        now_playing = data
    end
    queue_scroll = 0
    os.queueEvent("audio_update")
end

local function actionPlayNext(data)
    if data.type == "playlist" and data.playlist_items then
        for i = #data.playlist_items, 1, -1 do table.insert(queue, 1, data.playlist_items[i]) end
    else
        table.insert(queue, 1, data)
    end
    os.queueEvent("audio_update")
end

local function actionAddToQueue(data)
    if data.type == "playlist" and data.playlist_items then
        for i = 1, #data.playlist_items do table.insert(queue, data.playlist_items[i]) end
    else
        table.insert(queue, data)
    end
    os.queueEvent("audio_update")
end

local function getCurrentTracklist()
    local tracks = {}
    if now_playing then table.insert(tracks, { id = now_playing.id, name = now_playing.name, artist = now_playing.artist }) end
    for _, t in ipairs(queue) do table.insert(tracks, { id = t.id, name = t.name, artist = t.artist }) end
    return tracks
end

---------------------------------------------------------------------------
-- UI Loop
---------------------------------------------------------------------------
function uiLoop()
    refreshSavedPlaylists()
    redrawScreen()

    while true do
        if waiting_for_save_name then
            term.setBackgroundColor(colors.black)
            term.clear()
            term.setCursorPos(2, 3)
            term.setTextColor(colors.white)
            term.write("Save Queue as Playlist")
            term.setCursorPos(2, 5)
            term.setTextColor(colors.lightGray)
            term.write("Enter a name:")
            paintutils.drawFilledBox(2, 7, width - 1, 7, colors.white)
            term.setCursorPos(3, 7)
            term.setBackgroundColor(colors.white)
            term.setTextColor(colors.black)
            local input = read()
            waiting_for_save_name = false
            if input and #input > 0 then
                local tracks = getCurrentTracklist()
                if #tracks > 0 then
                    local sn = savePlaylist(input, tracks)
                    refreshSavedPlaylists()
                    showToast("Saved: " .. sn)
                else showToast("Nothing to save") end
            end
            os.queueEvent("redraw_screen")
        elseif waiting_for_input then
            parallel.waitForAny(
                function()
                    term.setCursorPos(3, 3)
                    term.setBackgroundColor(colors.white)
                    term.setTextColor(colors.black)
                    local input = read()
                    doSearch(input)
                    waiting_for_input = false
                    os.queueEvent("redraw_screen")
                end,
                function()
                    while waiting_for_input do
                        local _, _, x, y = os.pullEvent("mouse_click")
                        if y ~= 3 or x < 2 or x > width - 1 then
                            waiting_for_input = false
                            os.queueEvent("redraw_screen")
                            break
                        end
                    end
                end
            )
        else
            parallel.waitForAny(
                function() local _, btn, x, y = os.pullEvent("mouse_click"); handleClick(btn, x, y) end,
                function()
                    local _, btn, x, y = os.pullEvent("mouse_drag")
                    if btn == 1 and tab == 1 then
                        if y >= 6 and y <= 8 and x >= 1 and x < 26 then
                            volume = (x - 1) / 24 * 3
                            redrawScreen()
                        end
                    end
                end,
                function() local _, dir = os.pullEvent("mouse_scroll"); handleScroll(dir) end,
                function() os.pullEvent("redraw_screen"); redrawScreen() end,
                function()
                    while true do
                        local _, id = os.pullEvent("timer")
                        if id == toast_timer then
                            toast_msg, toast_timer = nil, nil
                            os.queueEvent("redraw_screen")
                            break
                        end
                    end
                end
            )
        end
    end
end

function handleScroll(dir)
    if tab == 1 then
        local mv = math.floor((height - 9) / 2)
        if mv < 1 then mv = 1 end
        if dir == 1 then queue_scroll = math.min(queue_scroll + 1, math.max(0, #queue - mv))
        else queue_scroll = math.max(0, queue_scroll - 1) end
        redrawScreen()
    elseif tab == 2 and not in_search_result and search_results then
        local mv = math.floor((height - 7) / 2)
        if mv < 1 then mv = 1 end
        if dir == 1 then search_scroll = math.min(search_scroll + 1, math.max(0, #search_results - mv))
        else search_scroll = math.max(0, search_scroll - 1) end
        redrawScreen()
    elseif tab == 3 and not in_library_menu then
        local mv = height - 5
        if mv < 1 then mv = 1 end
        if dir == 1 then library_scroll = math.min(library_scroll + 1, math.max(0, #saved_playlists - mv))
        else library_scroll = math.max(0, library_scroll - 1) end
        redrawScreen()
    end
end

function handleClick(button, x, y)
    if y == 1 and not in_search_result and not in_library_menu then
        local new_tab = math.ceil(x / (width / 3))
        if new_tab >= 1 and new_tab <= 3 then
            tab = new_tab
            if tab == 3 then refreshSavedPlaylists() end
        end
        redrawScreen()
        return
    end
    if tab == 1 then handleNowPlayingClick(button, x, y)
    elseif tab == 2 and not in_search_result then handleSearchTabClick(button, x, y)
    elseif tab == 2 and in_search_result then handleResultMenuClick(button, x, y)
    elseif tab == 3 and not in_library_menu then handleLibraryClick(button, x, y)
    elseif tab == 3 and in_library_menu then handleLibraryMenuClick(button, x, y)
    end
end

---------------------------------------------------------------------------
-- Click handlers
---------------------------------------------------------------------------
function handleSearchTabClick(button, x, y)
    if y == 3 and x >= 2 and x <= width - 1 then
        paintutils.drawFilledBox(2, 3, width - 1, 3, colors.white)
        waiting_for_input = true
        return
    end
    if y == 5 then
        if x >= 2 and x < 9 then
            if search_mode ~= 1 then
                search_mode = 1; search_results, search_error, search_scroll, last_search_url = nil, false, 0, nil
                if last_search then doSearch(last_search) end
            end
            redrawScreen(); return
        elseif x >= 10 and x < 21 then
            if search_mode ~= 2 then
                search_mode = 2; search_results, search_error, search_scroll, last_search_url = nil, false, 0, nil
                if last_search then doSearch(last_search) end
            end
            redrawScreen(); return
        end
    end
    if search_results and button == 1 then
        local rsy = 7
        local mv = math.floor((height - rsy) / 2)
        if mv < 1 then mv = 1 end
        for i = 1, mv do
            local idx = i + search_scroll
            if idx > #search_results then break end
            local ry = rsy + (i - 1) * 2
            if y == ry or y == ry + 1 then
                term.setBackgroundColor(colors.white); term.setTextColor(colors.black)
                term.setCursorPos(2, ry); term.clearLine()
                term.write(truncStr(search_results[idx].name or "", width - 2))
                sleep(0.15)
                clicked_result, clicked_result_data, playlist_loading = idx, nil, false
                if search_results[idx].type == "playlist_search" then
                    in_search_result, playlist_loading = true, true
                    local pid = search_results[idx].id
                    playlist_detail_url = api_base_url .. "?v=" .. version .. "&search=" .. textutils.urlEncode("https://www.youtube.com/playlist?list=" .. pid)
                    http.request(playlist_detail_url)
                else
                    in_search_result = true
                end
                redrawScreen(); return
            end
        end
    end
end

function handleResultMenuClick(button, x, y)
    if playlist_loading then return end
    local data = clicked_result_data or search_results[clicked_result]
    if not data then in_search_result = false; redrawScreen(); return end

    term.setBackgroundColor(colors.white); term.setTextColor(colors.black)
    local count = 1
    if data.type == "playlist" and data.playlist_items then count = #data.playlist_items end

    if y == 6 then
        term.setCursorPos(2, 6); term.clearLine(); term.write(" Play now"); sleep(0.15)
        in_search_result, clicked_result_data = false, nil
        actionPlayNow(data); tab = 1; redrawScreen()
    elseif y == 8 then
        term.setCursorPos(2, 8); term.clearLine(); term.write(" Play next"); sleep(0.15)
        in_search_result, clicked_result_data = false, nil
        actionPlayNext(data); showToast("Added " .. count .. " to queue"); redrawScreen()
    elseif y == 10 then
        term.setCursorPos(2, 10); term.clearLine(); term.write(" Add to queue"); sleep(0.15)
        in_search_result, clicked_result_data = false, nil
        actionAddToQueue(data); showToast("Added " .. count .. " to queue"); redrawScreen()
    elseif y == 13 then
        term.setCursorPos(2, 13); term.clearLine(); term.write(" Cancel"); sleep(0.15)
        in_search_result, clicked_result_data = false, nil; redrawScreen()
    end
end

function handleNowPlayingClick(button, x, y)
    local has_content = now_playing ~= nil or #queue > 0

    if y == 6 then
        -- Play/Stop (x 2..7)
        if x >= 2 and x <= 7 then
            if playing or has_content then
                term.setBackgroundColor(colors.white); term.setTextColor(colors.black)
                term.setCursorPos(2, 6); term.write(playing and " Stop " or " Play ")
                sleep(0.15)
            end
            if playing then
                playing = false
                for _, sp in ipairs(speakers) do sp.stop(); os.queueEvent("playback_stopped") end
                playing_id, is_loading, is_error = nil, false, false
                os.queueEvent("audio_update")
            elseif now_playing then
                playing_id, playing, is_error = nil, true, false
                os.queueEvent("audio_update")
            elseif #queue > 0 then
                now_playing = queue[1]; table.remove(queue, 1)
                playing_id, playing, is_error = nil, true, false
                os.queueEvent("audio_update")
            end
            redrawScreen(); return
        end
        -- Skip (x 9..14)
        if x >= 9 and x <= 14 then
            if has_content then
                term.setBackgroundColor(colors.white); term.setTextColor(colors.black)
                term.setCursorPos(9, 6); term.write(" Skip "); sleep(0.15)
                is_error = false
                if playing then
                    for _, sp in ipairs(speakers) do sp.stop(); os.queueEvent("playback_stopped") end
                end
                if #queue > 0 then
                    if looping == 1 then table.insert(queue, now_playing) end
                    now_playing = queue[1]; table.remove(queue, 1); playing_id = nil
                else
                    now_playing, playing, is_loading, is_error, playing_id = nil, false, false, false, nil
                end
                os.queueEvent("audio_update")
            end
            redrawScreen(); return
        end
        -- Shuffle (x 16..21)
        if x >= 16 and x <= 21 and #queue > 1 then
            term.setBackgroundColor(colors.white); term.setTextColor(colors.black)
            term.setCursorPos(16, 6); term.write(" Shuf "); sleep(0.15)
            shuffleQueue(); queue_scroll = 0; showToast("Queue shuffled")
            redrawScreen(); return
        end
        -- Loop (x 23+)
        if x >= 23 then
            looping = (looping + 1) % 3
            redrawScreen(); return
        end
    end

    -- Volume (row 7)
    if y == 7 and x >= 1 and x < 26 then
        volume = (x - 1) / 24 * 3; redrawScreen(); return
    end

    -- Row 8 buttons
    if y == 8 then
        -- Viz button
        monitor = findMonitor()
        if monitor then
            local viz_label = " Viz:" .. viz_names[viz_mode + 1] .. " "
            local viz_x = width - 21
            if x >= viz_x and x < viz_x + #viz_label then
                viz_mode = (viz_mode + 1) % #viz_names
                -- Reset viz state on change
                viz_state.fire = nil
                viz_state.rain_drops = {}
                viz_state.rain_chars = {}
                viz_state.stars = {}
                viz_state.bar_heights = {}
                if viz_mode == 0 and monitor then
                    monitor.setBackgroundColor(colors.black)
                    monitor.clear()
                end
                redrawScreen(); return
            end
        end

        local clear_label = " Clear "
        local save_label = " Save "
        local clear_x = width - #clear_label
        local save_x = clear_x - #save_label - 1
        if x >= save_x and x < save_x + #save_label and has_content then
            waiting_for_save_name = true; return
        end
        if x >= clear_x and x < clear_x + #clear_label and #queue > 0 then
            queue, queue_scroll = {}, 0; showToast("Queue cleared")
            os.queueEvent("audio_update"); redrawScreen(); return
        end
    end

    -- Queue right-click remove (row 9+)
    if button == 2 and #queue > 0 and y >= 9 then
        local mv = math.floor((height - 9) / 2)
        if mv < 1 then mv = 1 end
        for i = 1, mv do
            local idx = i + queue_scroll
            if idx > #queue then break end
            local ry = 9 + (i - 1) * 2
            if y == ry or y == ry + 1 then
                local removed = queue[idx].name
                table.remove(queue, idx)
                if queue_scroll > 0 and queue_scroll >= #queue then queue_scroll = math.max(0, #queue - mv) end
                showToast("Removed: " .. truncStr(removed, 20))
                redrawScreen(); return
            end
        end
    end
end

function handleLibraryClick(button, x, y)
    if #saved_playlists == 0 then return end
    local lsy = 5
    local mv = height - lsy
    if mv < 1 then mv = 1 end
    for i = 1, mv do
        local idx = i + library_scroll
        if idx > #saved_playlists then break end
        if y == lsy + (i - 1) then
            term.setBackgroundColor(colors.white); term.setTextColor(colors.black)
            term.setCursorPos(2, y); term.clearLine()
            term.write(truncStr(saved_playlists[idx].name, width - 2))
            sleep(0.15)
            clicked_library_idx = idx; in_library_menu = true
            redrawScreen(); return
        end
    end
end

function handleLibraryMenuClick(button, x, y)
    local pl = saved_playlists[clicked_library_idx]
    if not pl then in_library_menu = false; redrawScreen(); return end
    term.setBackgroundColor(colors.white); term.setTextColor(colors.black)

    if y == 5 then
        term.setCursorPos(2, 5); term.clearLine(); term.write(" Play now"); sleep(0.15)
        local tracks = loadPlaylistFile(pl.name)
        if tracks and #tracks > 0 then
            in_library_menu = false
            for _, sp in ipairs(speakers) do sp.stop(); os.queueEvent("playback_stopped") end
            playing, is_error, playing_id = true, false, nil
            now_playing = tracks[1]; queue = {}
            for i = 2, #tracks do table.insert(queue, tracks[i]) end
            queue_scroll = 0; tab = 1
            os.queueEvent("audio_update"); showToast("Playing: " .. pl.name)
        end
        redrawScreen()
    elseif y == 7 then
        term.setCursorPos(2, 7); term.clearLine(); term.write(" Add to queue"); sleep(0.15)
        local tracks = loadPlaylistFile(pl.name)
        if tracks and #tracks > 0 then
            in_library_menu = false
            for _, t in ipairs(tracks) do table.insert(queue, t) end
            os.queueEvent("audio_update"); showToast("Added " .. #tracks .. " tracks")
        end
        redrawScreen()
    elseif y == 9 then
        term.setCursorPos(2, 9); term.clearLine(); term.write(" Delete"); sleep(0.15)
        deleteSavedPlaylist(pl.name); in_library_menu = false
        showToast("Deleted: " .. pl.name); redrawScreen()
    elseif y == 12 then
        term.setCursorPos(2, 12); term.clearLine(); term.write(" Cancel"); sleep(0.15)
        in_library_menu = false; redrawScreen()
    end
end

---------------------------------------------------------------------------
-- VISUALIZERS
---------------------------------------------------------------------------
local fire_palette = { colors.black, colors.gray, colors.brown, colors.red, colors.orange, colors.yellow, colors.white }

local function heatToColor(heat)
    local idx = math.floor(heat + 0.5) + 1
    if idx < 1 then idx = 1 end
    if idx > #fire_palette then idx = #fire_palette end
    return fire_palette[idx]
end

local bar_colors_bottom = colors.green
local bar_colors_mid = colors.yellow
local bar_colors_top = colors.red

local rain_chars = "abcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()"

---------------------------------------------------------------------------
-- Visualizer 1: Spectrum Bars
---------------------------------------------------------------------------
local function drawSpectrumBars(mon)
    local mw, mh = mon.getSize()
    local num_bars = math.floor(mw / 3)
    if num_bars < 4 then num_bars = 4 end
    local bar_w = math.floor(mw / num_bars)
    local max_h = mh - 2

    -- Initialize if needed
    if #viz_state.bar_heights ~= num_bars then
        viz_state.bar_heights = {}
        viz_state.bar_peaks = {}
        viz_state.bar_peak_hold = {}
        for i = 1, num_bars do
            viz_state.bar_heights[i] = 0
            viz_state.bar_peaks[i] = 0
            viz_state.bar_peak_hold[i] = 0
        end
    end

    -- Use actual per-band energy from audio_bands
    local beat_boost = beat_detected and 1.4 or 1.0
    for i = 1, num_bars do
        -- Map bars to audio_bands (audio_bands may have different count)
        local band_idx = math.floor((i - 1) / num_bars * #audio_bands) + 1
        band_idx = math.min(band_idx, #audio_bands)
        local energy = (audio_bands[band_idx] or 0) * max_h * 2.5 * beat_boost

        -- Instant attack, slow decay
        if energy > viz_state.bar_heights[i] then
            viz_state.bar_heights[i] = energy
        else
            viz_state.bar_heights[i] = viz_state.bar_heights[i] * 0.88
        end

        -- Peak hold indicator
        if viz_state.bar_heights[i] > viz_state.bar_peaks[i] then
            viz_state.bar_peaks[i] = viz_state.bar_heights[i]
            viz_state.bar_peak_hold[i] = 12  -- hold for N frames
        else
            viz_state.bar_peak_hold[i] = viz_state.bar_peak_hold[i] - 1
            if viz_state.bar_peak_hold[i] <= 0 then
                viz_state.bar_peaks[i] = viz_state.bar_peaks[i] * 0.92
            end
        end
    end

    -- Draw
    mon.setBackgroundColor(colors.black)
    mon.clear()

    for i = 1, num_bars do
        local bh = math.floor(viz_state.bar_heights[i] + 0.5)
        if bh < 0 then bh = 0 end
        if bh > max_h then bh = max_h end
        local bx = (i - 1) * bar_w + 1

        -- Main bar
        for row = 0, bh - 1 do
            local y = mh - 1 - row
            if y >= 1 then
                local pct = row / max_h
                local col
                if pct > 0.75 then col = bar_colors_top
                elseif pct > 0.4 then col = bar_colors_mid
                else col = bar_colors_bottom end

                mon.setBackgroundColor(col)
                for bxx = bx, math.min(bx + bar_w - 2, mw) do
                    mon.setCursorPos(bxx, y)
                    mon.write(" ")
                end
            end
        end

        -- Dim reflection (bottom 3 rows mirrored)
        for row = 0, math.min(2, bh - 1) do
            local y = mh - 1 + row + 1
            if y <= mh and y >= 1 then
                mon.setBackgroundColor(colors.gray)
                for bxx = bx, math.min(bx + bar_w - 2, mw) do
                    mon.setCursorPos(bxx, y)
                    mon.write(" ")
                end
            end
        end

        -- Peak hold dot
        local pk = math.floor(viz_state.bar_peaks[i] + 0.5)
        if pk > 0 and pk <= max_h then
            local py = mh - 1 - pk
            if py >= 1 then
                mon.setBackgroundColor(colors.white)
                for bxx = bx, math.min(bx + bar_w - 2, mw) do
                    mon.setCursorPos(bxx, py)
                    mon.write(" ")
                end
            end
        end
    end

    -- Beat flash
    if beat_detected then
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.white)
        mon.setCursorPos(mw - 1, 1)
        mon.write("\7")
    end

    -- Song info at bottom
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.gray)
    if now_playing then
        mon.setCursorPos(2, mh)
        mon.write(truncStr(now_playing.name, mw - 2))
    end
end

---------------------------------------------------------------------------
-- Visualizer 2: Waveform (triggered oscilloscope)
---------------------------------------------------------------------------
local function drawWaveform(mon)
    local mw, mh = mon.getSize()
    local center_y = math.floor(mh / 2)
    local amplitude = math.floor(mh / 2) - 1

    -- Build display buffer using trigger-synced oscilloscope approach
    local wave = {}
    if buffer and #buffer > 0 then
        -- Find a positive zero-crossing to sync/stabilize the display
        local trigger = 1
        for i = 2, math.min(#buffer, 2000) do
            if buffer[i - 1] <= 0 and buffer[i] > 0 then
                trigger = i
                break
            end
        end

        -- Zoom: show ~4 samples per pixel for visible wave detail
        local spp = math.max(2, math.floor(#buffer / mw / 3))
        for x = 1, mw do
            local idx = trigger + (x - 1) * spp
            if idx >= 1 and idx <= #buffer then
                wave[x] = buffer[idx] / 128
            else
                wave[x] = 0
            end
        end
        viz_state.wave_buf = wave
    else
        wave = viz_state.wave_buf or {}
    end

    mon.setBackgroundColor(colors.black)
    mon.clear()

    -- Beat flash background
    if beat_detected then
        for x = 1, mw do
            mon.setCursorPos(x, center_y)
            mon.setBackgroundColor(colors.gray)
            mon.write(" ")
        end
        mon.setBackgroundColor(colors.black)
    else
        -- Draw center line
        mon.setTextColor(colors.gray)
        for x = 1, mw do
            mon.setCursorPos(x, center_y)
            mon.write("\140")
        end
    end

    -- Draw waveform with glow
    if #wave > 0 then
        for x = 1, math.min(mw, #wave) do
            local sample = wave[x] or 0
            local h = math.floor(sample * amplitude + 0.5)
            local target_y = center_y - h

            -- Intensity based on displacement
            local intensity = math.abs(h) / amplitude
            local col
            if intensity > 0.8 then col = colors.red
            elseif intensity > 0.5 then col = colors.yellow
            else col = colors.cyan end

            -- Draw filled bar from center to point
            if h > 0 then
                for dy = center_y - 1, math.max(1, target_y), -1 do
                    mon.setCursorPos(x, dy)
                    mon.setBackgroundColor(dy == target_y and col or colors.blue)
                    mon.write(" ")
                end
            elseif h < 0 then
                for dy = center_y + 1, math.min(mh, target_y) do
                    mon.setCursorPos(x, dy)
                    mon.setBackgroundColor(dy == target_y and col or colors.blue)
                    mon.write(" ")
                end
            end

            -- Bright tip
            if target_y >= 1 and target_y <= mh then
                mon.setCursorPos(x, target_y)
                mon.setBackgroundColor(col)
                mon.write(" ")
            end
        end
    end

    -- VU meter bar at top
    local vu_w = math.floor(audio_level * mw)
    if vu_w > 0 then
        for x = 1, math.min(vu_w, mw) do
            mon.setCursorPos(x, 1)
            local pct = x / mw
            if pct > 0.8 then mon.setBackgroundColor(colors.red)
            elseif pct > 0.5 then mon.setBackgroundColor(colors.yellow)
            else mon.setBackgroundColor(colors.green) end
            mon.write(" ")
        end
    end

    -- Song info
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    if now_playing then
        mon.setCursorPos(2, mh)
        mon.write(truncStr(now_playing.name, mw - 2))
    end
end

---------------------------------------------------------------------------
-- Visualizer 3: Campfire
---------------------------------------------------------------------------
local function initFire(fw, fh)
    viz_state.fire = {}
    viz_state.fire_w = fw
    viz_state.fire_h = fh
    for y = 1, fh do
        viz_state.fire[y] = {}
        for x = 1, fw do
            viz_state.fire[y][x] = 0
        end
    end
end

local function updateFire(fw, fh, intensity)
    local grid = viz_state.fire
    -- Seed bottom row with heat based on audio intensity
    local heat_base = math.floor(intensity * 5) + 1
    for x = 1, fw do
        grid[fh][x] = math.min(6, math.max(0, heat_base + math.random(-2, 2)))
    end
    -- Extra hot center
    local cx = math.floor(fw / 2)
    for x = math.max(1, cx - 3), math.min(fw, cx + 3) do
        grid[fh][x] = math.min(6, grid[fh][x] + 1)
    end

    -- Propagate upward
    for y = 1, fh - 1 do
        for x = 1, fw do
            local below = grid[y + 1][x] or 0
            local bl = grid[y + 1][math.max(1, x - 1)] or 0
            local br = grid[y + 1][math.min(fw, x + 1)] or 0
            local below2 = (y + 2 <= fh) and (grid[y + 2][x] or 0) or below
            local avg = (below + bl + br + below2) / 4
            grid[y][x] = math.max(0, avg - 0.2 - math.random() * 0.3)
        end
    end
end

local function drawCampfire(mon)
    local mw, mh = mon.getSize()

    -- Fire zone: center 60% width, bottom 55% height
    local fw = math.max(6, math.floor(mw * 0.6))
    local fh = math.max(4, math.floor(mh * 0.55))
    local fx = math.floor((mw - fw) / 2) + 1
    local fy = mh - fh - 1  -- leave room for logs + ground

    -- Init fire grid if needed
    if not viz_state.fire or viz_state.fire_w ~= fw or viz_state.fire_h ~= fh then
        initFire(fw, fh)
    end

    -- Intensity: base idle fire + audio boost
    local intensity = 0.3 + audio_level * 0.7

    updateFire(fw, fh, intensity)

    -- Clear screen to black (night sky)
    mon.setBackgroundColor(colors.black)
    mon.clear()

    -- Draw stars (initialize once, twinkle randomly)
    if #viz_state.stars == 0 then
        for i = 1, math.floor(mw * mh * 0.02) do
            table.insert(viz_state.stars, {
                x = math.random(1, mw),
                y = math.random(1, math.max(1, fy - 2))
            })
        end
    end
    for _, star in ipairs(viz_state.stars) do
        if math.random() > 0.3 then
            mon.setCursorPos(star.x, star.y)
            mon.setBackgroundColor(colors.black)
            mon.setTextColor(math.random() > 0.7 and colors.lightGray or colors.white)
            mon.write(math.random() > 0.5 and "." or "*")
        end
    end

    -- Draw fire
    for y = 1, fh do
        for x = 1, fw do
            local heat = viz_state.fire[y][x]
            if heat > 0.3 then
                mon.setCursorPos(fx + x - 1, fy + y - 1)
                mon.setBackgroundColor(heatToColor(heat))
                mon.write(" ")
            end
        end
    end

    -- Draw sparks
    if math.random() < intensity * 0.4 then
        table.insert(viz_state.sparks, {
            x = fx + math.floor(fw / 2) + math.random(-3, 3),
            y = fy - 1,
            life = math.random(3, 8),
            dx = math.random(-1, 1) * 0.3
        })
    end
    local new_sparks = {}
    for _, sp in ipairs(viz_state.sparks) do
        sp.y = sp.y - 1
        sp.x = sp.x + sp.dx
        sp.life = sp.life - 1
        if sp.life > 0 and sp.y >= 1 and sp.x >= 1 and sp.x <= mw then
            local sx, sy = math.floor(sp.x + 0.5), math.floor(sp.y + 0.5)
            mon.setCursorPos(sx, sy)
            mon.setBackgroundColor(colors.black)
            mon.setTextColor(sp.life > 3 and colors.yellow or colors.orange)
            mon.write("\7")
            table.insert(new_sparks, sp)
        end
    end
    viz_state.sparks = new_sparks

    -- Draw logs at the bottom
    local log_y = mh - 1
    local log_cx = math.floor(mw / 2)
    mon.setBackgroundColor(colors.brown)
    -- Crossed logs
    for dx = -4, 4 do
        local lx = log_cx + dx
        if lx >= 1 and lx <= mw then
            mon.setCursorPos(lx, log_y)
            mon.write(" ")
        end
    end
    -- Second log angled
    for dx = -3, 3 do
        local lx = log_cx + dx + 1
        if lx >= 1 and lx <= mw and log_y - 1 >= 1 then
            if math.abs(dx) > 1 then
                mon.setCursorPos(lx, log_y)
                mon.setBackgroundColor(colors.brown)
                mon.write(" ")
            end
        end
    end

    -- Draw ground
    mon.setBackgroundColor(colors.brown)
    for x = 1, mw do
        mon.setCursorPos(x, mh)
        mon.setBackgroundColor(x % 3 == 0 and colors.green or colors.brown)
        mon.write(" ")
    end

    -- Song info in the sky
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.lightGray)
    if now_playing then
        mon.setCursorPos(2, 1)
        mon.write(truncStr(now_playing.name, mw - 2))
    end
end

---------------------------------------------------------------------------
-- Visualizer 4: Matrix Rain
---------------------------------------------------------------------------
local function drawMatrixRain(mon)
    local mw, mh = mon.getSize()

    -- Initialize drops
    if #viz_state.rain_drops == 0 or #viz_state.rain_drops ~= mw then
        viz_state.rain_drops = {}
        viz_state.rain_chars = {}
        for x = 1, mw do
            viz_state.rain_drops[x] = math.random(1, mh)
            viz_state.rain_chars[x] = {}
            for y = 1, mh do
                local ci = math.random(1, #rain_chars)
                viz_state.rain_chars[x][y] = rain_chars:sub(ci, ci)
            end
        end
    end

    -- Speed and density react to audio + beats
    local speed = 1 + math.floor(audio_level * 3)
    local density = 0.3 + audio_level * 0.6
    if beat_detected then speed = speed + 2; density = 1.0 end

    mon.setBackgroundColor(colors.black)
    mon.clear()

    for x = 1, mw do
        -- Advance drop
        if math.random() < density then
            viz_state.rain_drops[x] = viz_state.rain_drops[x] + speed
            if viz_state.rain_drops[x] > mh + 10 then
                viz_state.rain_drops[x] = math.random(-5, 0)
            end
        end

        -- Randomly change a character
        if math.random() < 0.1 then
            local ry = math.random(1, mh)
            local ci = math.random(1, #rain_chars)
            viz_state.rain_chars[x][ry] = rain_chars:sub(ci, ci)
        end

        local head = viz_state.rain_drops[x]
        local tail_len = math.floor(mh * 0.6)

        for y = 1, mh do
            local dist = head - y
            if dist >= 0 and dist < tail_len then
                mon.setCursorPos(x, y)
                if dist == 0 then
                    -- Head: bright white
                    mon.setTextColor(colors.white)
                elseif dist < 3 then
                    mon.setTextColor(colors.lime)
                elseif dist < tail_len * 0.5 then
                    mon.setTextColor(colors.green)
                else
                    mon.setTextColor(colors.green)
                end
                mon.write(viz_state.rain_chars[x][y] or " ")
            end
        end
    end

    -- Song info overlay
    if now_playing then
        mon.setCursorPos(2, mh)
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.white)
        mon.write(truncStr(now_playing.name, mw - 2))
    end
end

---------------------------------------------------------------------------
-- Visualizer 5: Aurora Borealis
---------------------------------------------------------------------------
-- blit color hex: 0=white 1=orange 2=magenta 3=lightBlue 4=yellow
--   5=lime 6=pink 7=gray 8=lightGray 9=cyan a=purple b=blue
--   c=brown d=green e=red f=black

-- Multiple palettes that we blend between based on audio character
local aurora_palettes = {
    -- Cool:   black  blue   purple cyan   lime   white
    { "f", "b", "a", "3", "9", "5", "0" },
    -- Warm:   black  red    orange yellow lime   white
    { "f", "e", "1", "4", "5", "8", "0" },
    -- Neon:   black  purple magenta pink  orange yellow white
    { "f", "a", "2", "6", "1", "4", "0" },
    -- Ocean:  black  blue   cyan   lightBlue lime green white
    { "f", "b", "9", "3", "5", "d", "0" },
    -- Fire:   black  brown  red    orange yellow white
    { "f", "c", "e", "1", "4", "0", "0" },
}

-- Smoothed palette blend value for gradual shifts
local aurora_blend = 0
local aurora_blend_target = 0

local function drawAurora(mon)
    local mw, mh = mon.getSize()
    local t = os.clock()

    -- Audio drives intensity and wave speed
    local intensity = 0.35 + audio_level * 3.0
    local wave_speed = 1.0 + audio_level * 2.5
    if beat_detected then intensity = intensity + 1.5 end

    -- Split audio into low/mid/high bands
    local low_e, mid_e, high_e = 0, 0, 0
    local third = math.max(1, math.floor(#audio_bands / 3))
    for i = 1, third do
        low_e = low_e + (audio_bands[i] or 0)
    end
    for i = third + 1, third * 2 do
        mid_e = mid_e + (audio_bands[i] or 0)
    end
    for i = third * 2 + 1, #audio_bands do
        high_e = high_e + (audio_bands[i] or 0)
    end
    low_e = low_e / third
    mid_e = mid_e / third
    high_e = high_e / math.max(1, #audio_bands - third * 2)

    -- Pick palette based on audio character (shifts over time + audio)
    -- Low-heavy = warm/fire, high-heavy = cool/neon, balanced = ocean
    local palette_val = (low_e - high_e) * 8 + math.sin(t * 0.3) * 1.5
    if beat_detected then palette_val = palette_val + math.sin(t * 3) * 2 end
    aurora_blend_target = palette_val
    aurora_blend = aurora_blend + (aurora_blend_target - aurora_blend) * 0.08

    -- Map blend value to a palette index (1-5) with fractional blending
    local pi_raw = (aurora_blend + 3) * 0.6 + 1  -- roughly map range to 1..5
    if pi_raw < 1 then pi_raw = 1 elseif pi_raw > #aurora_palettes then pi_raw = #aurora_palettes end
    local pi1 = math.floor(pi_raw)
    local pi2 = math.min(pi1 + 1, #aurora_palettes)
    local frac = pi_raw - pi1
    local pal1 = aurora_palettes[pi1]
    local pal2 = aurora_palettes[pi2]

    -- Build current frame palette by choosing from pal1/pal2 based on frac
    local pal = {}
    for i = 1, math.min(#pal1, #pal2) do
        if math.random() < frac then
            pal[i] = pal2[i]
        else
            pal[i] = pal1[i]
        end
    end
    local pal_len = #pal

    -- Precompute x-waves (vertical curtains) - 3 layers
    local sx = {}
    for x = 1, mw do
        sx[x] = math.sin(x * 0.08 + t * wave_speed * 0.7)
               + math.sin(x * 0.19 + t * wave_speed * 1.5) * (0.4 + high_e * 5)
               + math.sin(x * 0.04 - t * wave_speed * 0.3) * (0.3 + low_e * 3)
    end

    -- Precompute diagonal wave (reacts to mid frequencies)
    local diag = {}
    for d = 2, mw + mh do
        diag[d] = math.sin(d * 0.055 + t * wave_speed * 0.4) * (0.5 + mid_e * 5)
    end

    -- Color offset that shifts the whole palette cyclically with time + audio
    local color_shift = math.sin(t * 0.5) * 1.2 + low_e * 2

    -- Reusable strings for blit
    local spaces = string.rep(" ", mw)
    local fg_str = string.rep("f", mw)

    for y = 1, mh do
        local sy = math.sin(y * 0.13 + t * wave_speed * 1.1)
                 + math.sin(y * 0.31 + t * wave_speed * 0.6) * 0.6
                 + math.sin(y * 0.07 - t * 0.8) * (0.3 + mid_e * 2)
        local bg = ""
        for x = 1, mw do
            local v = (sx[x] + sy + diag[x + y]) * intensity * 0.18 + color_shift
            -- Wider mapping for more color spread
            local idx = math.floor((v + 2.0) * 1.6) + 1
            -- Wrap around for more variety instead of clamping
            idx = ((idx - 1) % pal_len) + 1
            bg = bg .. pal[idx]
        end
        mon.setCursorPos(1, y)
        mon.blit(spaces, fg_str, bg)
    end

    -- Song info overlay
    if now_playing then
        mon.setCursorPos(2, mh)
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.white)
        mon.write(truncStr(now_playing.name, mw - 2))
    end
end

---------------------------------------------------------------------------
-- Visualizer Loop
---------------------------------------------------------------------------
function visualizerLoop()
    while true do
        monitor = findMonitor()
        if monitor and viz_mode > 0 then
            monitor.setTextScale(0.5)
            local ok, err = pcall(function()
                if viz_mode == 1 then drawSpectrumBars(monitor)
                elseif viz_mode == 2 then drawWaveform(monitor)
                elseif viz_mode == 3 then drawCampfire(monitor)
                elseif viz_mode == 4 then drawMatrixRain(monitor)
                elseif viz_mode == 5 then drawAurora(monitor)
                end
            end)
            if not ok then
                -- Monitor may have been disconnected
                monitor = nil
            end
        elseif monitor and viz_mode == 0 then
            -- Idle: show song info on monitor
            pcall(function()
                monitor.setTextScale(1)
                local mw, mh = monitor.getSize()
                monitor.setBackgroundColor(colors.black)
                monitor.clear()
                monitor.setTextColor(colors.cyan)
                monitor.setCursorPos(math.floor(mw / 2) - 5, math.floor(mh / 2) - 1)
                monitor.write("MC-CC-Music")
                if now_playing then
                    monitor.setTextColor(colors.white)
                    monitor.setCursorPos(2, math.floor(mh / 2) + 1)
                    monitor.write(truncStr(now_playing.name, mw - 2))
                    monitor.setTextColor(colors.lightGray)
                    monitor.setCursorPos(2, math.floor(mh / 2) + 2)
                    monitor.write(truncStr(now_playing.artist or "", mw - 2))
                else
                    monitor.setTextColor(colors.gray)
                    monitor.setCursorPos(math.floor(mw / 2) - 5, math.floor(mh / 2) + 1)
                    monitor.write("Not playing")
                end
            end)
        end

        -- Decay audio level between chunks (gentle so bars don't vanish)
        audio_level = audio_level * 0.93
        audio_peak = audio_peak * 0.96
        -- Decay bands individually
        for i = 1, #audio_bands do
            audio_bands[i] = (audio_bands[i] or 0) * 0.90
        end
        beat_detected = false

        sleep(0.05)  -- ~20 FPS
    end
end

---------------------------------------------------------------------------
-- Audio Loop
---------------------------------------------------------------------------
function audioLoop()
    while true do
        if playing and now_playing then
            local thisnowplayingid = now_playing.id
            if playing_id ~= thisnowplayingid then
                playing_id = thisnowplayingid
                last_download_url = api_base_url .. "?v=" .. version .. "&id=" .. textutils.urlEncode(playing_id)
                playing_status = 0
                needs_next_chunk = 1
                decoder = require("cc.audio.dfpwm").make_decoder()
                http.request({ url = last_download_url, binary = true })
                is_loading = true
                os.queueEvent("redraw_screen")
                os.queueEvent("audio_update")
            elseif playing_status == 1 and needs_next_chunk == 1 then
                while true do
                    local chunk = player_handle.read(size)
                    if not chunk then
                        if looping == 2 or (looping == 1 and #queue == 0) then
                            playing_id = nil
                        elseif looping == 1 and #queue > 0 then
                            table.insert(queue, now_playing)
                            now_playing = queue[1]
                            table.remove(queue, 1)
                            playing_id = nil
                        else
                            if #queue > 0 then
                                now_playing = queue[1]
                                table.remove(queue, 1)
                                playing_id = nil
                            else
                                now_playing, playing, playing_id = nil, false, nil
                                is_loading, is_error = false, false
                            end
                        end
                        os.queueEvent("redraw_screen")
                        player_handle.close()
                        needs_next_chunk = 0
                        break
                    else
                        if start then
                            chunk, start = start .. chunk, nil
                            size = size + 4
                        end

                        buffer = decoder(chunk)

                        -- Extract per-band energy for visualizer
                        local num_bands = 16
                        local band_size = math.floor(#buffer / num_bands)
                        local bands = {}
                        local overall = 0
                        for b = 1, num_bands do
                            local sum = 0
                            local si = (b - 1) * band_size + 1
                            local ei = math.min(b * band_size, #buffer)
                            for idx = si, ei, 4 do
                                local s = buffer[idx] or 0
                                sum = sum + s * s
                            end
                            local rms = math.sqrt(sum / ((ei - si) / 4 + 1)) / 128
                            bands[b] = rms
                            overall = overall + rms
                        end
                        audio_bands = bands
                        audio_level = overall / num_bands

                        -- Peak tracking
                        if audio_level > audio_peak then audio_peak = audio_level end

                        -- Beat detection: compare to rolling average
                        table.insert(audio_history, 1, audio_level)
                        if #audio_history > 30 then table.remove(audio_history) end
                        local avg = 0
                        for _, h in ipairs(audio_history) do avg = avg + h end
                        avg = avg / #audio_history
                        beat_detected = audio_level > avg * 1.5 and audio_level > 0.12

                        -- Re-scan speakers periodically (picks up network changes)
                        speakers = findAllSpeakers()

                        local fn = {}
                        for si, speaker in ipairs(speakers) do
                            fn[si] = function()
                                local name = peripheral.getName(speaker)
                                if #speakers > 1 then
                                    if speaker.playAudio(buffer, volume) then
                                        parallel.waitForAny(
                                            function()
                                                repeat until select(2, os.pullEvent("speaker_audio_empty")) == name
                                            end,
                                            function() os.pullEvent("playback_stopped") end
                                        )
                                        if not playing or playing_id ~= thisnowplayingid then return end
                                    end
                                else
                                    while not speaker.playAudio(buffer, volume) do
                                        parallel.waitForAny(
                                            function()
                                                repeat until select(2, os.pullEvent("speaker_audio_empty")) == name
                                            end,
                                            function() os.pullEvent("playback_stopped") end
                                        )
                                        if not playing or playing_id ~= thisnowplayingid then return end
                                    end
                                end
                                if not playing or playing_id ~= thisnowplayingid then return end
                            end
                        end

                        local ok, err = pcall(parallel.waitForAll, table.unpack(fn))
                        if not ok then
                            needs_next_chunk = 2
                            is_error = true
                            break
                        end
                        if not playing or playing_id ~= thisnowplayingid then break end
                    end
                end
                os.queueEvent("audio_update")
            end
        end
        os.pullEvent("audio_update")
    end
end

---------------------------------------------------------------------------
-- HTTP Loop
---------------------------------------------------------------------------
function httpLoop()
    while true do
        parallel.waitForAny(
            function()
                local _, url, handle = os.pullEvent("http_success")
                if url == last_search_url then
                    local body = handle.readAll(); handle.close()
                    if is_piped_search then
                        local data = textutils.unserialiseJSON(body)
                        if data and data.items then
                            search_results = {}
                            for _, item in ipairs(data.items) do
                                local pid = item.url and item.url:match("list=([%w_%-]+)")
                                if pid then
                                    table.insert(search_results, {
                                        id = pid,
                                        name = cleanStr(item.name or "Unknown Playlist"),
                                        artist = "Playlist  " .. (item.videos or "?") .. " videos  " .. cleanStr(item.uploaderName or ""),
                                        type = "playlist_search"
                                    })
                                end
                            end
                        else search_results = {} end
                    else
                        search_results = textutils.unserialiseJSON(body)
                        if not search_results then search_results = {} end
                    end
                    os.queueEvent("redraw_screen")
                end
                if url == playlist_detail_url then
                    local body = handle.readAll(); handle.close()
                    playlist_loading = false
                    local data = textutils.unserialiseJSON(body)
                    if data and #data > 0 then clicked_result_data = data[1]
                    else clicked_result_data = search_results[clicked_result] end
                    os.queueEvent("redraw_screen")
                end
                if url == last_download_url then
                    is_loading = false
                    player_handle = handle
                    start = handle.read(4)
                    size = 16 * 1024 - 4
                    playing_status = 1
                    os.queueEvent("redraw_screen")
                    os.queueEvent("audio_update")
                end
            end,
            function()
                local _, url = os.pullEvent("http_failure")
                if url == last_search_url then
                    search_error, search_results = true, nil
                    os.queueEvent("redraw_screen")
                end
                if url == playlist_detail_url then
                    playlist_loading = false
                    clicked_result_data = search_results[clicked_result]
                    os.queueEvent("redraw_screen")
                end
                if url == last_download_url then
                    is_loading, is_error, playing, playing_id = false, true, false, nil
                    os.queueEvent("redraw_screen")
                    os.queueEvent("audio_update")
                end
            end
        )
    end
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
parallel.waitForAny(uiLoop, audioLoop, httpLoop, visualizerLoop)
