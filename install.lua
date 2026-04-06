-- MC-CC-Music Installer
-- Run this on your ComputerCraft computer:
--   wget run https://raw.githubusercontent.com/Tid0s19/MC-CC-Music/claude/computercraft-yt-playlists-0kMxe/install.lua

local url = "https://raw.githubusercontent.com/Tid0s19/MC-CC-Music/claude/computercraft-yt-playlists-0kMxe/music.lua"
local filename = "music.lua"

print("MC-CC-Music Installer")
print("=====================")
print("")

-- Check for speaker
local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
    print("WARNING: No speaker detected!")
    print("Attach a speaker before running.")
    print("")
end

-- Check for advanced computer
if not term.isColor() then
    print("WARNING: This requires an")
    print("Advanced Computer (gold border).")
    print("")
end

print("Downloading " .. filename .. "...")
local ok, err = pcall(function()
    if fs.exists(filename) then
        fs.delete(filename)
    end
    shell.run("wget", url, filename)
end)

if ok and fs.exists(filename) then
    print("")
    print("Installed! Run with:")
    print("  " .. filename:gsub("%.lua$", ""))
    print("")
    print("Or type: music")
else
    print("")
    print("Download failed. Check HTTP is")
    print("enabled in server config.")
end
