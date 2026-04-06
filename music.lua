-- MC-CC-Music: ComputerCraft YouTube Music Player with Playlist Support
-- Enhanced UI with Shuffle, Save/Load Playlists, Library tab
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
local search_mode = 1 -- 1=Songs, 2=Playlists
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
local clicked_library_data = nil

-- Save name input
local waiting_for_save_name = false

-- Toast message
local toast_msg = nil
local toast_timer = nil

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

-- Find speakers
local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
    error("No speakers attached. Connect a speaker to this computer.", 0)
end

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
    if not fs.exists(SAVE_DIR) then
        fs.makeDir(SAVE_DIR)
    end
    -- Sanitize filename
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
            local count = 0
            if data then count = #data end
            table.insert(saved_playlists, { name = name, count = count })
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

local function drawSeparator(y, col)
    term.setBackgroundColor(col or colors.gray)
    for x = 1, width do
        term.setCursorPos(x, y)
        term.write("\140")
    end
    term.setBackgroundColor(colors.black)
end

---------------------------------------------------------------------------
-- Drawing: Tabs
---------------------------------------------------------------------------
function redrawScreen()
    if waiting_for_input or waiting_for_save_name then return end
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.clear()

    -- Tab bar
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

    if tab == 1 then
        drawNowPlaying()
    elseif tab == 2 then
        drawSearch()
    elseif tab == 3 then
        drawLibrary()
    end

    -- Toast message
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

    -- Now playing info
    if now_playing ~= nil then
        term.setTextColor(colors.cyan)
        term.setCursorPos(2, 3)
        term.write("\16 ")  -- play triangle
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
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2, 5)
        term.write("Loading...")
    elseif is_error then
        term.setTextColor(colors.red)
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2, 5)
        term.write("Network error")
    end

    -- Controls row 1: transport
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
    term.setCursorPos(2, 7)
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

    -- Queue header + Save/Clear buttons (row 8)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2, 8)
    if #queue > 0 then
        term.write("Queue (" .. #queue .. ")")
    else
        term.write("Queue")
    end

    -- Save & Clear buttons on right side of row 8
    local save_label = " Save "
    local clear_label = " Clear "
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

            -- Track number
            term.setTextColor(colors.gray)
            term.setCursorPos(2, 9 + (i - 1) * 2)
            local num = tostring(idx) .. "."
            term.write(num)

            -- Track name
            term.setTextColor(colors.white)
            term.setCursorPos(2 + #num + 1, 9 + (i - 1) * 2)
            term.write(truncStr(queue[idx].name, width - 3 - #num))

            -- Artist
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2 + #num + 1, 10 + (i - 1) * 2)
            term.write(truncStr(queue[idx].artist, width - 3 - #num))
        end

        -- Scroll indicators
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
    -- Search bar
    paintutils.drawFilledBox(2, 3, width - 1, 3, colors.lightGray)
    term.setBackgroundColor(colors.lightGray)
    term.setCursorPos(3, 3)
    term.setTextColor(colors.black)
    term.write(truncStr(last_search or "Search...", width - 4))

    -- Mode toggle (row 5)
    local bx = 2
    if search_mode == 1 then
        bx = bx + drawBtn(bx, 5, " Songs ", true) + 1
        drawBtn(bx, 5, " Playlists ", false)
    else
        bx = bx + drawBtn(bx, 5, " Songs ", false) + 1
        drawBtn(bx, 5, " Playlists ", true)
    end

    -- Results
    local results_start_y = 7
    if search_results ~= nil and #search_results > 0 then
        term.setBackgroundColor(colors.black)
        local max_visible = math.floor((height - results_start_y) / 2)
        if max_visible < 1 then max_visible = 1 end

        if search_scroll > math.max(0, #search_results - max_visible) then
            search_scroll = math.max(0, #search_results - max_visible)
        end

        for i = 1, max_visible do
            local idx = i + search_scroll
            if idx > #search_results then break end
            local r = search_results[idx]
            term.setCursorPos(2, results_start_y + (i - 1) * 2)
            if r.type == "playlist" or r.type == "playlist_search" then
                term.setTextColor(colors.cyan)
                term.write(truncStr("[PL] " .. (r.name or ""), width - 2))
            else
                term.setTextColor(colors.white)
                term.write(truncStr(r.name or "", width - 2))
            end
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2, results_start_y + 1 + (i - 1) * 2)
            term.write(truncStr(r.artist or "", width - 2))
        end

        if search_scroll > 0 then
            term.setTextColor(colors.cyan)
            term.setCursorPos(width, results_start_y)
            term.write("\24")
        end
        if search_scroll + max_visible < #search_results then
            term.setTextColor(colors.cyan)
            term.setCursorPos(width, height)
            term.write("\25")
        end
    elseif search_results ~= nil and #search_results == 0 then
        term.setCursorPos(2, results_start_y)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        term.write("No results found")
    else
        term.setCursorPos(2, results_start_y)
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
            term.setCursorPos(2, results_start_y + 1)
            term.write("YouTube video/playlist URL.")
            term.setCursorPos(2, results_start_y + 3)
            term.setTextColor(colors.gray)
            term.write("Switch to Playlists mode to")
            term.setCursorPos(2, results_start_y + 4)
            term.write("search for playlists by name.")
        end
    end

    -- Fullscreen result options
    if in_search_result then
        drawResultMenu()
    end
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
    if not data then
        in_search_result = false
        return
    end

    -- Header
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

    -- Buttons
    local row = 6
    if is_pl then
        drawBtn(2, row, " Play all now              ", false); row = row + 2
        drawBtn(2, row, " Play all next             ", false); row = row + 2
        drawBtn(2, row, " Add all to queue          ", false); row = row + 2
    else
        drawBtn(2, row, " Play now                  ", false); row = row + 2
        drawBtn(2, row, " Play next                 ", false); row = row + 2
        drawBtn(2, row, " Add to queue              ", false); row = row + 2
    end

    row = row + 1
    drawBtn(2, row, " Cancel                    ", false)
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

    local list_start_y = 5
    local max_visible = height - list_start_y
    if max_visible < 1 then max_visible = 1 end

    if library_scroll > math.max(0, #saved_playlists - max_visible) then
        library_scroll = math.max(0, #saved_playlists - max_visible)
    end

    for i = 1, max_visible do
        local idx = i + library_scroll
        if idx > #saved_playlists then break end
        local pl = saved_playlists[idx]
        local y = list_start_y + (i - 1)

        term.setCursorPos(2, y)
        term.setTextColor(colors.cyan)
        term.write("\16 ")
        term.setTextColor(colors.white)
        term.write(truncStr(pl.name, width - 16))
        term.setTextColor(colors.gray)
        term.write(" (" .. pl.count .. ")")
    end

    if library_scroll > 0 then
        term.setTextColor(colors.cyan)
        term.setCursorPos(width, list_start_y)
        term.write("\24")
    end
    if library_scroll + max_visible < #saved_playlists then
        term.setTextColor(colors.cyan)
        term.setCursorPos(width, height)
        term.write("\25")
    end

    -- Library item menu
    if in_library_menu then
        drawLibraryMenu()
    end
end

function drawLibraryMenu()
    term.setBackgroundColor(colors.black)
    term.clear()

    local pl = saved_playlists[clicked_library_idx]
    if not pl then
        in_library_menu = false
        return
    end

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
-- Perform search
---------------------------------------------------------------------------
local function doSearch(input)
    if string.len(input) == 0 then
        last_search = nil
        last_search_url = nil
        search_results = nil
        search_error = false
        is_piped_search = false
        return
    end

    last_search = input
    search_results = nil
    search_error = false
    search_scroll = 0

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

---------------------------------------------------------------------------
-- Action helpers
---------------------------------------------------------------------------
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
    playing = true
    is_error = false
    playing_id = nil

    if data.type == "playlist" and data.playlist_items and #data.playlist_items > 0 then
        now_playing = data.playlist_items[1]
        queue = {}
        for i = 2, #data.playlist_items do
            table.insert(queue, data.playlist_items[i])
        end
    else
        now_playing = data
    end
    queue_scroll = 0
    os.queueEvent("audio_update")
end

local function actionPlayNext(data)
    if data.type == "playlist" and data.playlist_items then
        for i = #data.playlist_items, 1, -1 do
            table.insert(queue, 1, data.playlist_items[i])
        end
    else
        table.insert(queue, 1, data)
    end
    os.queueEvent("audio_update")
end

local function actionAddToQueue(data)
    if data.type == "playlist" and data.playlist_items then
        for i = 1, #data.playlist_items do
            table.insert(queue, data.playlist_items[i])
        end
    else
        table.insert(queue, data)
    end
    os.queueEvent("audio_update")
end

local function actionPlaySavedPlaylist(tracks)
    for _, speaker in ipairs(speakers) do
        speaker.stop()
        os.queueEvent("playback_stopped")
    end
    playing = true
    is_error = false
    playing_id = nil
    now_playing = tracks[1]
    queue = {}
    for i = 2, #tracks do
        table.insert(queue, tracks[i])
    end
    queue_scroll = 0
    os.queueEvent("audio_update")
end

local function actionQueueSavedPlaylist(tracks)
    for _, t in ipairs(tracks) do
        table.insert(queue, t)
    end
    os.queueEvent("audio_update")
end

local function getCurrentTracklist()
    local tracks = {}
    if now_playing then
        table.insert(tracks, { id = now_playing.id, name = now_playing.name, artist = now_playing.artist })
    end
    for _, t in ipairs(queue) do
        table.insert(tracks, { id = t.id, name = t.name, artist = t.artist })
    end
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
            -- Save playlist name input
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
                    local saved_name = savePlaylist(input, tracks)
                    refreshSavedPlaylists()
                    showToast("Saved: " .. saved_name)
                else
                    showToast("Nothing to save")
                end
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
                        local event, button, x, y = os.pullEvent("mouse_click")
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
                function()
                    local event, button, x, y = os.pullEvent("mouse_click")
                    handleClick(button, x, y)
                end,
                function()
                    local event, button, x, y = os.pullEvent("mouse_drag")
                    if button == 1 and tab == 1 and not in_search_result then
                        if y >= 6 and y <= 8 and x >= 1 and x < 2 + 24 then
                            volume = (x - 1) / 24 * 3
                            redrawScreen()
                        end
                    end
                end,
                function()
                    local event, direction, x, y = os.pullEvent("mouse_scroll")
                    handleScroll(direction)
                end,
                function()
                    os.pullEvent("redraw_screen")
                    redrawScreen()
                end,
                function()
                    while true do
                        local event, id = os.pullEvent("timer")
                        if id == toast_timer then
                            toast_msg = nil
                            toast_timer = nil
                            os.queueEvent("redraw_screen")
                            break
                        end
                    end
                end
            )
        end
    end
end

function handleScroll(direction)
    if tab == 1 and not in_search_result then
        local max_visible = math.floor((height - 9) / 2)
        if max_visible < 1 then max_visible = 1 end
        if direction == 1 then
            queue_scroll = math.min(queue_scroll + 1, math.max(0, #queue - max_visible))
        else
            queue_scroll = math.max(0, queue_scroll - 1)
        end
        redrawScreen()
    elseif tab == 2 and not in_search_result then
        if search_results then
            local max_visible = math.floor((height - 7) / 2)
            if max_visible < 1 then max_visible = 1 end
            if direction == 1 then
                search_scroll = math.min(search_scroll + 1, math.max(0, #search_results - max_visible))
            else
                search_scroll = math.max(0, search_scroll - 1)
            end
            redrawScreen()
        end
    elseif tab == 3 and not in_library_menu then
        local max_visible = height - 5
        if max_visible < 1 then max_visible = 1 end
        if direction == 1 then
            library_scroll = math.min(library_scroll + 1, math.max(0, #saved_playlists - max_visible))
        else
            library_scroll = math.max(0, library_scroll - 1)
        end
        redrawScreen()
    end
end

function handleClick(button, x, y)
    -- Tab switching
    if y == 1 and not in_search_result and not in_library_menu then
        local tab_count = 3
        local new_tab = math.ceil(x / (width / tab_count))
        if new_tab >= 1 and new_tab <= tab_count then
            tab = new_tab
            if tab == 3 then refreshSavedPlaylists() end
        end
        redrawScreen()
        return
    end

    if tab == 1 then
        handleNowPlayingClick(button, x, y)
    elseif tab == 2 and not in_search_result then
        handleSearchTabClick(button, x, y)
    elseif tab == 2 and in_search_result then
        handleResultMenuClick(button, x, y)
    elseif tab == 3 and not in_library_menu then
        handleLibraryClick(button, x, y)
    elseif tab == 3 and in_library_menu then
        handleLibraryMenuClick(button, x, y)
    end
end

---------------------------------------------------------------------------
-- Click handlers
---------------------------------------------------------------------------
function handleSearchTabClick(button, x, y)
    if y == 3 and x >= 2 and x <= width - 1 then
        paintutils.drawFilledBox(2, 3, width - 1, 3, colors.white)
        term.setBackgroundColor(colors.white)
        waiting_for_input = true
        return
    end

    -- Mode toggle (row 5)
    if y == 5 then
        if x >= 2 and x < 2 + 7 then
            if search_mode ~= 1 then
                search_mode = 1
                search_results = nil
                search_error = false
                search_scroll = 0
                last_search_url = nil
                if last_search then doSearch(last_search) end
            end
            redrawScreen()
            return
        elseif x >= 10 and x < 10 + 11 then
            if search_mode ~= 2 then
                search_mode = 2
                search_results = nil
                search_error = false
                search_scroll = 0
                last_search_url = nil
                if last_search then doSearch(last_search) end
            end
            redrawScreen()
            return
        end
    end

    -- Search result click
    if search_results and button == 1 then
        local results_start_y = 7
        local max_visible = math.floor((height - results_start_y) / 2)
        if max_visible < 1 then max_visible = 1 end

        for i = 1, max_visible do
            local idx = i + search_scroll
            if idx > #search_results then break end
            local ry = results_start_y + (i - 1) * 2
            if y == ry or y == ry + 1 then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
                term.setCursorPos(2, ry)
                term.clearLine()
                term.write(truncStr(search_results[idx].name or "", width - 2))
                sleep(0.15)

                clicked_result = idx
                clicked_result_data = nil
                playlist_loading = false

                if search_results[idx].type == "playlist_search" then
                    in_search_result = true
                    playlist_loading = true
                    local pid = search_results[idx].id
                    playlist_detail_url = api_base_url .. "?v=" .. version .. "&search=" .. textutils.urlEncode("https://www.youtube.com/playlist?list=" .. pid)
                    http.request(playlist_detail_url)
                    redrawScreen()
                else
                    in_search_result = true
                    redrawScreen()
                end
                return
            end
        end
    end
end

function handleResultMenuClick(button, x, y)
    if playlist_loading then return end

    local data = clicked_result_data or search_results[clicked_result]
    if not data then
        in_search_result = false
        redrawScreen()
        return
    end

    term.setBackgroundColor(colors.white)
    term.setTextColor(colors.black)

    if y == 6 then
        term.setCursorPos(2, 6)
        term.clearLine()
        term.write(" Play now")
        sleep(0.15)
        in_search_result = false
        clicked_result_data = nil
        actionPlayNow(data)
        tab = 1
        redrawScreen()
    elseif y == 8 then
        term.setCursorPos(2, 8)
        term.clearLine()
        term.write(" Play next")
        sleep(0.15)
        in_search_result = false
        clicked_result_data = nil
        actionPlayNext(data)
        local count = 1
        if data.type == "playlist" and data.playlist_items then count = #data.playlist_items end
        showToast("Added " .. count .. " to queue")
        redrawScreen()
    elseif y == 10 then
        term.setCursorPos(2, 10)
        term.clearLine()
        term.write(" Add to queue")
        sleep(0.15)
        in_search_result = false
        clicked_result_data = nil
        actionAddToQueue(data)
        local count = 1
        if data.type == "playlist" and data.playlist_items then count = #data.playlist_items end
        showToast("Added " .. count .. " to queue")
        redrawScreen()
    elseif y == 13 then
        term.setCursorPos(2, 13)
        term.clearLine()
        term.write(" Cancel")
        sleep(0.15)
        in_search_result = false
        clicked_result_data = nil
        redrawScreen()
    end
end

function handleNowPlayingClick(button, x, y)
    -- Controls row (y == 6)
    if y == 6 then
        local has_content = now_playing ~= nil or #queue > 0

        -- Play/Stop: x 2..7
        if x >= 2 and x <= 7 then
            if playing or has_content then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
                term.setCursorPos(2, 6)
                if playing then term.write(" Stop ") else term.write(" Play ") end
                sleep(0.15)
            end
            if playing then
                playing = false
                for _, speaker in ipairs(speakers) do
                    speaker.stop()
                    os.queueEvent("playback_stopped")
                end
                playing_id = nil
                is_loading = false
                is_error = false
                os.queueEvent("audio_update")
            elseif now_playing ~= nil then
                playing_id = nil
                playing = true
                is_error = false
                os.queueEvent("audio_update")
            elseif #queue > 0 then
                now_playing = queue[1]
                table.remove(queue, 1)
                playing_id = nil
                playing = true
                is_error = false
                os.queueEvent("audio_update")
            end
            redrawScreen()
            return
        end

        -- Skip: x 9..14
        if x >= 9 and x <= 14 then
            if now_playing ~= nil or #queue > 0 then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
                term.setCursorPos(9, 6)
                term.write(" Skip ")
                sleep(0.15)

                is_error = false
                if playing then
                    for _, speaker in ipairs(speakers) do
                        speaker.stop()
                        os.queueEvent("playback_stopped")
                    end
                end
                if #queue > 0 then
                    if looping == 1 then
                        table.insert(queue, now_playing)
                    end
                    now_playing = queue[1]
                    table.remove(queue, 1)
                    playing_id = nil
                else
                    now_playing = nil
                    playing = false
                    is_loading = false
                    is_error = false
                    playing_id = nil
                end
                os.queueEvent("audio_update")
            end
            redrawScreen()
            return
        end

        -- Shuffle: x 16..21
        if x >= 16 and x <= 21 then
            if #queue > 1 then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
                term.setCursorPos(16, 6)
                term.write(" Shuf ")
                sleep(0.15)
                shuffleQueue()
                queue_scroll = 0
                showToast("Queue shuffled")
            end
            redrawScreen()
            return
        end

        -- Loop: x 23+
        if x >= 23 then
            if looping == 0 then
                looping = 1
            elseif looping == 1 then
                looping = 2
            else
                looping = 0
            end
            redrawScreen()
            return
        end
    end

    -- Volume slider (row 7)
    if y == 7 and x >= 1 and x < 2 + 24 then
        volume = (x - 1) / 24 * 3
        redrawScreen()
        return
    end

    -- Save / Clear buttons (row 8)
    if y == 8 then
        local clear_label = " Clear "
        local save_label = " Save "
        local clear_x = width - #clear_label
        local save_x = clear_x - #save_label - 1

        if x >= save_x and x < save_x + #save_label then
            if now_playing or #queue > 0 then
                waiting_for_save_name = true
            end
            return
        end

        if x >= clear_x and x < clear_x + #clear_label then
            if #queue > 0 then
                queue = {}
                queue_scroll = 0
                showToast("Queue cleared")
                os.queueEvent("audio_update")
            end
            redrawScreen()
            return
        end
    end

    -- Queue item right-click to remove (row 9+)
    if button == 2 and #queue > 0 and y >= 9 then
        local max_visible = math.floor((height - 9) / 2)
        if max_visible < 1 then max_visible = 1 end
        for i = 1, max_visible do
            local idx = i + queue_scroll
            if idx > #queue then break end
            local ry = 9 + (i - 1) * 2
            if y == ry or y == ry + 1 then
                local removed = queue[idx].name
                table.remove(queue, idx)
                if queue_scroll > 0 and queue_scroll >= #queue then
                    queue_scroll = math.max(0, #queue - max_visible)
                end
                showToast("Removed: " .. truncStr(removed, 20))
                redrawScreen()
                return
            end
        end
    end
end

function handleLibraryClick(button, x, y)
    if #saved_playlists == 0 then return end

    local list_start_y = 5
    local max_visible = height - list_start_y
    if max_visible < 1 then max_visible = 1 end

    for i = 1, max_visible do
        local idx = i + library_scroll
        if idx > #saved_playlists then break end
        local ry = list_start_y + (i - 1)
        if y == ry then
            -- Highlight
            term.setBackgroundColor(colors.white)
            term.setTextColor(colors.black)
            term.setCursorPos(2, ry)
            term.clearLine()
            term.write(truncStr(saved_playlists[idx].name, width - 2))
            sleep(0.15)

            clicked_library_idx = idx
            in_library_menu = true
            redrawScreen()
            return
        end
    end
end

function handleLibraryMenuClick(button, x, y)
    local pl = saved_playlists[clicked_library_idx]
    if not pl then
        in_library_menu = false
        redrawScreen()
        return
    end

    term.setBackgroundColor(colors.white)
    term.setTextColor(colors.black)

    if y == 5 then
        -- Play now
        term.setCursorPos(2, 5)
        term.clearLine()
        term.write(" Play now")
        sleep(0.15)
        local tracks = loadPlaylistFile(pl.name)
        if tracks and #tracks > 0 then
            in_library_menu = false
            actionPlaySavedPlaylist(tracks)
            tab = 1
            showToast("Playing: " .. pl.name)
        end
        redrawScreen()
    elseif y == 7 then
        -- Add to queue
        term.setCursorPos(2, 7)
        term.clearLine()
        term.write(" Add to queue")
        sleep(0.15)
        local tracks = loadPlaylistFile(pl.name)
        if tracks and #tracks > 0 then
            in_library_menu = false
            actionQueueSavedPlaylist(tracks)
            showToast("Added " .. #tracks .. " tracks")
        end
        redrawScreen()
    elseif y == 9 then
        -- Delete
        term.setCursorPos(2, 9)
        term.clearLine()
        term.write(" Delete")
        sleep(0.15)
        deleteSavedPlaylist(pl.name)
        in_library_menu = false
        showToast("Deleted: " .. pl.name)
        redrawScreen()
    elseif y == 12 then
        -- Cancel
        term.setCursorPos(2, 12)
        term.clearLine()
        term.write(" Cancel")
        sleep(0.15)
        in_library_menu = false
        redrawScreen()
    end
end

---------------------------------------------------------------------------
-- Audio Loop (streams DFPWM from server)
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
                        -- Song ended
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
                                now_playing = nil
                                playing = false
                                playing_id = nil
                                is_loading = false
                                is_error = false
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
                                            function()
                                                os.pullEvent("playback_stopped")
                                            end
                                        )
                                        if not playing or playing_id ~= thisnowplayingid then return end
                                    end
                                else
                                    while not speaker.playAudio(buffer, volume) do
                                        parallel.waitForAny(
                                            function()
                                                repeat until select(2, os.pullEvent("speaker_audio_empty")) == name
                                            end,
                                            function()
                                                os.pullEvent("playback_stopped")
                                            end
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

                        if not playing or playing_id ~= thisnowplayingid then
                            break
                        end
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
                local event, url, handle = os.pullEvent("http_success")

                -- Search results
                if url == last_search_url then
                    local body = handle.readAll()
                    handle.close()
                    if is_piped_search then
                        local data = textutils.unserialiseJSON(body)
                        if data and data.items then
                            search_results = {}
                            for _, item in ipairs(data.items) do
                                local pid = nil
                                if item.url then
                                    pid = item.url:match("list=([%w_%-]+)")
                                end
                                if pid then
                                    table.insert(search_results, {
                                        id = pid,
                                        name = cleanStr(item.name or "Unknown Playlist"),
                                        artist = "Playlist  " .. (item.videos or "?") .. " videos  " .. cleanStr(item.uploaderName or ""),
                                        type = "playlist_search"
                                    })
                                end
                            end
                        else
                            search_results = {}
                        end
                    else
                        search_results = textutils.unserialiseJSON(body)
                        if not search_results then search_results = {} end
                    end
                    os.queueEvent("redraw_screen")
                end

                -- Playlist detail
                if url == playlist_detail_url then
                    local body = handle.readAll()
                    handle.close()
                    playlist_loading = false
                    local data = textutils.unserialiseJSON(body)
                    if data and #data > 0 then
                        clicked_result_data = data[1]
                    else
                        clicked_result_data = search_results[clicked_result]
                    end
                    os.queueEvent("redraw_screen")
                end

                -- Audio download
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
                local event, url = os.pullEvent("http_failure")

                if url == last_search_url then
                    search_error = true
                    search_results = nil
                    os.queueEvent("redraw_screen")
                end
                if url == playlist_detail_url then
                    playlist_loading = false
                    clicked_result_data = search_results[clicked_result]
                    os.queueEvent("redraw_screen")
                end
                if url == last_download_url then
                    is_loading = false
                    is_error = true
                    playing = false
                    playing_id = nil
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
parallel.waitForAny(uiLoop, audioLoop, httpLoop)
