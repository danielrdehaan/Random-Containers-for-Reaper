-- @description Random Containers for Reaper
-- @author Simple Sound Tools
-- @version 2.0.B.005
-- @about
--   	This script brings the essential functionality of audio middleware to Reaper
-- @provides
-- 		[nomain] Fonts/Roboto/*.ttf
-- 		[nomain] Data/*.lua
-- @changelog
-- 		Update to repo README.md contents with installation video and user guide.
SCRIPT_FOLDER = 'Random Containers'
r = reaper
SEP = package.config:sub(1, 1)
DATA = _VERSION == 'Lua 5.3' and 'Data53' or 'Data'
DATA_PATH = debug.getinfo(1, 'S').source:match '@(.+[/\\])' .. DATA .. SEP
dofile(DATA_PATH .. 'Simple-Sound-Tools_Random-Container-Functions.lua')
