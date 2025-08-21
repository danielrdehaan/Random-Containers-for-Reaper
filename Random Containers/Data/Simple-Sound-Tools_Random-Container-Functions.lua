-- @noindex
--[[
  DRD_Random Container Editor.lua
  --------------------------------
  By: Daniel Dehaan
--]]

---------------------------------------------------------
--                 Global State                        --
---------------------------------------------------------

local scriptID  = "RandomContainers"
local isRunning = (reaper.GetExtState(scriptID, "Running") == "1")

-- REPLACE THIS with your script's actual Command ID from REAPER’s Action List:
local commandName = "_RS57fe93c86c48458c08bcf6d59856566422eb3160"
local commandID   = reaper.NamedCommandLookup(commandName)

local lastInsideState       = {} -- itemGUID -> bool
local sequentialTakeIndices = {} -- itemGUID -> integer
local shuffleHistory        = {} -- itemGUID -> {recent take indices}
local lastPlayState         = -1

---------------------------------------------------------
--           Utility / Helper Functions                --
---------------------------------------------------------

local function getItemGUID(item)
    return reaper.BR_GetMediaItemGUID(item)
end

local function getItemNotes(item)
    local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    return notes or ""
end

-- random float in [low, high]
local function randomFloat(low, high)
    return low + (high - low) * math.random()
end

---------------------------------------------------------
--             #rc_container(1) logic                   --
---------------------------------------------------------
local function isRandomContainer(notes)
    -- Define the tags to check
    local enabledTags = {
        "#rc_enableTakeRandomization",
        "#rc_enableTriggerProbability",
        "#rc_enableVolumeRandomization",
        "#rc_enablePanRandomization",
        "#rc_enablePitchRandomization",
        "#rc_enableTimingRandomization(1)"
    }

    -- Loop through the tags and check if any are enabled
    for _, tag in ipairs(enabledTags) do
        local match = notes:match(tag .. "%((%d)%)")
        if match and tonumber(match) == 1 then
            return true
        end
    end

    -- If no tags are enabled, return false
    return false
end

---------------------------------------------------------
--               Get enbabled states                   --
---------------------------------------------------------

local function getEnableTakeRandomization(notes)
    local match = notes:match("#rc_enableTakeRandomization%((%d)%)")
    return match and tonumber(match) == 1 or false
end

local function getEnableTriggerProbability(notes)
    local match = notes:match("#rc_enableTriggerProbability%((%d)%)")
    return match and tonumber(match) == 1 or false
end

local function getEnableVolumeRandomization(notes)
    local match = notes:match("#rc_enableVolumeRandomization%((%d)%)")
    return match and tonumber(match) == 1 or false
end

local function getEnablePanRandomization(notes)
    local match = notes:match("#rc_enablePanRandomization%((%d)%)")
    return match and tonumber(match) == 1 or false
end

local function getEnablePitchRandomization(notes)
    local match = notes:match("#rc_enablePitchRandomization%((%d)%)")
    return match and tonumber(match) == 1 or false
end

local function getPreservePlayRate(notes)
    local match = notes:match("#rc_preservePlayRate%((%d)%)")
    return match and tonumber(match) == 1 or false
end

---------------------------------------------------------
--        Get Start Offset Tags Separately             --
---------------------------------------------------------
local function getEnableStartOffsetRandomization(notes)
    local match = notes:match("#rc_enableStartOffsetRandomization%((%d)%)")
    return match and tonumber(match) == 1 or false
end

local function getStartOffset(notes)
    local startOffset = notes:match("#rc_startOffset%(([^)]+)%)")
    return tonumber(startOffset)
end

local function getStartOffsetRandAmount(notes)
    local offsetRandAmount = notes:match("#rc_startOffsetRandomizationAmount%(([^)]+)%)")
    return tonumber(offsetRandAmount)
end


---------------------------------------------------------
--          Randomize Start Offset Function            --
---------------------------------------------------------

local function applyRandomizeStartOffset(item)
    if not item then return end

    -- Retrieve the item's notes and current start position
    local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    
    local activeTake = reaper.GetActiveTake(item)
    if not activeTake then return end

    local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    -- Get fix start offset amount
    local startOffset = itemLength * ((getStartOffset(notes) * 0.01) or 0)

    -- Retrieve timing range from tags
    local offsetRandAmount = itemLength * ((getStartOffsetRandAmount(notes) * 0.01) or 0)

    -- Calculate the new randomized start position
    local randomOffset = startOffset + (math.random() * offsetRandAmount)

    -- Update the item's start position
    reaper.SetMediaItemTakeInfo_Value(activeTake,"D_STARTOFFS", randomOffset)

    -- Update the project to reflect the changes
    reaper.UpdateItemInProject(item)
end


---------------------------------------------------------
--                #rc_probability(x) logic             --
---------------------------------------------------------
local function getProbabilityValue(notes)
    local probString = notes:match("#rc_probability%(([^)]+)%)")
    if probString then
        local p = tonumber(probString)
        if p then
            if p < 0 then p = 0 end
            if p > 100 then p = 100 end
            return p
        end
    end
    return nil
end

local function applyProbabilityMute(item, probability)
    if not probability then return end

    local dice = math.random(100)  -- [1..100]
    local muteState = 1 -- default: muted
    if dice <= probability then
        muteState = 0 -- unmuted
    end
    reaper.SetMediaItemInfo_Value(item, "B_MUTE", muteState)
    reaper.UpdateItemInProject(item)
end

---------------------------------------------------------
--           #rc_takeMode(x) => shuffle or seq or weighted   --
---------------------------------------------------------

local function getTakeMode(notes)
    local modeString = notes:match("#rc_takeMode%(([^)]+)%)")
    if modeString then
        local trimmed = modeString:lower():gsub("%s+", "")
        if trimmed == "shuffle" then
            return "shuffle"
        elseif trimmed == "seq" or trimmed == "sequential" then
            return "seq"
        elseif trimmed == "weighted" then
            return "weighted"
        end
    end
    return nil
end

local function getShuffleNoRepeat(notes)
    local n = notes:match("#rc_shuffleNoRepeat%((%d+)%)")
    n = tonumber(n)
    if not n or n < 1 then return 1 end
    return math.floor(n)
end

local function doShuffle(item)
    local takeCount = reaper.CountTakes(item)
    if takeCount <= 1 then
        reaper.SetActiveTake(reaper.GetMediaItemTake(item, 0))
        return
    end

    local guid   = getItemGUID(item)
    local notes  = getItemNotes(item)
    local N      = getShuffleNoRepeat(notes)
    local history = shuffleHistory[guid] or {}

    local currentTakeIndex = reaper.GetMediaItemInfo_Value(item, "I_CURTAKE")

    local function buildCandidates()
        local candidates = {}
        for i = 0, takeCount - 1 do
            local skip = (i == currentTakeIndex)
            if not skip then
                for _, h in ipairs(history) do
                    if h == i then
                        skip = true
                        break
                    end
                end
            end
            if not skip then
                table.insert(candidates, i)
            end
        end
        return candidates
    end

    local candidates = buildCandidates()
    while #candidates == 0 and #history > 0 do
        table.remove(history, 1)
        candidates = buildCandidates()
    end

    if #candidates == 0 then
        for i = 0, takeCount - 1 do
            if i ~= currentTakeIndex then table.insert(candidates, i) end
        end
    end

    local newTake = candidates[math.random(#candidates)]
    reaper.SetActiveTake(reaper.GetMediaItemTake(item, newTake))
    reaper.UpdateItemInProject(item)

    table.insert(history, newTake)
    while #history > N do table.remove(history, 1) end
    shuffleHistory[guid] = history
end

local function doSequential(item)
    local itemGUID  = getItemGUID(item)
    local takeCount = reaper.CountTakes(item)
    if takeCount < 1 then return end

    local oldIndex = sequentialTakeIndices[itemGUID] or -1
    local newIndex = (oldIndex + 1) % takeCount

    reaper.SetActiveTake(reaper.GetMediaItemTake(item, newIndex))
    reaper.UpdateItemInProject(item)
    sequentialTakeIndices[itemGUID] = newIndex
end

---------------------------------------------------------
--        #rc_takeWeights(...) => Weighted logic            --
---------------------------------------------------------

local function getRWeightArray(notes)
    -- parse something like #rc_takeWeights(10,20,70) => {10,20,70}
    local wLine = notes:match("#rc_takeWeights%(([^)]+)%)")
    if not wLine then 
        return nil 
    end

    local arr = {}
    for token in wLine:gmatch("[^,]+") do
        local val = tonumber(token)
        if val then
            table.insert(arr, val)
        end
    end

    if #arr == 0 then 
        return nil 
    end

    return arr
end

local function doWeighted(item, wArr)
    local takeCount = reaper.CountTakes(item)
    if takeCount < 1 then return end

    -- If # of takes doesn't match # of weights, do fallback or do nothing:
    if #wArr ~= takeCount then
        -- fallback: set take 0 or skip
        reaper.SetActiveTake(reaper.GetMediaItemTake(item, 0))
        return
    end

    -- Sum up percentages
    local sum = 0
    for _, weightVal in ipairs(wArr) do
        sum = sum + weightVal
    end

    if sum <= 0 then
        -- If all weights are zero or invalid, fallback
        reaper.SetActiveTake(reaper.GetMediaItemTake(item, 0))
        return
    end

    -- Generate a random float in [0, sum)
    local r = randomFloat(0, sum)
    local cumulative = 0

    -- Walk each weight until we find r's "bucket"
    for i, weightVal in ipairs(wArr) do
        cumulative = cumulative + weightVal
        if r <= cumulative then
            -- i is 1-based, takes are 0-based
            reaper.SetActiveTake(reaper.GetMediaItemTake(item, i-1))
            break
        end
    end

    reaper.UpdateItemInProject(item)
end

---------------------------------------------------------
--                 Pitch Randomization                 --
---------------------------------------------------------

-- Function to extract pitch range from media item notes
local function getPitchRandomizationAmount(notes)
    local pitchRandAmount = tonumber(notes:match("#rc_pitchRandomizationAmount%(([^)]+)%)"))
    return pitchRandAmount
end

-- Function to extract pitch offsets (semitones and cents) from media item notes
local function getPitchOffsets(notes)
    local semitoneOffset = tonumber(notes:match("#rc_pitchOffsetSemitones%(([^)]+)%)")) or 0
    local centsOffset = tonumber(notes:match("#rc_pitchOffsetCents%(([^)]+)%)")) or 0
    return semitoneOffset, centsOffset
end

-- Convert semitone offset to playback rate
local function semitonesToPlayRate(semi)
    return 2 ^ (semi / 12.0)
end

-- Reset pitch, play rate, and optionally item length for all takes in an item
local function resetPitchAndPlayRate(item, preservePlayRate)
    if not item then return end

    -- Retrieve item notes to get the original length
    local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)

    -- Get the number of takes in the item
    local numTakes = reaper.CountTakes(item)
    if numTakes == 0 then return end

    -- Iterate through each take and reset pitch and playrate
    for i = 0, numTakes - 1 do
        local take = reaper.GetTake(item, i)
        if take then
            -- Disable "Preserve pitch when changing rate"
            reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0) 
            -- Reset pitch adjustment to 0 semitones
            reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", 0) 
            -- Reset playback rate to 1.0
            reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1.0) 
        end
    end

    -- Reset item length to the original value if available
    -- if originalLength then
    --     reaper.SetMediaItemInfo_Value(item, "D_LENGTH", originalLength)
    -- end

    -- Update the item in the project to apply changes
    reaper.UpdateItemInProject(item)
end


-- Function to handle pitch randomization
local function applyPitchRandomization(item)
    -- Get item notes
    local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    
    -- Check if pitch randomization is enabled
    local enablePitchRandomization = notes:match("#rc_enablePitchRandomization%((%d)%)")
    if enablePitchRandomization ~= "1" then return end
    
    -- Get pitch randomization amount
    local pitchRandAmount = getPitchRandomizationAmount(notes)
    if not pitchRandAmount then return end
    
    -- Get pitch offsets
    local semitoneOffset, centsOffset = getPitchOffsets(notes)
    
    -- Check the #rc_preservePlayRate tag
    local preservePlayRate = getPreservePlayRate(notes)
    
    -- Reset pitch, play rate, and length to default values
    resetPitchAndPlayRate(item, preservePlayRate)
    
    -- Generate a random semitone value within the range
    local randValue = (math.random() * (pitchRandAmount * 2)) - pitchRandAmount
    
    -- Adjust by offsets
    local adjustedValue = randValue + semitoneOffset + (centsOffset / 100)
    
    -- Get the active take
    local activeTake = reaper.GetActiveTake(item)
    if not activeTake then return end
    
    -- Convert semitone adjustment to playback rate
    local newRate = semitonesToPlayRate(adjustedValue)
    
    -- Set the new playback rate for the active take
    reaper.SetMediaItemTakeInfo_Value(activeTake, "D_PLAYRATE", newRate)
    
    -- Update the item in the project
    reaper.UpdateItemInProject(item)
end



---------------------------------------------------------
--     Volume Randomization Functions                  --
---------------------------------------------------------
local function getVolume(notes)
    local volume = tonumber(notes:match("#rc_volume%(([^)]+)%)"))
    return volume
end

local function getRandVolumeAmount(notes)
    local volRandAmount = tonumber(notes:match("#rc_volumeRandomizationAmount%(([^)]+)%)"))
    return volRandAmount
end

-- Function to Apply Randomized Volume to an Item
local function applyRandomVolume(item, baseVolume_dB, volRandAmount_percent)
    -- Calculate the maximum randomization range in dB based on the percentage
    local max_rand_dB = -70.0 * (volRandAmount_percent * 0.01)

    -- Generate a random dB offset within the range [max_rand_dB, 0 dB]
    local randDB = randomFloat(max_rand_dB, 0.0)

    -- Calculate the final volume in dB by adding the random offset to the base volume
    local finalVolume_dB = baseVolume_dB + randDB

    -- Clamp the final volume to stay within -70 dB to +12 dB
    if finalVolume_dB < -70.0 then
        finalVolume_dB = -70.0
    elseif finalVolume_dB > 12.0 then
        finalVolume_dB = 12.0
    end

    -- Convert the final dB volume to Reaper's linear scale
    local amplitude = 10 ^ (finalVolume_dB / 20)

    -- Set the item's volume in Reaper
    reaper.SetMediaItemInfo_Value(item, "D_VOL", amplitude)
    reaper.UpdateItemInProject(item)
end

---------------------------------------------------------
--       #rc_pan(x,y) => random TAKE pan logic         --
---------------------------------------------------------
local function getPan(notes)
    local pan = tonumber(notes:match("#rc_pan%(([^)]+)%)"))
    return pan
end

local function getPanAmount(notes)
    local panAmount = tonumber(notes:match("#rc_panRandomizationAmount%(([^)]+)%)"))
    return panAmount
end

local function applyRandomPanToTake(item, pan, panAmount)

    -- get the active take of the item
    local take = reaper.GetActiveTake(item)
    if not take then return end

    -- Calculate the random pan amount
    local randPan = pan + randomFloat(panAmount * -0.01, panAmount * 0.01)

    -- Clamp the random pan amount to be between -1 and 1
    if randPan < -1 then
        randPan = -1
    elseif randPan > 1 then
        randPan = 1
    end

    -- Update the item
    reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", randPan)
    reaper.UpdateItemInProject(item)
end



---------------------------------------------------------
--      Apply changes to a single item if tagged       --
---------------------------------------------------------
local function applyRandomizedParametersToItem(item)
    local notes = getItemNotes(item)
    if not notes then return end

    local muteState = 0 -- Default to unmuted

    -- Handle Trigger Probability
    if getEnableTriggerProbability(notes) then
        local probability = getProbabilityValue(notes)
        if probability then
            local dice = math.random(100) -- Generate a random value between 1 and 100
            if dice > probability then
                muteState = 1 -- Force muted if probability fails
            end
        end
    end

    -- Apply the final mute state to the item
    local currentMuteState = reaper.GetMediaItemInfo_Value(item, "B_MUTE")
    if currentMuteState ~= muteState then
        reaper.SetMediaItemInfo_Value(item, "B_MUTE", muteState)
        reaper.UpdateArrange() -- Force REAPER to refresh the arrangement view
    end

    -- Handle Take Randomization
    if getEnableTakeRandomization(notes) then
        local mode = getTakeMode(notes)
        if mode == "shuffle" then
            doShuffle(item)
        elseif mode == "seq" then
            doSequential(item)
        elseif mode == "weighted" then
            local wArr = getRWeightArray(notes)
            doWeighted(item, wArr)
        end
    end

    -- Handle Timing Randomization
    if getEnableStartOffsetRandomization(notes) then
        applyRandomizeStartOffset(item)
    end

    -- Handle Pitch Randomization
    if getEnablePitchRandomization(notes) then
        applyPitchRandomization(item)
    end

    -- Handle Volume Randomization
    if getEnableVolumeRandomization(notes) then
        local volume = getVolume(notes)
        local volRandAmount = getRandVolumeAmount(notes)
        if  volRandAmount then
            applyRandomVolume(item, volume, volRandAmount)
        end
    end

    -- Handle Pan Randomization
    if getEnablePanRandomization(notes) then
        local pan = getPan(notes)
        local panAmount = getPanAmount(notes)
        if panAmount then
            applyRandomPanToTake(item, pan, panAmount)
        end
    end

    reaper.UpdateItemInProject(item)
end


---------------------------------------------------------
--         Re-randomize ALL items immediately          --
---------------------------------------------------------

local function reRandomizeAllItems()
    local numItems = reaper.CountMediaItems(0)
    if numItems == 0 then return end
    for i = 0, numItems - 1 do
        local item = reaper.GetMediaItem(0, i)
        handleItemTakeSelection(item)
    end
end


---------------------------------------------------------
--                    Main Loop                        --
---------------------------------------------------------

-- State tracking variables
local lastInsideState = {} -- Tracks whether the playhead was inside an item
local processedItems = {}  -- Tracks items already randomized during the current cycle
local lastPlayPos = 0      -- Tracks the last known play position
local lastPlayState = -1   -- Tracks the last known play state

local function resetProcessedItems()
    processedItems = {}
end

local function main()
    -- Ensure the script continues only when running
    if not isRunning then return end

    reaper.PreventUIRefresh(1)

    local playState = reaper.GetPlayState() -- 0=stop, 1=play, 2=pause
    local playPos = reaper.GetPlayPosition() -- Current playhead position

    -- Reset everything if playback stops
    if playState == 0 then
        resetProcessedItems()
    end

    -- Handle playback loop: detect items that the playhead never exited
    if playPos < lastPlayPos then
        -- get the number of items in the project
        local numItems = reaper.CountMediaItems(0)
        -- loop over all items
        for i = 0, numItems - 1 do
            -- get the current item
            local item = reaper.GetMediaItem(0, i)
            local itemGUID = reaper.BR_GetMediaItemGUID(item)
            -- Randomize the item's parameters
            applyRandomizedParametersToItem(item)
        end
    end

    -- Handle playback logic only when playing
    if playState == 1 and lastPlayState ~= 1 then
        -- get the number of items in the project
        local numItems = reaper.CountMediaItems(0)
        -- loop over all items
        for i = 0, numItems - 1 do
            -- get the current item
            local item = reaper.GetMediaItem(0, i)
            local itemGUID = reaper.BR_GetMediaItemGUID(item)
            -- Randomize the item's parameters
            applyRandomizedParametersToItem(item)
        end
    end

    -- Update the last play position and play state for the next iteration
    lastPlayPos = playPos
    lastPlayState = playState

    reaper.PreventUIRefresh(-1)

    -- Continue the script loop
    reaper.defer(main)
end


    

---------------------------------------------------------
--              Start / Stop / Toggle                  --
---------------------------------------------------------

local function startPlaybackMonitoring()
    isRunning = true
    main()
end

local function stopPlaybackMonitoring()
    isRunning = false
end


--------------------------------------------------------------------------------
-- 1) Try to load the ImGui (reaper_imgui) library
--------------------------------------------------------------------------------
local ok, ImGui = pcall(function()
  package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
  return require('imgui')('0.9.2')  -- or your installed version
end)

if not ok or not ImGui then
  reaper.ShowMessageBox(
    "Could not load ReaImGui. Please install/update 'reaper_imgui' via ReaPack.",
    "Error",
    0
  )
  return
end

--------------------------------------------------------------------------------
-- 2) Create our ImGui context and set up the fonts
--------------------------------------------------------------------------------
local ctx = ImGui.CreateContext("DRD_Random Container Editor")

-- Define the font paths and sizes
local resourcePath = reaper.GetResourcePath()
local fontPath_RobotoBlack = resourcePath .. "/Scripts/Simple Sound Tools/Random Containers/Fonts/Roboto/Roboto-Black.ttf"
local fontSize_RobotoBlack = 32
local fontPath_RobotoLight = resourcePath .. "/Scripts/Simple Sound Tools/Random Containers/Fonts/Roboto/Roboto-Medium.ttf"
local fontSize_RobotoLight = 16

-- Load fonts
local font_Title = ImGui.CreateFont(fontPath_RobotoBlack, 32, ImGui.FontFlags_None)
local font_Heading = ImGui.CreateFont(fontPath_RobotoBlack, 16, ImGui.FontFlags_None)
local font_Parameter = ImGui.CreateFont(fontPath_RobotoLight, 14, ImGui.FontFlags_None)

local headingColor = 0xE8E8E8FF
local darkGrey = 0x333333FF
local paramColor = 0xC0C0C0FF

ImGui.Attach(ctx, font_Title)
ImGui.Attach(ctx, font_Heading)
ImGui.Attach(ctx, font_Parameter)

-- Helper function to round decimal values to whole number integers
local function round(x)
    if x >= 0 then
        return math.floor(x + 0.5)
    else
        return math.ceil(x - 0.5)
    end
end

--------------------------------------------------------------------------------
-- 3) Define the GUI state
--------------------------------------------------------------------------------
local state = {
  -- Last Selected Item
  lastItem                = nil,  -- The last-selected media item
  numTakes                = 0,    -- Number of takes in the last-selected item

  -- Take Randomization
  enableTakeRandomization = false, -- Enable/disable take randomization
  takeMode                = 0,     -- 0=Shuffle, 1=Sequential, 2=Weighted
  takeWeights             = {},    -- E.g., {25, 25, 25, 25} for Weighted mode
  shuffleNoRepeat         = 1,     -- #rc_shuffleNoRepeat(N)

  -- Trigger Probability
  enableTriggerProbability = false, -- Enable/disable trigger probability
  prob                      = 100.0, -- #rc_probability(50)

  -- Start Offset Randomization
  enableStartOffsetRandomization  = false, -- Enable/disable start offset randomization
  startOffset                     = 0.0,
  startOffsetRandAmount           = 0.0,   -- Start offset randomization amount

  -- Volume Randomization
  enableVolumeRandomization = false, -- Enable/disable volume randomization
  volume = 0.0,
  volumeRandAmount        = 0.0,  -- Minimum random volume in dB

  -- Pan Randomization
  enablePanRandomization  = false, -- Enable/disable pan randomization
  pan                     = 0.0,
  panRandAmount           = 0,  -- Minimum random pan value

  -- Pitch Randomization
  enablePitchRandomization  = false, -- Enable/disable pitch randomization
  pitchRandomizationAmount  = 0.0, -- Minimum pitch range in semitones
  pitchOffsetSemitones      = 0.0,     -- Offset in semitones

  -- Envelope Randomization
  enableEnvelopeRandomization  = false, -- Enable/disable pitch randomization
}


local rmodeOptions = {"Shuffle", "Sequential", "Weighted" }

--------------------------------------------------------------------------------
-- 4) parseItemNotes(notes, numTakes)
--    Parses metadata from item notes and returns a table of extracted parameters.
--------------------------------------------------------------------------------
local function parseItemNotes(notes, numTakes)
  -- Defaults
  local result = {
    -- Take Randomization
    enableTakeRandomization   = false,
    takeMode                  = 0,
    takeWeights               = {},
    shuffleNoRepeat           = 1,

    -- Trigger Probability
    enableTriggerProbability  = false,
    prob                      = 100,

    -- Start Offset Randomization
    enableStartOffsetRandomization  = false,
    startOffset                     = 0.0,
    startOffsetRandAmount           = 0.0,

    -- Volume Randomization
    enableVolumeRandomization = false,
    volume                    = 0.0,
    volumeRandAmount          = 0.0,

    -- Pan Randomization
    enablePanRandomization  = false,
    pan                     = 0.0,
    panRandAmount           = 0.0,

    -- Pitch Randomization
    enablePitchRandomization  = false,
    pitchRandomizationAmount  = 0.0,
    pitchOffsetSemitones      = 0.0,

    -- Envelope Randomization
    enableEnvelopeRandomization  = false,
  }

  -- Helper: Parse boolean tags
  local function parseBooleanTags(line)
    local boolTags = {
      enableTakeRandomization   = "^#rc_enableTakeRandomization%((%d+)%)",
      enableTriggerProbability  = "^#rc_enableTriggerProbability%((%d+)%)",
      enableVolumeRandomization = "^#rc_enableVolumeRandomization%((%d+)%)",
      enablePanRandomization    = "^#rc_enablePanRandomization%((%d+)%)",
      enablePitchRandomization  = "^#rc_enablePitchRandomization%((%d+)%)",
      enableStartOffsetRandomization = "^#rc_enableStartOffsetRandomization%((%d+)%)",
      enableEnvelopeRandomization = "^#rc_enableEnvelopeRandomization%((%d+)%)",
    }

    for key, pattern in pairs(boolTags) do
      local value = line:match(pattern)
      if value then
        result[key] = (tonumber(value) == 1)
      end
    end
  end

  -- Iterate through lines of notes
  for line in notes:gmatch("[^\r\n]+") do

    -- Take Randomization
    local takeMode = line:match("^#rc_takeMode%(([^)]+)%)")
    if takeMode then
      takeMode = takeMode:lower():gsub("%s+", "")
      result.takeMode = ({ shuffle = 0, sequential = 1, weighted = 2 })[takeMode] or 0
    end

    local weights = line:match("^#rc_takeWeights%(([^)]+)%)")
    if weights then
      local parsedWeights = {}
      for weight in weights:gmatch("[^,]+") do
        table.insert(parsedWeights, tonumber(weight) or 0)
      end
      if #parsedWeights == numTakes then
        result.takeWeights = parsedWeights
      end
    end

    local noRepeat = line:match("^#rc_shuffleNoRepeat%(([^)]+)%)")
    if noRepeat then
      result.shuffleNoRepeat = tonumber(noRepeat) or 1
    end

    -- Trigger Probability
    local probValue = line:match("^#rc_probability%(([^)]+)%)")
    if probValue then
      result.prob = math.min(100, math.max(0, tonumber(probValue)))
    end

    -- Start Offset
    local startOffset = line:match("^#rc_startOffset%(([^)]+)%)")
    if startOffset then
      result.startOffset = tonumber(startOffset) or 0
    end

    -- Start Offset Randomization
    local startOffsetRandAmount = line:match("^#rc_startOffsetRandomizationAmount%(([^)]+)%)")
    if startOffsetRandAmount then
      result.startOffsetRandAmount = tonumber(startOffsetRandAmount) or 0
    end

    -- Volume level
    local volume = line:match("^#rc_volume%(([^)]+)%)")
    if volume then
      result.volume = tonumber(volume)
    end

    -- Volume Randomization
    local volRandAmount = line:match("^#rc_volumeRandomizationAmount%(([^)]+)%)")
    if volRandAmount then
      result.volumeRandAmount = tonumber(volRandAmount)
    end

    -- Pan
    local pan = line:match("^#rc_pan%(([^)]+)%)")
    if pan then
      result.pan = tonumber(pan)
    end

    -- Pan Randomization
    local panAmount = line:match("^#rc_panRandomizationAmount%(([^)]+)%)")
    if panAmount then
      result.panRandAmount = tonumber(panAmount)
    end

    -- Pitch Randomization
    local pitchAmount = line:match("^#rc_pitchRandomizationAmount%(([^)]+)%)")
    if pitchAmount then
      result.pitchRandomizationAmount = tonumber(pitchAmount)
    end

    local semitoneOffset = line:match("^#rc_pitchOffsetSemitones%(([^)]+)%)")
    if semitoneOffset then
      result.pitchOffsetSemitones = tonumber(semitoneOffset) or 0
    end

    -- Parse boolean tags
    parseBooleanTags(line)
  end

  return result
end

--------------------------------------------------------------------------------
-- Helper: setOrReplaceTag(itemNotes, pattern, replacementLine)
-- Used for #rc_container(...), #rc_takeMode(...), etc.
--------------------------------------------------------------------------------
local function setOrReplaceTag(itemNotes, tagPattern, replacementLine)
  local replaced = false
  local newLines = {}
  for line in itemNotes:gmatch("([^\r\n]*)\r?\n?") do
    if line:match(tagPattern) then
      if replacementLine ~= "" then
        table.insert(newLines, replacementLine)
      end
      replaced = true
    else
      table.insert(newLines, line)
    end
  end
  if not replaced and replacementLine ~= "" then
    table.insert(newLines, replacementLine)
  end
  return table.concat(newLines, "\n")
end


--------------------------------------------------------------------------------
-- Check for Random Container header in item notes
--------------------------------------------------------------------------------
local function checkForTagHeader(item)
    -- Validate the media item
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then
        reaper.ShowMessageBox("Invalid media item provided.", "Error", 0)
        return false
    end

    -- Retrieve the current notes of the media item
    local retval, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    
    if not retval then
        reaper.ShowMessageBox("Failed to retrieve item notes.", "Error", 0)
        return false
    end

    -- Define the specific tag header line to search for
    local tagHeaderLine = "#-----------------Random Container-----------------"

    -- Search for the tag header line in the notes
    if notes:find(tagHeaderLine, 1, true) then
        return true
    else
        return false
    end
end

--------------------------------------------------------------------------------
-- Add default Random Container tag block to item notes
--------------------------------------------------------------------------------
local function addDefaultTagBlock(item)
    -- Validate the media item
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then
        return false, "Invalid media item provided."
    end

    -- Retrieve the current notes of the media item
    local retval, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    if not retval then
        return false, "Failed to retrieve item notes."
    end

    -- Define the specific tag header line to search for
    local tagHeaderLine = "#-----------------Random Container-----------------"

    -- Check if the tag header already exists to prevent duplication
    if notes:find(tagHeaderLine, 1, true) then
        return true, "Random Container tag block already exists in the item's notes."
    end

    -- Define the block of text to append
    local tagBlock = [[
#-----------------Random Container-------------------
#---takes---
#rc_enableTakeRandomization(0)
#rc_takeMode(Shuffle)
#rc_takeWeights(100)
#rc_shuffleNoRepeat(1)

#---trigger---
#rc_enableTriggerProbability(0)
#rc_probability(100)

#---offset---
#rc_enableStartOffsetRandomization(0)
#rc_startOffset(0)
#rc_startOffsetRandomizationAmount(0)

#---volume---
#rc_enableVolumeRandomization(0)
#rc_volume(0)
#rc_volumeRandomizationAmount(0)

#---pan---
#rc_enablePanRandomization(0)
#rc_pan(0)
#rc_panRandomizationAmount(0)

#---pitch---
#rc_enablePitchRandomization(0)
#rc_pitchOffsetSemitones(0)
#rc_pitchRandomizationAmount(0)

#---envelopes---
#rc_enableEnvelopeRandomization(0)
#----------------------------------------------------
]]

    -- Ensure there's a newline before appending if notes are not empty
    if #notes > 0 and not notes:match("\n$") then
        notes = notes .. "\n"
    end

    -- Append the tag block to the existing notes
    notes = notes .. tagBlock

    -- Update the media item's notes with the new content
    local set_success = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", notes, true)

    if set_success then
        return true, "Random Container tag block added to the item's notes."
    else
        return false, "Failed to update item notes."
    end
end


--------------------------------------------------------------------------------
-- update Playback Rate when semitone or cent sliders are adjusted            --
--------------------------------------------------------------------------------
-- Function to update playback rate based on pitch offsets in semitones and cents
local function updatePlaybackRate(item)
    if not item then return end

    -- Retrieve the item's notes
    local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)

    -- Extract pitch offsets from notes
    local semitoneOffset = tonumber(notes:match("#rc_pitchOffsetSemitones%((%-?%d+)%)")) or 0

    -- Convert pitch shift to playback rate
    local playbackRate = 2 ^ (semitoneOffset / 12)

    local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local newItemLength = itemLength / playbackRate

    -- Get the active take of the item
    local take = reaper.GetActiveTake(item)
    if not take then return end

    -- Apply the new playback rate
    reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", playbackRate)

    -- Update item length relative to item playback rate
    -- reaper.SetMediaItemInfo_Value(item, "D_LENGTH", newItemLength)

    -- Update the item in the project to apply changes
    reaper.UpdateItemInProject(item)
end


--------------------------------------------------------------------------------
-- applyParametersToItem(item, st, changedParams):
--------------------------------------------------------------------------------
local function applyParametersToItem(item, st, changedParams)
    -- Ensure the item has the Random Container tag block
    if not checkForTagHeader(item) then
        addDefaultTagBlock(item)
    end

    -- Retrieve the current notes
    local _, oldNotes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    local newNotes = oldNotes or ""

    --------------------------------------------------------------------------------
    -- Reset States (Mute, Volume, Pan, Pitch, Start Offset)
    --------------------------------------------------------------------------------

    -- Mute State Reset
    if (changedParams.resetMuteState or st.resetMuteState)
        and not st.enableCycleTracking
        and not st.enableTriggerProbability then
        reaper.SetMediaItemInfo_Value(item, "B_MUTE", 0) -- Unmute the item
    end

    -- Volume Reset
    if (changedParams.resetVolume or st.resetVolume)
        and not st.enableVolumeRandomization then
        reaper.SetMediaItemInfo_Value(item, "D_VOL", 1.0) -- Reset to 0.0 dB (linear scale)
    end

    -- Pan Reset
    if (changedParams.resetPan or st.resetPan)
        and not st.enablePanRandomization then
        local activeTake = reaper.GetActiveTake(item)
        if activeTake then
            reaper.SetMediaItemTakeInfo_Value(activeTake, "D_PAN", 0.0) -- Centered pan
        end
    end

    -- Pitch Reset
    if (changedParams.resetPitch or st.resetPitch)
        and not st.enablePitchRandomization then
        local activeTake = reaper.GetActiveTake(item)
        if activeTake then
            reaper.SetMediaItemTakeInfo_Value(activeTake, "D_PLAYRATE", 1.0) -- Reset playback rate to 1.0
            reaper.SetMediaItemTakeInfo_Value(activeTake, "B_PPITCH", 0)    -- Turn off "Preserve pitch"
        end
    end

    -- Start Offset Reset
    if (changedParams.resetStartOffset or st.resetStartOffset)
        and not st.enableStartOffsetRandomization then
        -- Reset take offset
        if activeTake then
          reaper.SetMediaItemTakeInfo_Value(activeTake, "D_STARTOFFS", 0.0)
        end
    end

    --------------------------------------------------------------------------------
    -- Take Randomization Tags
    --------------------------------------------------------------------------------
    if changedParams.enableTakeRandomization then
        newNotes = setOrReplaceTag(newNotes, "^#rc_enableTakeRandomization%([^)]*%)", 
            string.format("#rc_enableTakeRandomization(%d)", st.enableTakeRandomization and 1 or 0))
    end

    if changedParams.takeMode then
        local modeStrings = { "Shuffle", "Sequential", "Weighted" }
        local modeLine = modeStrings[st.takeMode + 1] or "Shuffle"
        newNotes = setOrReplaceTag(newNotes, "^#rc_takeMode%([^)]*%)", "#rc_takeMode(" .. modeLine .. ")")
    end

    if changedParams.takeWeights then
        if st.takeMode == 2 then -- Only apply weights if in Weighted mode
            local thisItemNumTakes = reaper.CountTakes(item)
            thisItemNumTakes = math.max(thisItemNumTakes, 1)

            local weights = (#st.takeWeights == thisItemNumTakes) and st.takeWeights or {}
            if #weights == 0 then
                local evenWeight = 100.0 / thisItemNumTakes
                for i = 1, thisItemNumTakes do table.insert(weights, evenWeight) end
            end
            local weightLine = "#rc_takeWeights(" .. table.concat(weights, ",") .. ")"
            newNotes = setOrReplaceTag(newNotes, "^#rc_takeWeights%([^)]*%)", weightLine)
        end
    end

    if changedParams.shuffleNoRepeat then
        newNotes = setOrReplaceTag(newNotes, "^#rc_shuffleNoRepeat%([^)]*%)",
            string.format("#rc_shuffleNoRepeat(%d)", math.floor(st.shuffleNoRepeat or 1)))
    end

    --------------------------------------------------------------------------------
    -- Trigger Probability Tags
    --------------------------------------------------------------------------------
    if changedParams.enableTriggerProbability then
        newNotes = setOrReplaceTag(newNotes, "^#rc_enableTriggerProbability%([^)]*%)", 
            string.format("#rc_enableTriggerProbability(%d)", st.enableTriggerProbability and 1 or 0))
    end

    if changedParams.triggerProbability then
        newNotes = setOrReplaceTag(newNotes, "^#rc_probability%([^)]*%)", 
            string.format("#rc_probability(%g)", st.prob))
    end

    --------------------------------------------------------------------------------
    -- Start Offset Randomization Tags
    --------------------------------------------------------------------------------
    if changedParams.enableStartOffsetRandomization then
        -- Update the Start Offset randomization enable tag
        newNotes = setOrReplaceTag(newNotes, "^#rc_enableStartOffsetRandomization%([^)]*%)", 
            string.format("#rc_enableStartOffsetRandomization(%d)", st.enableStartOffsetRandomization and 1 or 0))
    end

    if changedParams.startOffset then
        newNotes = setOrReplaceTag(newNotes, "^#rc_startOffset%([^)]*%)", 
            string.format("#rc_startOffset(%.2f)", st.startOffset))

        -- Update item
        local activeTake = reaper.GetActiveTake(item)
        if not activeTake then return end

        local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local itemPlayrate = reaper.GetMediaItemTakeInfo_Value(activeTake, "D_PLAYRATE")
        local startOffset = (itemLength * (st.startOffset * 0.01)) * itemPlayrate
        reaper.SetMediaItemTakeInfo_Value(activeTake,"D_STARTOFFS", startOffset)
        reaper.UpdateItemInProject(item)

    end

    if changedParams.startOffsetRandAmount then
        newNotes = setOrReplaceTag(newNotes, "^#rc_startOffsetRandomizationAmount%([^)]*%)", 
            string.format("#rc_startOffsetRandomizationAmount(%.2f)", st.offsetRand))
    end

    --------------------------------------------------------------------------------
    -- Volume Randomization Tags
    --------------------------------------------------------------------------------
    if changedParams.enableVolumeRandomization then
        newNotes = setOrReplaceTag(newNotes, "^#rc_enableVolumeRandomization%([^)]*%)", 
            string.format("#rc_enableVolumeRandomization(%d)", st.enableVolumeRandomization and 1 or 0))
    end

    if changedParams.volume then
        newNotes = setOrReplaceTag(newNotes, "^#rc_volume%([^)]*%)", 
            string.format("#rc_volume(%.2f)", st.volume))

        local amplitude = 10 ^ (st.volume  / 20)

        -- Set the item's volume
        reaper.SetMediaItemInfo_Value(item, "D_VOL", amplitude)
        reaper.UpdateItemInProject(item)
    end

    if changedParams.volumeRandAmount then
        newNotes = setOrReplaceTag(newNotes, "^#rc_volumeRandomizationAmount%([^)]*%)", 
            string.format("#rc_volumeRandomizationAmount(%.2f)", st.volumeRandAmount))
    end

    --------------------------------------------------------------------------------
    -- Pan Randomization Tags
    --------------------------------------------------------------------------------
    if changedParams.enablePanRandomization then
        newNotes = setOrReplaceTag(newNotes, "^#rc_enablePanRandomization%([^)]*%)", 
            string.format("#rc_enablePanRandomization(%d)", st.enablePanRandomization and 1 or 0))
    end

    if changedParams.pan then
        newNotes = setOrReplaceTag(newNotes, "^#rc_pan%([^)]*%)", 
            string.format("#rc_pan(%.2f)", st.pan))

        -- Set the item's pan
        local take = reaper.GetActiveTake(item)
        reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", st.pan)
        reaper.UpdateItemInProject(item)
    end

    if changedParams.panRandAmount then
        newNotes = setOrReplaceTag(newNotes, "^#rc_panRandomizationAmount%([^)]*%)", 
            string.format("#rc_panRandomizationAmount(%.2f)", st.panRandAmount))
    end

    --------------------------------------------------------------------------------
    -- Pitch Randomization Tags
    --------------------------------------------------------------------------------
    if changedParams.enablePitchRandomization then
        -- Update or add the pitch randomization enable tag
        newNotes = setOrReplaceTag(newNotes, "^#rc_enablePitchRandomization%([^)]*%)", 
            string.format("#rc_enablePitchRandomization(%d)", st.enablePitchRandomization and 1 or 0))
    end

    -- Example snippet integrating with your GUI editor section
    if changedParams.pitchOffsetSemitones then
        -- Update tags based on slider changes
        if changedParams.pitchOffsetSemitones then
            newNotes = setOrReplaceTag(newNotes, "#rc_pitchOffsetSemitones%((%-?%d+)%)", 
                string.format("#rc_pitchOffsetSemitones(%d)", st.pitchOffsetSemitones))
        end
    
        -- Call the playback rate update function
        updatePlaybackRate(item)
    end


    if changedParams.pitchRandomizationAmount then
        newNotes = setOrReplaceTag(newNotes, "^#rc_pitchRandomizationAmount%([^)]*%)", 
            string.format("#rc_pitchRandomizationAmount(%.2f)", st.pitchRandomizationAmount))
    end

    --------------------------------------------------------------------------------
    -- Envelope Randomization Tags
    --------------------------------------------------------------------------------
    if changedParams.enableEnvelopeRandomization then
        -- Update or add the envelope randomization enable tag
        newNotes = setOrReplaceTag(newNotes, "^#rc_enableEnvelopeRandomization%(%d+%.?%d*%)", 
            string.format("#rc_enableEnvelopeRandomization(%d)", st.enableEnvelopeRandomization and 1 or 0))
    end

    -- Update or add tags for each changed envelope slider
    if state.enableEnvelopeRandomization and state.sliderValues then
        for envelope, value in pairs(changedParams) do
            if envelope ~= "enableEnvelopeRandomization" then
                -- Get the envelope name
                local retval, envelopeName = reaper.GetEnvelopeName(envelope, "")
                if retval then
                    -- Sanitize the envelope name for the tag (replace spaces with underscores and remove non-alphanumerics)
                    local sanitizedName = envelopeName:gsub("%s+", "_"):gsub("[^%w_]", "")
                    
                    -- Create the tag string with floating-point value
                    local tag = string.format("#rc_%s(%.2f)", sanitizedName, value)
                    
                    -- Define the pattern to search for existing tag with optional decimal places
                    local pattern = "^#rc_" .. sanitizedName .. "%(%d+%.?%d*%)"
                    
                    -- Insert or replace the tag using setOrReplaceTag
                    newNotes = setOrReplaceTag(newNotes, pattern, tag)
                end
            end
        end
    end


    --------------------------------------------------------------------------------
    -- Write updated notes back to the item
    --------------------------------------------------------------------------------
    reaper.GetSetMediaItemInfo_String(item, "P_NOTES", newNotes, true)
end


--------------------------------------------------------------------------------
-- applyToSelectedItems(st, changedParams): Writes the changed parameters to ALL selected items.
--------------------------------------------------------------------------------
local function applyToSelectedItems(st, changedParams)
  local cnt = reaper.CountSelectedMediaItems(0)
  if cnt == 0 then return end

  reaper.Undo_BeginBlock2(0)

  for i = 0, cnt - 1 do
    local it = reaper.GetSelectedMediaItem(0, i)
    applyParametersToItem(it, st, changedParams)
  end

  reaper.Undo_EndBlock2(0, "Auto-update Random Container Tags on Items", -1)
  reaper.UpdateArrange()
end

local function mergeTables(dest, src)
    for k, v in pairs(src) do
        dest[k] = v
    end
    return dest
end



------------------------------------------------
-- Take Randomization Section
------------------------------------------------
local function renderTakeRandomizationSection(ctx, changedParams)
    -- Push styles for the checkbox
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)        -- Checkbox Background
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Checkbox Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)  -- Checkbox Active
    ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, 0x48B2A0FF)      -- Checkmark

    -- Render the checkbox
    local enableTakeRandomizationChanged, enableTakeRandomizationNew = ImGui.Checkbox(ctx, "##Take Randomization", state.enableTakeRandomization)
    ImGui.PopStyleColor(ctx, 4) -- Pop the checkbox styles

    if enableTakeRandomizationChanged then
        state.enableTakeRandomization = enableTakeRandomizationNew
        changedParams.enableTakeRandomization = true -- Track this change
    end

    -- Push styles for the heading
    ImGui.SameLine(ctx)
    ImGui.PushFont(ctx, font_Heading)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, headingColor)
    ImGui.SeparatorText(ctx, "Take Randomization")
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop the heading styles

    -- Render the combo box and options if enabled
    ImGui.PushFont(ctx, font_Parameter)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor) -- Parameter text color

    if state.enableTakeRandomization then
        local currentModeLabel = rmodeOptions[state.takeMode + 1] or "Shuffle"

        -- Push styles for the combo box arrow, frame, and popup
        ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x282828FF)        -- Arrow background
        ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x949494FF) -- Arrow hover
        ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x48B2A0FF)  -- Arrow active
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)       -- Combo box background
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Combo box hover
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF) -- Combo box active
        ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x333333FF)       -- Dropdown popup background
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor)          -- Text inside popup
        ImGui.PushStyleColor(ctx, ImGui.Col_Header, 0x48B2A0FF)        -- Highlight background
        ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, 0x949494FF) -- Highlight hover
        ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, 0x50E3C2FF)  -- Highlight when clicked

        if ImGui.BeginCombo(ctx, "Mode", currentModeLabel) then
            for i, label in ipairs(rmodeOptions) do
                -- Adjust comparison for 0-based `state.takeMode`
                local isSelected = ((i - 1) == state.takeMode)
                if ImGui.Selectable(ctx, label, isSelected) then
                    state.takeMode = i - 1 -- Store 0-based index
                    changedParams.takeMode = true -- Track this change
                end
                if isSelected then
                    ImGui.SetItemDefaultFocus(ctx)
                end
            end
            ImGui.EndCombo(ctx)
        end

        -- Pop combo box styles
        ImGui.PopStyleColor(ctx, 11) -- Pop all combo-related styles
        ImGui.Separator(ctx)

        ------------------------------------------------
        -- Weighted Sliders (only show if Weighted)
        ------------------------------------------------
        if state.takeMode == 2 then
            if state.numTakes > 0 then
                -- Push styles for the sliders
                ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)       -- Slider background
                ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Slider hover
                ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF) -- Slider active
                ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrab, 0x48B2A0FF)   -- Slider grab
                ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrabActive, 0x50E3C2FF) -- Slider grab active

                for i = 1, state.numTakes do
                    local label = ("Take #%d"):format(i)
                    local changedW, newVal = ImGui.SliderDouble(ctx, label, 
                        state.takeWeights[i] or 0, 
                        0, 100, 
                        "%.2f%%"
                    )
                    if changedW then
                        state.takeWeights[i] = newVal
                        changedParams.takeWeights = true -- Track this change
                    end
                end

                if changedParams.takeWeights then
                    -- Auto-normalize distribution
                    local sum = 0
                    for _, val in ipairs(state.takeWeights) do sum = sum + val end
                    if sum > 0 then
                        for j = 1, #state.takeWeights do
                            state.takeWeights[j] = state.takeWeights[j] / sum * 100
                        end
                    else
                        local even = 100.0 / state.numTakes
                        for j = 1, state.numTakes do
                            state.takeWeights[j] = even
                        end
                    end
                end

                -- Pop slider styles
                ImGui.PopStyleColor(ctx, 5)
            end
            ImGui.Separator(ctx)
        end

        if state.takeMode == 0 then
            ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)
            ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF)
            ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)
            ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrab, 0x48B2A0FF)
            ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrabActive, 0x50E3C2FF)
            local maxTakes = math.max(state.numTakes, 1)
            local changedNR, newNR = ImGui.SliderInt(ctx, "Repeats", state.shuffleNoRepeat or 1, 1, maxTakes)
            if changedNR then
                state.shuffleNoRepeat = newNR
                changedParams.shuffleNoRepeat = true
            end
            ImGui.PopStyleColor(ctx, 5)
            ImGui.Separator(ctx)
        end
    end

    -- Pop parameter styles
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx)
end


------------------------------------------------
-- Trigger Probability Section
------------------------------------------------
local function renderTriggerProbabilitySection(ctx, changedParams)
    -- Push styles for the checkbox
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)        -- Checkbox Background
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Checkbox Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)  -- Checkbox Active
    ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, 0x48B2A0FF)      -- Checkmark

    -- Render the checkbox
    local enableTriggerChanged, enableTriggerNew = ImGui.Checkbox(ctx, "##Trigger Probability", state.enableTriggerProbability)
    ImGui.PopStyleColor(ctx, 4) -- Pop the checkbox styles

    if enableTriggerChanged then
        state.enableTriggerProbability = enableTriggerNew
        changedParams.enableTriggerProbability = true
    end

    -- Push styles for the heading
    ImGui.SameLine(ctx)
    ImGui.PushFont(ctx, font_Heading)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, headingColor)
    ImGui.SeparatorText(ctx, "Trigger Probability")
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop the heading styles

    -- Render the slider if trigger probability is enabled
    ImGui.PushFont(ctx, font_Parameter)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor) -- Parameter text color

    if state.enableTriggerProbability then
        -- Push styles for the slider
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)        -- Slider background
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Slider hover
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)  -- Slider active
        ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrab, 0x48B2A0FF)     -- Slider grab
        ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrabActive, 0x50E3C2FF) -- Slider grab active

        -- Render the slider
        local probChanged, newProb = ImGui.SliderInt(ctx, "##ProbabilityAmount", state.prob, 0, 100, "%d%%")
        if probChanged then
            state.prob = newProb
            changedParams.triggerProbability = true
        end

        -- Pop slider styles
        ImGui.PopStyleColor(ctx, 5)
        ImGui.Separator(ctx)
    end

    -- Pop parameter styles
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx)
end


------------------------------------------------
-- Start Offset Randomization Section
------------------------------------------------
local function renderStartOffsetRandomizationSection(ctx, changedParams)
    -- Apply styles for the checkbox
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)        -- Checkbox Background
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Checkbox Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)  -- Checkbox Active
    ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, 0x48B2A0FF)      -- Checkmark

    -- Render Start Offset Randomization checkbox
    local enableStartOffsetRandomizationChanged, enableStartOffsetNew = ImGui.Checkbox(ctx, "##Start Offset Randomization", state.enableStartOffsetRandomization)
    ImGui.PopStyleColor(ctx, 4) -- Pop checkbox styles

    if enableStartOffsetRandomizationChanged then
        state.enableStartOffsetRandomization = enableStartOffsetNew
        changedParams.enableStartOffsetRandomization = true
    end

    -- Apply heading styles
    ImGui.SameLine(ctx)
    ImGui.PushFont(ctx, font_Heading)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, headingColor)
    ImGui.SeparatorText(ctx, "Start Offset Randomization")
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop heading styles

    -- Render Start Offset Slider if enabled
    ImGui.PushFont(ctx, font_Parameter)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor)

    if state.enableStartOffsetRandomization then
        ------------------------------------------------
        -- Start Offset Range Sliders
        ------------------------------------------------
        -- Apply slider styles
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)        -- Slider Background
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Slider Hover
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)  -- Slider Active
        ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrab, 0x48B2A0FF)     -- Slider Grab
        ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrabActive, 0x50E3C2FF) -- Slider Grab Active

        -- Render the slider
        ImGui.Text(ctx, "Offset")
        local offsetChanged, newOffset = ImGui.SliderInt(ctx, "##StartOffset", state.startOffset, -100, 100, "%d%%")
        
        if offsetChanged then
            state.startOffset = newOffset
            changedParams.startOffset = true
        end

        -- Render the slider
        ImGui.Text(ctx, "Randomization")
        local offsetRandChanged, newOffsetRand = ImGui.SliderInt(ctx, "##OffsetRand", state.offsetRand, 0, 100, "%d%%")
        
        if offsetRandChanged then
            state.offsetRand = newOffsetRand
            changedParams.startOffsetRandAmount = true
        end


        ImGui.PopStyleColor(ctx, 5) -- Pop slider styles
    end

    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop parameter text styles
end


------------------------------------------------
-- Volume Randomization Section
------------------------------------------------
local function renderVolumeRandomizationSection(ctx, changedParams)
    -- Apply styles for the checkbox
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)        -- Checkbox Background
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Checkbox Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)  -- Checkbox Active
    ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, 0x48B2A0FF)      -- Checkmark

    -- Render Volume Randomization checkbox
    local enableVolumeChanged, enableVolumeNew = ImGui.Checkbox(ctx, "##Volume Randomization", state.enableVolumeRandomization)
    ImGui.PopStyleColor(ctx, 4) -- Pop checkbox styles

    if enableVolumeChanged then
        state.enableVolumeRandomization = enableVolumeNew
        changedParams.enableVolumeRandomization = true
    end

    -- Apply heading styles
    ImGui.SameLine(ctx)
    ImGui.PushFont(ctx, font_Heading)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, headingColor)
    ImGui.SeparatorText(ctx, "Volume Randomization")
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop heading styles

    -- Render Volume Range Sliders if enabled
    ImGui.PushFont(ctx, font_Parameter)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor)

    if state.enableVolumeRandomization then
        ------------------------------------------------
        -- Volume Range Sliders
        ------------------------------------------------
        -- Apply slider styles
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)        -- Slider Background
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Slider Hover
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)  -- Slider Active
        ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrab, 0x48B2A0FF)     -- Slider Grab
        ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrabActive, 0x50E3C2FF) -- Slider Grab Active

        -- Render the randomization amound slider
        ImGui.Text(ctx, "Level")
        local volChanged, volume = ImGui.SliderDouble(ctx, "##Volume", state.volume, -150, 12, "%.2fdB")

        if volChanged then
            state.volume = volume
            changedParams.volume = true
        end

        -- Render the randomization amound slider
        ImGui.Text(ctx, "Randomization")
        local volRandChanged, vRandAmount = ImGui.SliderInt(ctx, "##VolumeRandAmount", state.volumeRandAmount, 0, 100, "%d%%")

        if volRandChanged then
            state.volumeRandAmount = vRandAmount
            changedParams.volumeRandAmount = true
        end

        ImGui.PopStyleColor(ctx, 5) -- Pop slider styles
    end

    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop parameter text styles
end


------------------------------------------------
-- Pan Randomization Section
------------------------------------------------
local function renderPanRandomizationSection(ctx, changedParams)
    -- Apply styles for the checkbox
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)        -- Checkbox Background
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Checkbox Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)  -- Checkbox Active
    ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, 0x48B2A0FF)      -- Checkmark

    -- Render Pan Randomization checkbox
    local enablePanChanged, enablePanNew = ImGui.Checkbox(ctx, "##Pan Randomization", state.enablePanRandomization)
    ImGui.PopStyleColor(ctx, 4) -- Pop checkbox styles

    if enablePanChanged then
        state.enablePanRandomization = enablePanNew
        changedParams.enablePanRandomization = true
    end

    -- Apply heading styles
    ImGui.SameLine(ctx)
    ImGui.PushFont(ctx, font_Heading)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, headingColor)
    ImGui.SeparatorText(ctx, "Pan Randomization")
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop heading styles

    -- Render Pan Range Sliders if enabled
    ImGui.PushFont(ctx, font_Parameter)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor)

    if state.enablePanRandomization then
        ------------------------------------------------
        -- Pan Range Sliders
        ------------------------------------------------
        -- Apply slider styles
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)        -- Slider Background
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Slider Hover
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)  -- Slider Active
        ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrab, 0x48B2A0FF)     -- Slider Grab
        ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrabActive, 0x50E3C2FF) -- Slider Grab Active

        -- Render the pan control slider
        ImGui.Text(ctx, "Pan")
        local panChanged, pan = ImGui.SliderDouble(ctx, "##Pan", state.pan, -1, 1, "%.2f")

        if panChanged then
            state.pan = pan
            changedParams.pan = true
        end

        -- Render the double slider
        ImGui.Text(ctx, "Randomization")
        local panChanged, pnamount = ImGui.SliderInt(ctx, "##PanAmounts", state.panRandAmount, 0, 100, "%d%%")

        if panChanged then
            state.panRandAmount = pnamount
            changedParams.panRandAmount = true
        end

        ImGui.PopStyleColor(ctx, 5) -- Pop slider styles
    end

    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop parameter text styles
end




------------------------------------------------
-- Pitch Randomization Section
------------------------------------------------
-- Declare adjustment flags outside the function to maintain their state across frames
local adjustingSemitones = false
local adjustingCents = false

local function renderPitchRandomizationSection(ctx, changedParams)
    -- Apply styles for the checkbox
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)        -- Checkbox Background
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Checkbox Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)  -- Checkbox Active
    ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, 0x48B2A0FF)      -- Checkmark

    -- Render Pitch Randomization checkbox
    local enablePitchChanged, enablePitchNew = ImGui.Checkbox(ctx, "##Pitch Randomization", state.enablePitchRandomization)
    ImGui.PopStyleColor(ctx, 4) -- Pop checkbox styles

    if enablePitchChanged then
        state.enablePitchRandomization = enablePitchNew
        changedParams.enablePitchRandomization = true
    end

    -- Apply heading styles
    ImGui.SameLine(ctx)
    ImGui.PushFont(ctx, font_Heading)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, headingColor)
    ImGui.SeparatorText(ctx, "Pitch Randomization")
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop heading styles

    -- Render Pitch Randomization section if enabled
    ImGui.PushFont(ctx, font_Parameter)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor)

    if state.enablePitchRandomization then
        ------------------------------------------------
        -- Pitch Offset Sliders
        ------------------------------------------------
        ImGui.Text(ctx, "Offset")

        -- Apply styles for the sliders
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF)
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF)
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF)
        ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrab, 0x48B2A0FF)
        ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrabActive, 0x50E3C2FF)

         -- Semitones Slider with Adjustment Flag
        local semitonesChanged, newSemitones = ImGui.SliderDouble(ctx, "Semitones", state.pitchOffsetSemitones, -48, 48, "%.2fst")
        if semitonesChanged then
            adjustingSemitones = true
            adjustingCents = false -- Ensure Cents slider is not being adjusted
            state.pitchOffsetSemitones = math.floor(newSemitones)
            changedParams.pitchOffsetSemitones = true
        end

        ------------------------------------------------
        -- Pitch Range Sliders
        ------------------------------------------------
        ImGui.Text(ctx, "Randomization")
        local pitchChanged, pamount = ImGui.SliderDouble(ctx, "##PitchAmounts", state.pitchRandomizationAmount, 0, 48, "%.2fst")
        if pitchChanged then
            state.pitchRandomizationAmount = pamount
            changedParams.pitchRandomizationAmount = true
        end

        ImGui.PopStyleColor(ctx, 5) -- Pop slider styles
    end

    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop parameter text styles
end


------------------------------------------------
-- Display Settings Section
------------------------------------------------
local function renderSettingsSection(ctx, changedParams)
    -- Apply styles for the main Settings checkbox
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF) -- Checkbox Background
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Checkbox Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF) -- Checkbox Active
    ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, 0x949494FF) -- Checkmark


    local displaySettingsChanged, displaySettings = ImGui.Checkbox(ctx, "##Settings", state.displaySettings or false)
    ImGui.PopStyleColor(ctx, 4) -- Pop checkbox styles

    if displaySettingsChanged then
        state.displaySettings = displaySettings
    end

    -- Apply heading styles
    ImGui.SameLine(ctx)
    ImGui.PushFont(ctx, font_Heading)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, headingColor)
    ImGui.SeparatorText(ctx, "Settings")
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop heading styles

    -- Render Settings section if enabled
    ImGui.PushFont(ctx, font_Parameter)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor)

    if state.displaySettings then
        ImGui.Text(ctx, "Reset when randomization disabled:")
        ImGui.Indent(ctx, 20)

        -- Define a reusable function to render styled checkboxes
        local function renderStyledCheckbox(label, stateKey, changedParamsKey)
            ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x282828FF) -- Checkbox Background
            ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0x949494FF) -- Checkbox Hover
            ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0x48B2A0FF) -- Checkbox Active
            ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, 0x949494FF) -- Checkmark

            local changed, newValue = ImGui.Checkbox(ctx, label, state[stateKey] or false)
            ImGui.PopStyleColor(ctx, 4) -- Pop checkbox styles

            if changed then
                state[stateKey] = newValue
                changedParams[changedParamsKey] = true
            end
        end

        -- Render individual reset options
        renderStyledCheckbox("Mute", "resetMuteState", "resetMuteState")
        renderStyledCheckbox("Offset", "resetOffset", "resetOffset")
        renderStyledCheckbox("Volume", "resetVolume", "resetVolume")
        renderStyledCheckbox("Pan", "resetPan", "resetPan")
        renderStyledCheckbox("Pitch", "resetPitch", "resetPitch")

        ImGui.Unindent(ctx, 20)
    end

    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx) -- Pop parameter text styles
end


------------------------------------------------
-- Render Pack Take Folder Button
------------------------------------------------
local function renderPackTakeButton(ctx)

    -- Push font for parameter text
    ImGui.PushFont(ctx, font_Parameter)

    -- Push custom colors for the button and its states
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x282828FF)        -- Button Background
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x949494FF) -- Button Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x48B2A0FF)  -- Button Active
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor)          -- Button Text Color

    -- Render the button to implode selected items on same track...
    ImGui.Text(ctx, "Create random container from selected items on...")
    if ImGui.Button(ctx, "Same Track") then
        ImGui.PopFont(ctx)         -- Pop the font
        ImGui.PopStyleColor(ctx, 4) -- Pop the 4 pushed style colors
        reaper.Main_OnCommand(40543, 0)
        return false               -- Signal to close the window
    end

    -- Render the button to implode selected items on same track...
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Across Tracks") then
        ImGui.PopFont(ctx)         -- Pop the font
        ImGui.PopStyleColor(ctx, 4) -- Pop the 4 pushed style colors
        reaper.Main_OnCommand(40438, 0)
        return false               -- Signal to close the window
    end

    -- Add separator when section visible
    ImGui.Separator(ctx)
    
    -- Cleanup for font and style colors if the button is not clicked
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx, 4)    -- Pop the 4 pushed style colors
    return true                    -- Signal to keep the window open

end



------------------------------------------------
-- Render Links Section
------------------------------------------------
function open_url_in_default_browser(url)
    local os_name = reaper.GetOS():lower()

    if string.match(os_name, "windows") then
        os.execute(('start "" "%s"'):format(url))
        return true
    elseif string.match(os_name, "osx64") then -- macOS
        os.execute(('open "%s"'):format(url))
        return true
    elseif string.match(os_name, "macos-arm64") then -- macOS
        os.execute(('open "%s"'):format(url))
        return true
    elseif string.match(os_name, "other") then
        os.execute(('xdg-open "%s"'):format(url))
        return true
    else
        return false
    end
end


local function renderLinkSection(ctx)
    -- Push font for parameter text
    ImGui.PushFont(ctx, font_Parameter)
    ImGui.Separator(ctx)

    -- Push custom colors for the button and its states
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x282828FF)        -- Button Background
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x949494FF) -- Button Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x48B2A0FF)  -- Button Active
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor)          -- Button Text Color

    -- Render the "Open Website" button
    if ImGui.Button(ctx, "Support Developer") then
        ImGui.PopFont(ctx)         -- Pop the font
        ImGui.PopStyleColor(ctx, 4) -- Pop the 4 pushed style colors
        open_url_in_default_browser("https://www.buymeacoffee.com/danielrdehaan")
        return false               -- Signal to close the window
    end

    -- Render the "Open Website" button
    if ImGui.Button(ctx, "Discord Server") then
        ImGui.PopFont(ctx)         -- Pop the font
        ImGui.PopStyleColor(ctx, 4) -- Pop the 4 pushed style colors
        open_url_in_default_browser("https://discord.gg/C9FYD8Qf4g")
        return false               -- Signal to close the window
    end

    -- Render the "Open Website" button
    if ImGui.Button(ctx, "Developer Website") then
        ImGui.PopFont(ctx)         -- Pop the font
        ImGui.PopStyleColor(ctx, 4) -- Pop the 4 pushed style colors
        open_url_in_default_browser("https://www.simplesoundtools.com")
        return false               -- Signal to close the window
    end

    -- Cleanup for font and style colors if the button is not clicked
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx, 4)    -- Pop the 4 pushed style colors
    return true                    -- Signal to keep the window open
end


------------------------------------------------
-- Render Close Button
------------------------------------------------
local function renderCloseSection(ctx)
    -- Push font for parameter text
    ImGui.PushFont(ctx, font_Parameter)
    ImGui.Separator(ctx)

    -- Push custom colors for the button and its states
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x282828FF)        -- Button Background
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x949494FF) -- Button Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x48B2A0FF)  -- Button Active
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor)          -- Button Text Color

    -- Render the "Close" button
    if ImGui.Button(ctx, "Close Window") then
        ImGui.PopFont(ctx)         -- Pop the font
        ImGui.PopStyleColor(ctx, 4) -- Pop the 4 pushed style colors
        return false               -- Signal to close the window
    end

    -- Cleanup for font and style colors if the button is not clicked
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx, 4)    -- Pop the 4 pushed style colors
    return true                    -- Signal to keep the window open
end


-- Function to convert Reaper's amplitude value to decibels (dB)
function amplitudeToDb(A)
    -- Define the minimum and maximum dB values
    local MIN_DB = -150
    local MAX_DB = 12

    -- Handle non-positive amplitude values by setting to minimum dB
    if A <= 0 then
        return MIN_DB
    end

    -- Calculate the base-10 logarithm of the amplitude
    -- Lua's math.log(x) computes the natural logarithm (base e), so we convert it to base 10
    local db = 20 * (math.log(A) / math.log(10))

    -- Clamp the dB value to the specified range
    if db < MIN_DB then
        db = MIN_DB
    elseif db > MAX_DB then
        db = MAX_DB
    end

    return db
end

-- Function to convert playrate to semitones
function playrate_to_semitones(playrate)
    if playrate <= 0 then
        -- Invalid playrate value
        return nil
    end

    -- Calculate total semitones using logarithm base 2
    local total_semitones = 12 * math.log(playrate) / math.log(2)

    return total_semitones
end


------------------------------------------------
-- Get Item Parameters
------------------------------------------------
local lastUpdateTime = 0
local debounceInterval = 0.05 -- 50 milliseconds

local function getItemParams(last)
    local currentTime = reaper.time_precise()
    if currentTime - lastUpdateTime < debounceInterval then
        return
    end
    
    lastUpdateTime = currentTime

    if last then

        -- Get item's active take
        local take = reaper.GetActiveTake(last)

        -- Get item volume
        local itemVol = amplitudeToDb(reaper.GetMediaItemInfo_Value(last, "D_VOL"))
        if state.volume ~= itemVol then
            state.volume = itemVol
        end
        
        -- Get item pan
        local itemPan = reaper.GetMediaItemTakeInfo_Value(take, "D_PAN")
        if state.pan ~= itemPan then
            state.pan = itemPan
        end

        -- Get item start offset
        local itemStartOffset = 100 * reaper.GetMediaItemTakeInfo_Value(take,"D_STARTOFFS")

        if itemStartOffset < -100 then
            itemStartOffset = -100
        elseif itemStartOffset > 100 then
            itemStartOffset = 100
        end

        if state.startOffset ~= round(itemStartOffset) then
            state.startOffset = round(itemStartOffset)
        end

        -- Get item playback rate and convert to semitone and cents
        local itemPlayRate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
        local semitones = playrate_to_semitones(itemPlayRate)

        state.pitchOffsetSemitones = semitones or state.pitchOffsetSemitones

    end
end

-- Define the toggle state outside the function to persist between frames
local scriptActive = false

local function renderScriptActivationButton(ctx)
  
  -- Push font for parameter text
  ImGui.PushFont(ctx, font_Parameter)
  ImGui.Separator(ctx)
  
  -- Define colors based on the toggle state
  if scriptActive then
    -- Colors when active
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x48B2A0FF)        -- Active Button Background
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x5FD7BDFF) -- Active Button Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x3AA38BFF)  -- Active Button Pressed
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor)          -- Button Text Color
  else
    -- Colors when inactive
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x282828FF)        -- Inactive Button Background
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x949494FF) -- Inactive Button Hover
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x3C3C3CFF)  -- Inactive Button Pressed
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, paramColor)          -- Button Text Color
  end
  
  -- Set the button label based on the toggle state
  local buttonLabel = scriptActive and "Active" or "Inactive"
  
  -- Render the toggle button
  ImGui.Text(ctx,"Playback Monitoring: ")
  ImGui.SameLine(ctx)
  local buttonClicked = ImGui.Button(ctx, buttonLabel)
  
  -- Handle button click to toggle the state
  if buttonClicked then
    scriptActive = not scriptActive
    -- Add any additional logic you need when toggling
    if scriptActive then
      startPlaybackMonitoring()
    else
      stopPlaybackMonitoring()
    end
  end
  
  -- Cleanup: pop the font and style colors
  ImGui.PopFont(ctx)
  ImGui.PopStyleColor(ctx, 4)    -- Pop the 4 pushed style colors
  
end


------------------------------------------------
-- Main GUI Function
------------------------------------------------
local function MainLoop()
    -- Initialize changedParams table
    local changedParams = {}

    -- Check how many items are selected
    local selCount = reaper.CountSelectedMediaItems(0)

    -- Update state if items are selected
    if selCount > 0 then
        local last = reaper.GetSelectedMediaItem(0, selCount - 1)
        if last ~= state.lastItem then
            -- Update selected item and its parameters
            state.lastItem = last
            state.numTakes = math.max(reaper.CountTakes(last), 1)
            local _, notes = reaper.GetSetMediaItemInfo_String(last, "P_NOTES", "", false)
            state = mergeTables(state, parseItemNotes(notes, state.numTakes))
        end
        -- getItemParams(last)
    else
        state.lastItem = nil
        state.numTakes = 0
    end

    -- Begin ImGui frame
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, 0x333333FF)
    local visible, open = ImGui.Begin(ctx, "DRD_Random Container Editor", true)
    ImGui.PopStyleColor(ctx)

    if visible then
        -- Spacebar Detection: Check if spacebar is pressed this frame
        if ImGui.IsKeyPressed(ctx, reaper.ImGui_Key_Space()) then
            reaper.Main_OnCommand(40044,0)
        end

        if ImGui.IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
          open = false
        end

        -- Title Section
        ImGui.PushFont(ctx, font_Title)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, headingColor)
        ImGui.Text(ctx, "Random Container Editor")
        ImGui.PopStyleColor(ctx)
        ImGui.PopFont(ctx)

        renderScriptActivationButton(ctx)

        -- Check if items are selected
        if selCount > 0 then
            renderPackTakeButton(ctx)
            renderTakeRandomizationSection(ctx, changedParams)
            renderTriggerProbabilitySection(ctx, changedParams)
            renderStartOffsetRandomizationSection(ctx, changedParams)
            renderVolumeRandomizationSection(ctx, changedParams)
            renderPanRandomizationSection(ctx, changedParams)
            renderPitchRandomizationSection(ctx, changedParams)
            -- renderSettingsSection(ctx, changedParams)
        else
            ImGui.PushFont(ctx, font_Parameter)
            ImGui.PushStyleColor(ctx, ImGui.Col_Text, headingColor)
            ImGui.Text(ctx, "No item(s) selected.")
            ImGui.PopStyleColor(ctx)
            ImGui.PopFont(ctx)
        end

        
        renderLinkSection(ctx)

        -- Render close button and check if the window should remain open
        if not renderCloseSection(ctx) then
            ImGui.End(ctx) -- End the ImGui frame before returning
            return
        end

        ImGui.End(ctx)
    end

    -- Handle closing or re-running the loop
    if not open then
        return
    else
        -- Apply changes if any were made
        for _ in pairs(changedParams) do
            applyToSelectedItems(state, changedParams)
            break
        end

        -- Reset adjustment flags
        adjustingSemitones = false
        adjustingCents = false

        reaper.defer(MainLoop)
    end
end


--------------------------------------------------------------------------------
-- 6) Start the GUI script
--------------------------------------------------------------------------------
reaper.defer(MainLoop)