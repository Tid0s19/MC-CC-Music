-- MC-CC-Music: ComputerCraft YouTube Music Player with Playlist Support
-- Based on terreng/computercraft-streaming-music
-- Requires: CC:Tweaked 1.100.0+, Advanced Computer, Speaker

local api_base_url = "https://ipod-2to6magyna-uc.a.run.app/"
local piped_api = "https://pipedapi.kavin.rocks"
local version = "2.1"

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

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
function redrawScreen()
    if waiting_for_input then return end
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.clear()

    -- Tabs
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    local tabs = { " Now Playing ", " Search " }
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
    end
end

function drawNowPlaying()
    term.setBackgroundColor(colors.black)
    if now_playing ~= nil then
        term.setTextColor(colors.white)
        term.setCursorPos(2, 3)
        term.write(truncStr(now_playing.name, width - 2))
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 4)
        term.write(truncStr(now_playing.artist, width - 2))
    else
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 3)
        term.write("Not playing")
    end

    if is_loading then
        term.setTextColor(colors.gray)
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2, 5)
        term.write("Loading...")
    elseif is_error then
        term.setTextColor(colors.red)
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2, 5)
        term.write("Network error")
    end

    -- Controls row
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.gray)

    if playing then
        term.setCursorPos(2, 6)
        term.write(" Stop ")
    else
        if now_playing ~= nil or #queue > 0 then
            term.setTextColor(colors.white)
        else
            term.setTextColor(colors.lightGray)
        end
        term.setBackgroundColor(colors.gray)
        term.setCursorPos(2, 6)
        term.write(" Play ")
    end

    if now_playing ~= nil or #queue > 0 then
        term.setTextColor(colors.white)
    else
        term.setTextColor(colors.lightGray)
    end
    term.setBackgroundColor(colors.gray)
    term.setCursorPos(2 + 7, 6)
    term.write(" Skip ")

    if looping ~= 0 then
        term.setTextColor(colors.black)
        term.setBackgroundColor(colors.white)
    else
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.gray)
    end
    term.setCursorPos(2 + 7 + 7, 6)
    if looping == 0 then
        term.write(" Loop Off ")
    elseif looping == 1 then
        term.write(" Loop Queue ")
    else
        term.write(" Loop Song ")
    end

    -- Volume slider
    term.setCursorPos(2, 8)
    paintutils.drawBox(2, 8, 25, 8, colors.gray)
    local vw = math.floor(24 * (volume / 3) + 0.5) - 1
    if vw >= 0 then
        paintutils.drawBox(2, 8, 2 + vw, 8, colors.white)
    end
    local pct = math.floor(100 * (volume / 3) + 0.5) .. "%"
    if volume < 0.6 then
        term.setCursorPos(2 + vw + 2, 8)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
    else
        term.setCursorPos(2 + vw - 3 - (volume == 3 and 1 or 0), 8)
        term.setBackgroundColor(colors.white)
        term.setTextColor(colors.black)
    end
    term.write(pct)

    -- Queue
    if #queue > 0 then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.gray)
        term.setCursorPos(2, 9)
        term.write("Queue (" .. #queue .. ")  [right-click to remove]")

        local max_visible = math.floor((height - 10) / 2)
        if max_visible < 1 then max_visible = 1 end

        if queue_scroll > math.max(0, #queue - max_visible) then
            queue_scroll = math.max(0, #queue - max_visible)
        end

        for i = 1, max_visible do
            local idx = i + queue_scroll
            if idx > #queue then break end
            term.setTextColor(colors.white)
            term.setCursorPos(2, 10 + (i - 1) * 2)
            term.write(truncStr(queue[idx].name, width - 2))
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2, 11 + (i - 1) * 2)
            term.write(truncStr(queue[idx].artist, width - 2))
        end

        -- Scroll indicators
        if queue_scroll > 0 then
            term.setTextColor(colors.gray)
            term.setCursorPos(width, 10)
            term.write("\24")
        end
        if queue_scroll + max_visible < #queue then
            term.setTextColor(colors.gray)
            term.setCursorPos(width, height)
            term.write("\25")
        end
    end
end

function drawSearch()
    -- Search bar
    paintutils.drawFilledBox(2, 3, width - 1, 3, colors.lightGray)
    term.setBackgroundColor(colors.lightGray)
    term.setCursorPos(3, 3)
    term.setTextColor(colors.black)
    term.write(truncStr(last_search or "Search...", width - 4))

    -- Mode toggle
    term.setCursorPos(2, 5)
    if search_mode == 1 then
        term.setBackgroundColor(colors.white)
        term.setTextColor(colors.black)
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
    end
    term.write(" Songs ")

    if search_mode == 2 then
        term.setBackgroundColor(colors.white)
        term.setTextColor(colors.black)
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
    end
    term.write(" Playlists ")

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

        -- Scroll indicators
        if search_scroll > 0 then
            term.setTextColor(colors.gray)
            term.setCursorPos(width, results_start_y)
            term.write("\24")
        end
        if search_scroll + max_visible < #search_results then
            term.setTextColor(colors.gray)
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
            term.write("Paste a YouTube video or")
            term.setCursorPos(2, results_start_y + 1)
            term.write("playlist URL, or search.")
            term.setCursorPos(2, results_start_y + 3)
            term.write("Use the Playlists tab to")
            term.setCursorPos(2, results_start_y + 4)
            term.write("search for playlists.")
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
        term.setCursorPos(2, 2)
        term.setTextColor(colors.lightGray)
        term.write("Loading playlist details...")
        return
    end

    local data = clicked_result_data or search_results[clicked_result]
    if not data then
        in_search_result = false
        return
    end

    term.setCursorPos(2, 2)
    term.setTextColor(colors.white)
    term.write(truncStr(data.name or "", width - 2))
    term.setCursorPos(2, 3)
    term.setTextColor(colors.lightGray)
    term.write(truncStr(data.artist or "", width - 2))

    local is_pl = (data.type == "playlist") and data.playlist_items
    if is_pl then
        term.setCursorPos(2, 4)
        term.setTextColor(colors.gray)
        term.write(#data.playlist_items .. " tracks")
    end

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)

    local row = 6
    term.setCursorPos(2, row)
    term.clearLine()
    if is_pl then
        term.write("Play all now")
    else
        term.write("Play now")
    end

    row = 8
    term.setCursorPos(2, row)
    term.clearLine()
    if is_pl then
        term.write("Play all next")
    else
        term.write("Play next")
    end

    row = 10
    term.setCursorPos(2, row)
    term.clearLine()
    if is_pl then
        term.write("Add all to queue")
    else
        term.write("Add to queue")
    end

    term.setCursorPos(2, 13)
    term.clearLine()
    term.write("Cancel")
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

    -- Check if it is a playlist URL (works in any mode)
    local has_list = input:match("[?&]list=([%w_%-]+)")
    -- Check if it is a video URL
    local has_video = input:match("youtu") and (input:match("v=([%w_%-]+)") or input:match("youtu%.be/([%w_%-]+)"))

    if has_list or has_video or search_mode == 1 then
        -- Use the main server for: video search, video URLs, playlist URLs
        is_piped_search = false
        last_search_url = api_base_url .. "?v=" .. version .. "&search=" .. textutils.urlEncode(input)
        http.request(last_search_url)
    else
        -- Playlist text search via Piped API
        is_piped_search = true
        last_search_url = piped_api .. "/search?q=" .. textutils.urlEncode(input) .. "&filter=playlists"
        http.request(last_search_url)
    end
end

---------------------------------------------------------------------------
-- Action helpers
---------------------------------------------------------------------------
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

---------------------------------------------------------------------------
-- UI Loop
---------------------------------------------------------------------------
function uiLoop()
    redrawScreen()

    while true do
        if waiting_for_input then
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
                        if y >= 7 and y <= 9 and x >= 1 and x < 2 + 24 then
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
                end
            )
        end
    end
end

function handleScroll(direction)
    if tab == 1 and not in_search_result then
        local max_visible = math.floor((height - 10) / 2)
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
    end
end

function handleClick(button, x, y)
    -- Tab switching
    if y == 1 and not in_search_result then
        if x < width / 2 then
            tab = 1
        else
            tab = 2
        end
        redrawScreen()
        return
    end

    if tab == 2 and not in_search_result then
        handleSearchTabClick(button, x, y)
    elseif tab == 2 and in_search_result then
        handleResultMenuClick(button, x, y)
    elseif tab == 1 and not in_search_result then
        handleNowPlayingClick(button, x, y)
    end
end

function handleSearchTabClick(button, x, y)
    -- Search bar click
    if y == 3 and x >= 2 and x <= width - 1 then
        paintutils.drawFilledBox(2, 3, width - 1, 3, colors.white)
        term.setBackgroundColor(colors.white)
        waiting_for_input = true
        return
    end

    -- Mode toggle
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
        elseif x >= 9 and x < 9 + 11 then
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
                -- Highlight
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
                term.setCursorPos(2, ry)
                term.clearLine()
                term.write(truncStr(search_results[idx].name or "", width - 2))
                sleep(0.15)

                clicked_result = idx
                clicked_result_data = nil
                playlist_loading = false

                -- If this is a playlist search result from Piped, load full details
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
        term.write("Play now")
        sleep(0.15)
        in_search_result = false
        clicked_result_data = nil
        actionPlayNow(data)
        redrawScreen()
    elseif y == 8 then
        term.setCursorPos(2, 8)
        term.clearLine()
        term.write("Play next")
        sleep(0.15)
        in_search_result = false
        clicked_result_data = nil
        actionPlayNext(data)
        redrawScreen()
    elseif y == 10 then
        term.setCursorPos(2, 10)
        term.clearLine()
        term.write("Add to queue")
        sleep(0.15)
        in_search_result = false
        clicked_result_data = nil
        actionAddToQueue(data)
        redrawScreen()
    elseif y == 13 then
        term.setCursorPos(2, 13)
        term.clearLine()
        term.write("Cancel")
        sleep(0.15)
        in_search_result = false
        clicked_result_data = nil
        redrawScreen()
    end
end

function handleNowPlayingClick(button, x, y)
    if y == 6 then
        -- Play/Stop button
        if x >= 2 and x < 2 + 6 then
            if playing or now_playing ~= nil or #queue > 0 then
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

        -- Skip button
        if x >= 2 + 7 and x < 2 + 7 + 6 then
            if now_playing ~= nil or #queue > 0 then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
                term.setCursorPos(2 + 7, 6)
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

        -- Loop button
        if x >= 2 + 7 + 7 and x < 2 + 7 + 7 + 12 then
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

    -- Volume slider
    if y == 8 and x >= 1 and x < 2 + 24 then
        volume = (x - 1) / 24 * 3
        redrawScreen()
        return
    end

    -- Queue item right-click to remove
    if button == 2 and #queue > 0 and y >= 10 then
        local max_visible = math.floor((height - 10) / 2)
        if max_visible < 1 then max_visible = 1 end
        for i = 1, max_visible do
            local idx = i + queue_scroll
            if idx > #queue then break end
            local ry = 10 + (i - 1) * 2
            if y == ry or y == ry + 1 then
                table.remove(queue, idx)
                if queue_scroll > 0 and queue_scroll >= #queue then
                    queue_scroll = math.max(0, #queue - max_visible)
                end
                redrawScreen()
                return
            end
        end
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

                -- Search results (songs via server OR playlists via Piped)
                if url == last_search_url then
                    local body = handle.readAll()
                    handle.close()
                    if is_piped_search then
                        -- Parse Piped API response
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
                            if #search_results == 0 then
                                search_results = {}
                            end
                        else
                            search_results = {}
                        end
                    else
                        -- Parse server response (original format)
                        search_results = textutils.unserialiseJSON(body)
                        if not search_results then search_results = {} end
                    end
                    os.queueEvent("redraw_screen")
                end

                -- Playlist detail loaded from server
                if url == playlist_detail_url then
                    local body = handle.readAll()
                    handle.close()
                    playlist_loading = false
                    local data = textutils.unserialiseJSON(body)
                    if data and #data > 0 then
                        clicked_result_data = data[1]
                    else
                        -- Failed to load details, show basic info
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
                    -- If piped search failed, try without piped (fallback)
                    if is_piped_search then
                        search_error = true
                        search_results = nil
                    else
                        search_error = true
                    end
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
