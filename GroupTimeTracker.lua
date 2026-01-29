
--[[
    ENHANCED TIME TRACKER SYSTEM
    ============================
    Purpose: Tracks in-game time for specific group ranks and generates weekly reports
    Features:
    - Real-time time tracking for group members
    - Weekly Discord reports with rankings
    - GUI interface for players
    - Data persistence with backup system
    - Rate limiting and error handling
    
    Author: [evilmafia111]
    Version: 3.0
    Last Updated: [1/30/26]
--]]

-- Services
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- Configuration Constants
local GROUP_ID = 269811162                 -- Roblox group ID to track
local GUARD_RANK = 0                      -- Minimum rank to track
local COMMAND_PREFIX = "!"                 -- Chat command prefix
local DATASTORE_NAME = "GroupTimeTracker_Guard_V3"  -- DataStore name
local RESET_DAY = 7                        -- Day of week to reset (0=Sun, 7=Sun)

-- Discord Integration
local DISCORD_WEBHOOK_URL = ""            -- Set this in production

-- Performance & Safety Constants
local MAX_DATASTORE_RETRIES = 5           -- Max retry attempts for DataStore operations
local RETRY_DELAY = 5                     -- Base delay between retries (exponential backoff)
local MAX_REQUESTS_PER_MINUTE = 30        -- DataStore rate limit (Roblox default)
local CACHE_DURATION = 90                 -- Rank cache TTL in seconds
local SAVE_COOLDOWN = 60                  -- Minimum time between saves
local AUTO_SAVE_INTERVAL = 900            -- Auto-save interval (15 minutes)
local COMMAND_COOLDOWN = 10               -- Command cooldown per player
local RESET_BUFFER = 3600                 -- Buffer time after reset for report sending (1 hour)

-- State Management Variables
local requestCount = 0                    -- Tracks DataStore requests for rate limiting
local lastResetTime = os.time()           -- Last rate limit reset time
local lastSaveTime = 0                    -- Last successful save time
local pendingSave = false                 -- Flag for pending save operations
local sessionCache = {}                   -- Cache for player rank checks
local commandCooldowns = {}               -- Player command cooldowns
local weeklyData = {                      -- Current week's tracking data
    startTime = nil,                      -- Week start timestamp
    endTime = nil,                        -- Week end timestamp
    playerTimes = {}                      -- Player time records: {userId = {name, time, rank}}
}
local activeSessions = {}                 -- Currently online players: {userId = joinTime}
local dirtyPlayers = {}                   -- Players with unsaved changes
local initialLoadComplete = false         -- Safety flag for initial data load

-- DataStore request queue for rate limiting
local requestQueue = {}                   -- Queue of pending DataStore operations
local processingQueue = false             -- Flag indicating queue is being processed

print("Enhanced Time Tracker System Started")

--[[
    PROCESS REQUEST QUEUE
    ====================
    Processes DataStore operations sequentially with rate limiting
    Prevents exceeding Roblox DataStore API limits
--]]
local function processRequestQueue()
    if processingQueue or #requestQueue == 0 then
        return
    end
    
    processingQueue = true
    
    -- Process each queued request
    while #requestQueue > 0 do
        local request = table.remove(requestQueue, 1)
        local currentTime = os.time()
        
        -- Reset request counter if minute has passed
        if currentTime - lastResetTime >= 60 then
            requestCount = 0
            lastResetTime = currentTime
        end
        
        -- Wait if rate limit reached
        if requestCount >= MAX_REQUESTS_PER_MINUTE then
            local waitTime = 60 - (currentTime - lastResetTime)
            print(string.format("DataStore rate limit reached. Queueing %d requests, waiting %d seconds...", 
                #requestQueue + 1, waitTime))
            task.wait(waitTime + 1)  -- task.wait is preferred over wait()
            requestCount = 0
            lastResetTime = os.time()
        end
        
        -- Execute the DataStore operation with pcall for error handling
        local success, result = pcall(request.operation, unpack(request.args))
        requestCount = requestCount + 1
        
        -- Call callback if provided
        if request.callback then
            request.callback(success, result)
        end
        
        task.wait(0.1)  -- Small delay between operations
    end
    
    processingQueue = false
end

--[[
    QUEUE DATASTORE OPERATION
    =========================
    Adds DataStore operations to the processing queue
    Ensures all DataStore calls go through rate limiting
    
    Parameters:
    - operation: Function to execute
    - callback: Optional callback function(success, result)
    - ...: Arguments for the operation
--]]
local function queueDataStoreOperation(operation, callback, ...)
    table.insert(requestQueue, {
        operation = operation,
        args = {...},
        callback = callback
    })
    
    -- Start processing if not already running
    if not processingQueue then
        task.spawn(processRequestQueue)  -- task.spawn is preferred over spawn()
    end
end

--[[
    GET CACHED SESSION
    ==================
    Retrieves cached player data if still valid
    
    Parameters:
    - userId: Player's UserId
    
    Returns:
    - Cached data or nil if expired/not found
--]]
local function getCachedSession(userId)
    if sessionCache[userId] and os.time() - sessionCache[userId].timestamp < CACHE_DURATION then
        return sessionCache[userId].data
    end
    return nil
end

--[[
    SET CACHED SESSION
    ==================
    Caches player data with timestamp
    
    Parameters:
    - userId: Player's UserId
    - data: Data to cache
--]]
local function setCachedSession(userId, data)
    sessionCache[userId] = {
        data = data,
        timestamp = os.time()
    }
end

--[[
    SAFE DATASTORE OPERATION
    ========================
    Wraps DataStore operations with retry logic and rate limiting
    
    Parameters:
    - operation: DataStore function to call
    - ...: Arguments for the operation
    
    Returns:
    - success: Boolean indicating operation success
    - result: Operation result or error message
--]]
local function safeDataStoreOperation(operation, ...)
    local retries = 0
    local lastError
    
    while retries < MAX_DATASTORE_RETRIES do
        local currentTime = os.time()
        
        -- Reset request counter if minute has passed
        if currentTime - lastResetTime >= 60 then
            requestCount = 0
            lastResetTime = currentTime
        end
        
        -- Wait if rate limit reached
        if requestCount >= MAX_REQUESTS_PER_MINUTE then
            local waitTime = 60 - (currentTime - lastResetTime)
            task.wait(waitTime + 1)
            requestCount = 0
            lastResetTime = os.time()
        end
        
        -- Attempt operation with error handling
        local success, result = pcall(operation, ...)
        
        if success then
            requestCount = requestCount + 1
            return true, result
        else
            lastError = result
            retries = retries + 1
            
            -- Log non-rate-limit errors
            if not string.find(tostring(result), "RequestLimitReached") then
                print(string.format("DataStore operation failed (attempt %d/%d): %s", 
                    retries, MAX_DATASTORE_RETRIES, tostring(result)))
            end
            
            -- Exponential backoff for retries
            if retries < MAX_DATASTORE_RETRIES then
                task.wait(RETRY_DELAY * math.pow(2, retries - 1))
            end
        end
    end
    
    return false, lastError
end

--[[
    FORMAT TIME
    ===========
    Converts seconds to HH:MM:SS format
    
    Parameters:
    - seconds: Time in seconds
    
    Returns:
    - Formatted time string
--]]
local function formatTime(seconds)
    if not seconds or type(seconds) ~= "number" then
        return "00:00:00"
    end
    seconds = math.max(0, seconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local seconds = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

--[[
    FORMAT DATE
    ===========
    Converts timestamp to readable date format
    
    Parameters:
    - timestamp: Unix timestamp
    
    Returns:
    - Formatted date string
--]]
local function formatDate(timestamp)
    if not timestamp or type(timestamp) ~= "number" then
        return "Unknown"
    end
    return os.date("%Y-%m-%d %H:%M", timestamp)
end

--[[
    FORMAT COUNTDOWN
    ================
    Converts seconds to countdown format (days, hours, minutes, seconds)
    
    Parameters:
    - seconds: Time in seconds
    
    Returns:
    - Formatted countdown string
--]]
local function formatCountdown(seconds)
    if not seconds or type(seconds) ~= "number" then
        return "00:00:00"
    end
    seconds = math.max(0, seconds)
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local seconds = math.floor(seconds % 60)
    
    if days > 0 then
        return string.format("%dd %02dh %02dm %02ds", days, hours, minutes, seconds)
    else
        return string.format("%02dh %02dm %02ds", hours, minutes, seconds)
    end
end

--[[
    HAS GUARD RANK
    ==============
    Checks if player has required minimum rank in group
    
    Parameters:
    - userId: Player's UserId
    
    Returns:
    - Boolean indicating if player meets rank requirement
--]]
local function hasGuardRank(userId)
    -- Check cache first
    local cached = getCachedSession(userId)
    if cached and cached.rankCheck then
        return cached.rankCheck >= GUARD_RANK
    end
    
    -- Get player instance
    local player = Players:GetPlayerByUserId(userId)
    if not player then return false end
    
    -- Get player's rank in group
    local success, result = pcall(function()
        return player:GetRankInGroup(GROUP_ID)
    end)
    
    if success then
        -- Cache result for future checks
        setCachedSession(userId, {rankCheck = result})
        return result >= GUARD_RANK
    else
        -- Handle API errors (including rate limits)
        if not string.find(tostring(result), "429") then
            print("Error checking rank for user " .. userId .. ": " .. tostring(result))
        end
        return false
    end
end

--[[
    GET PLAYER RANK NAME
    ====================
    Gets the role/rank name of a player in the group
    
    Parameters:
    - userId: Player's UserId
    
    Returns:
    - Rank name string
--]]
local function getPlayerRankName(userId)
    local player = Players:GetPlayerByUserId(userId)
    if not player then return "Unknown" end
    
    local success, result = pcall(function()
        return player:GetRoleInGroup(GROUP_ID)
    end)
    
    if success then
        return result
    end
    return "Unknown"
end

--[[
    CALCULATE WEEK BOUNDARIES
    =========================
    Calculates start and end timestamps for current tracking week
    
    Returns:
    - startOfWeek: Unix timestamp for week start
    - endOfWeek: Unix timestamp for week end
--]]
local function calculateWeekBoundaries()
    local now = os.time()
    local currentDay = tonumber(os.date("%w", now))  -- 0=Sunday, 6=Saturday
    
    -- Adjust for Sunday=0 or Sunday=7
    local resetDay = RESET_DAY == 7 and 0 or RESET_DAY
    local daysSinceReset = (currentDay - resetDay) % 7
    if daysSinceReset < 0 then daysSinceReset = daysSinceReset + 7 end
    
    -- Calculate start of week
    local startOfWeek = now - (daysSinceReset * 86400)
    local date = os.date("*t", startOfWeek)
    date.hour = 0
    date.min = 0
    date.sec = 0
    startOfWeek = os.time(date)
    
    -- Calculate end of week (end of day)
    local endOfWeek = startOfWeek + (7 * 86400) - 1
    
    return startOfWeek, endOfWeek
end

--[[
    GET CURRENT PLAYER TIME
    =======================
    Calculates total tracked time for a player including current session
    
    Parameters:
    - userId: Player's UserId
    
    Returns:
    - Total time in seconds
--]]
local function getCurrentPlayerTime(userId)
    if not weeklyData.playerTimes or not weeklyData.playerTimes[userId] then
        return 0
    end
    
    local totalTime = weeklyData.playerTimes[userId].time or 0
    
    -- Add active session time if player is online
    if activeSessions[userId] then
        totalTime = totalTime + (os.time() - activeSessions[userId])
    end
    
    return totalTime
end

--[[
    SAVE WEEKLY DATA
    ================
    Saves current week's data to DataStore with backup
    
    Returns:
    - Boolean indicating save success
--]]
local function saveWeeklyData()
    -- Prevent saves before initial load
    if not initialLoadComplete then
        print("Save attempted before initial load complete, skipping...")
        return false
    end
    
    local currentTime = os.time()
    
    -- Cooldown enforcement
    if currentTime - lastSaveTime < SAVE_COOLDOWN and not pendingSave then
        pendingSave = true
        task.delay(SAVE_COOLDOWN - (currentTime - lastSaveTime), function()
            pendingSave = false
            saveWeeklyData()
        end)
        return false
    end
    
    pendingSave = false
    
    -- Update active sessions before saving
    for userId, startTime in pairs(activeSessions) do
        if weeklyData.playerTimes and weeklyData.playerTimes[userId] then
            local sessionTime = os.time() - startTime
            weeklyData.playerTimes[userId].time = (weeklyData.playerTimes[userId].time or 0) + sessionTime
            activeSessions[userId] = os.time()
            dirtyPlayers[userId] = true
        end
    end
    
    -- Prepare data for saving
    local saveData = {
        startTime = weeklyData.startTime,
        endTime = weeklyData.endTime,
        playerTimes = {},
        version = 3,
        savedAt = os.time()
    }
    
    -- Convert player times table
    if weeklyData.playerTimes then
        for userId, playerData in pairs(weeklyData.playerTimes) do
            if userId and playerData and type(userId) == "number" then
                if dirtyPlayers[userId] or (playerData.time or 0) > 0 then
                    saveData.playerTimes[tostring(userId)] = {
                        name = playerData.name or "Unknown",
                        time = playerData.time or 0,
                        rank = playerData.rank or "Unknown",
                        lastUpdated = os.time()
                    }
                    dirtyPlayers[userId] = nil
                end
            end
        end
    end
    
    -- Initialize DataStores
    local dataStore = DataStoreService:GetDataStore(DATASTORE_NAME)
    local backupStore = DataStoreService:GetDataStore(DATASTORE_NAME .. "_Backup")
    
    -- Save to primary DataStore
    local success, err = safeDataStoreOperation(function()
        dataStore:SetAsync("weeklyData", saveData)
        
        -- Create backup in separate coroutine
        task.spawn(function()
            local backupSuccess = pcall(function()
                backupStore:SetAsync("backup_" .. os.date("%Y%m%d"), saveData)
            end)
            if backupSuccess then
                print("Backup saved successfully")
            end
        end)
    end)
    
    if success then
        lastSaveTime = os.time()
        local playerCount = 0
        for _ in pairs(saveData.playerTimes) do
            playerCount = playerCount + 1
        end
        print(string.format("Weekly data saved successfully at %s. Players: %d", 
            os.date("%H:%M:%S"), playerCount))
        return true
    else
        print("Failed to save weekly data: " .. tostring(err))
        
        -- Emergency save for rate limit situations
        if string.find(tostring(err), "RequestLimitReached") then
            print("DataStore throttled, using emergency save...")
            task.spawn(function()
                task.wait(30)
                local emergencySuccess = pcall(function()
                    local emergencyStore = DataStoreService:GetOrderedDataStore(DATASTORE_NAME .. "_Emergency")
                    emergencyStore:SetAsync("emergency_save", {
                        timestamp = os.time(),
                        playerCount = #Players:GetPlayers()
                    })
                end)
                if emergencySuccess then
                    print("Emergency save completed")
                end
            end)
        end
        
        return false
    end
end

--[[
    DEBOUNCED SAVE
    ==============
    Throttles save requests to prevent excessive DataStore calls
--]]
local saveDebounce = false
local function debouncedSave()
    if saveDebounce then return end
    saveDebounce = true
    
    task.spawn(function()
        task.wait(2)
        saveWeeklyData()
        saveDebounce = false
    end)
end

--[[
    SEND WEEKLY REPORT TO DISCORD
    =============================
    Formats and sends weekly report to configured Discord webhook
    
    Returns:
    - Boolean indicating send success
--]]
local function sendWeeklyReportToDiscord()
    -- Validate webhook configuration
    if not DISCORD_WEBHOOK_URL or DISCORD_WEBHOOK_URL == "" then
        print("Discord webhook not configured, skipping report")
        return false
    end
    
    -- Skip in Studio for testing
    if RunService:IsStudio() then
        print("Studio mode: Skipping Discord report")
        return false
    end
    
    -- Validate data availability
    if not weeklyData.playerTimes then
        print("No player data available for Discord report")
        return false
    end
    
    -- Prepare player data for sorting
    local sortedPlayers = {}
    local playerCount = 0
    
    for userId, data in pairs(weeklyData.playerTimes) do
        if data and data.name and data.time then
            table.insert(sortedPlayers, {
                name = data.name,
                time = data.time,
                rank = data.rank or "Unknown"
            })
            playerCount = playerCount + 1
        end
    end
    
    -- Sort by time descending
    table.sort(sortedPlayers, function(a, b) 
        return a.time > b.time 
    end)
    
    -- Create Discord embeds
    local embeds = {}
    
    -- Summary embed
    local summaryEmbed = {
        title = "📊 Weekly Time Tracking Report - COMPLETE",
        color = 3447003,  -- Blue color
        fields = {},
        footer = {
            text = "Automated Report • " .. os.date("%Y-%m-%d %H:%M:%S")
        }
    }
    
    local startTimeText = weeklyData.startTime and formatDate(weeklyData.startTime) or "Unknown"
    local endTimeText = weeklyData.endTime and formatDate(weeklyData.endTime) or "Unknown"
    
    table.insert(summaryEmbed.fields, {
        name = "📅 Period",
        value = startTimeText .. " to " .. endTimeText,
        inline = false
    })
    
    -- Calculate totals
    local totalTime = 0
    for _, player in pairs(sortedPlayers) do
        totalTime = totalTime + (player.time or 0)
    end
    
    local averageTime = playerCount > 0 and (totalTime / playerCount) or 0
    
    table.insert(summaryEmbed.fields, {
        name = "📈 Summary",
        value = string.format(
            "**Total Players:** %d\n**Total Time:** %s\n**Average Time:** %s",
            playerCount, 
            formatTime(totalTime),
            formatTime(averageTime)
        ),
        inline = false
    })
    
    table.insert(embeds, summaryEmbed)
    
    -- Player ranking embeds (split into chunks for Discord limits)
    if playerCount > 0 then
        local chunks = {}
        for i = 1, playerCount, 20 do  -- Discord limit: 25 fields per embed
            local chunk = {}
            for j = i, math.min(i + 19, playerCount) do
                table.insert(chunk, sortedPlayers[j])
            end
            table.insert(chunks, chunk)
        end
        
        -- Create embed for each chunk
        for chunkIndex, chunk in ipairs(chunks) do
            local embed = {
                title = string.format("🏆 Player Rankings (%d/%d)", chunkIndex, #chunks),
                color = 15105570,  -- Orange color
                fields = {},
                footer = {
                    text = string.format("Page %d/%d • Total Players: %d", chunkIndex, #chunks, playerCount)
                }
            }
            
            -- Format player list for this chunk
            local playersText = ""
            for i, player in ipairs(chunk) do
                local globalIndex = (chunkIndex - 1) * 20 + i
                local medal = ""
                if globalIndex == 1 then medal = "🥇 "
                elseif globalIndex == 2 then medal = "🥈 "
                elseif globalIndex == 3 then medal = "🥉 "
                else medal = "**" .. globalIndex .. ".** " end
                
                playersText = playersText .. string.format(
                    "%s%s (%s) - `%s`\n",
                    medal, 
                    player.name or "Unknown", 
                    player.rank or "Unknown", 
                    formatTime(player.time or 0)
                )
            end
            
            table.insert(embed.fields, {
                name = string.format("Players %d-%d", (chunkIndex - 1) * 20 + 1, (chunkIndex - 1) * 20 + #chunk),
                value = playersText,
                inline = false
            })
            
            table.insert(embeds, embed)
        end
    else
        -- No data embed
        local noDataEmbed = {
            title = "❌ No Player Data",
            color = 15158332,  -- Red color
            description = "No players were tracked this week.",
            footer = {
                text = "No Data • " .. os.date("%Y-%m-%d %H:%M:%S")
            }
        }
        table.insert(embeds, noDataEmbed)
    end
    
    -- Prepare Discord webhook payload
    local payload = {
        embeds = embeds,
        username = "Time Tracker Bot",
        avatar_url = "https://i.imgur.com/6JqQZ7y.png"  -- Consider replacing with your own image
    }
    
    -- Send to Discord
    local success, result = pcall(function()
        HttpService:PostAsync(DISCORD_WEBHOOK_URL, HttpService:JSONEncode(payload))
    end)
    
    if success then
        print("Complete weekly report sent to Discord! (" .. #embeds .. " embeds, " .. playerCount .. " players)")
        return true
    else
        print("Failed to send Discord report: " .. tostring(result))
        return false
    end
end

--[[
    LOAD WEEKLY DATA
    ================
    Loads weekly data from DataStore, initializes new week if needed
    Includes backup recovery system
--]]
local function loadWeeklyData()
    local dataStore = DataStoreService:GetDataStore(DATASTORE_NAME)
    local backupStore = DataStoreService:GetDataStore(DATASTORE_NAME .. "_Backup")
    
    -- Helper function to load data from any store
    local function loadFromStore(store, isBackup)
        local success, data = safeDataStoreOperation(function()
            return store:GetAsync(isBackup and "backup_" .. os.date("%Y%m%d") or "weeklyData")
        end)
        
        if success and data then
            -- Convert string keys to numbers for consistency
            if data.playerTimes then
                local convertedPlayerTimes = {}
                for userIdStr, playerData in pairs(data.playerTimes) do
                    local userId = tonumber(userIdStr)
                    if userId and playerData then
                        convertedPlayerTimes[userId] = {
                            name = playerData.name or "Unknown",
                            time = playerData.time or 0,
                            rank = playerData.rank or "Unknown"
                        }
                    end
                end
                data.playerTimes = convertedPlayerTimes
            end
            
            -- Validate data structure
            if data.startTime and data.endTime and data.playerTimes then
                return data
            end
        end
        return nil
    end
    
    -- Try primary store first
    local data = loadFromStore(dataStore, false)
    
    -- Fallback to backup if primary fails
    if not data then
        print("Primary load failed, trying backup...")
        data = loadFromStore(backupStore, true)
    end
    
    if data then
        weeklyData = data
        print("Weekly data loaded successfully")
        
        -- Check if week reset is needed
        local currentTime = os.time()
        local isFreshSession = RunService:IsStudio() and currentTime - (weeklyData.endTime or 0) > 86400
        
        if isFreshSession or (weeklyData.endTime and currentTime > (weeklyData.endTime + RESET_BUFFER)) then
            print("Week reset detected")
            
            -- Send final report before reset (in production only)
            if not isFreshSession and not RunService:IsStudio() then
                task.spawn(function()
                    task.wait(10)
                    sendWeeklyReportToDiscord()
                end)
            end
            
            -- Reset for new week
            weeklyData.startTime, weeklyData.endTime = calculateWeekBoundaries()
            weeklyData.playerTimes = {}
            dirtyPlayers = {}
            
            -- Save new week data
            task.spawn(function()
                task.wait(30)
                saveWeeklyData()
            end)
            
            print("Weekly data reset for new week")
        end
    else
        -- Initialize first week
        print("No existing data found, initializing new week")
        weeklyData.startTime, weeklyData.endTime = calculateWeekBoundaries()
        weeklyData.playerTimes = {}
        
        -- Initial save
        if not RunService:IsStudio() then
            task.spawn(function()
                task.wait(60)
                saveWeeklyData()
            end)
        end
        print("New weekly data initialized")
    end
    
    initialLoadComplete = true
end

--[[
    SHOW TIME RECORDS
    =================
    Creates and displays GUI with time tracking information for a player
    
    Parameters:
    - player: Player instance to show GUI to
--]]
local function showTimeRecords(player)
    print("Showing time records for player: " .. player.Name)
    
    -- Remove existing GUI if present
    if player.PlayerGui:FindFirstChild("TimeTrackerGUI") then
        player.PlayerGui.TimeTrackerGUI:Destroy()
    end
    
    -- Create main GUI container
    local gui = Instance.new("ScreenGui")
    gui.Name = "TimeTrackerGUI"
    gui.Parent = player.PlayerGui
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    
    -- Main frame with responsive sizing
    local mainFrame = Instance.new("Frame")
    mainFrame.Name = "MainFrame"
    mainFrame.Parent = gui
    mainFrame.Size = UDim2.new(0.7, 0, 0.65, 0)
    mainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
    mainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
    mainFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
    mainFrame.BorderSizePixel = 0
    mainFrame.ClipsDescendants = true
    
    -- Responsive constraints
    local aspectRatioConstraint = Instance.new("UIAspectRatioConstraint")
    aspectRatioConstraint.AspectRatio = 1.5
    aspectRatioConstraint.Parent = mainFrame
    
    local sizeConstraint = Instance.new("UISizeConstraint")
    sizeConstraint.MinSize = Vector2.new(300, 280)
    sizeConstraint.MaxSize = Vector2.new(500, 450)
    sizeConstraint.Parent = mainFrame
    
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = mainFrame
    
    -- Header section
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Parent = mainFrame
    header.Size = UDim2.new(1, 0, 0.2, 0)
    header.Position = UDim2.new(0, 0, 0, 0)
    header.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
    header.BorderSizePixel = 0
    
    local headerCorner = Instance.new("UICorner")
    headerCorner.CornerRadius = UDim.new(0, 8)
    headerCorner.Parent = header
    
    -- Title label
    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Parent = header
    title.Size = UDim2.new(0.8, 0, 0.3, 0)
    title.Position = UDim2.new(0.1, 0, 0.1, 0)
    title.BackgroundTransparency = 1
    title.Text = "WEEKLY TIME TRACKER"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Font = Enum.Font.GothamBold
    title.TextScaled = true
    
    -- Period display
    local period = Instance.new("TextLabel")
    period.Name = "Period"
    period.Parent = header
    period.Size = UDim2.new(0.8, 0, 0.2, 0)
    period.Position = UDim2.new(0.1, 0, 0.4, 0)
    period.BackgroundTransparency = 1
    period.Text = "Period: " .. formatDate(weeklyData.startTime) .. " to " .. formatDate(weeklyData.endTime)
    period.TextColor3 = Color3.fromRGB(200, 200, 200)
    period.TextXAlignment = Enum.TextXAlignment.Left
    period.Font = Enum.Font.Gotham
    period.TextSize = 12
    period.TextWrapped = true
    
    -- Countdown to reset
    local countdownLabel = Instance.new("TextLabel")
    countdownLabel.Name = "CountdownLabel"
    countdownLabel.Parent = header
    countdownLabel.Size = UDim2.new(0.8, 0, 0.2, 0)
    countdownLabel.Position = UDim2.new(0.1, 0, 0.65, 0)
    countdownLabel.BackgroundTransparency = 1
    countdownLabel.Text = "Next reset: Calculating..."
    countdownLabel.TextColor3 = Color3.fromRGB(100, 220, 100)
    countdownLabel.TextXAlignment = Enum.TextXAlignment.Left
    countdownLabel.Font = Enum.Font.GothamBold
    countdownLabel.TextSize = 12
    countdownLabel.TextWrapped = true
    
    -- Close button
    local closeButton = Instance.new("TextButton")
    closeButton.Name = "CloseButton"
    closeButton.Parent = header
    closeButton.Size = UDim2.new(0.1, 0, 0.5, 0)
    closeButton.Position = UDim2.new(0.95, 0, 0.25, 0)
    closeButton.AnchorPoint = Vector2.new(0.5, 0.5)
    closeButton.BackgroundColor3 = Color3.fromRGB(220, 70, 70)
    closeButton.Text = "X"
    closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeButton.Font = Enum.Font.GothamBold
    closeButton.TextScaled = true
    closeButton.BorderSizePixel = 0
    
    local closeCorner = Instance.new("UICorner")
    closeCorner.CornerRadius = UDim.new(0, 12)
    closeCorner.Parent = closeButton
    
    -- Scrollable content area
    local scrollFrame = Instance.new("ScrollingFrame")
    scrollFrame.Name = "ScrollFrame"
    scrollFrame.Parent = mainFrame
    scrollFrame.Size = UDim2.new(0.95, 0, 0.75, 0)
    scrollFrame.Position = UDim2.new(0.025, 0, 0.22, 0)
    scrollFrame.BackgroundTransparency = 1
    scrollFrame.BorderSizePixel = 0
    scrollFrame.ScrollBarThickness = 6
    scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 120)
    scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scrollFrame.ScrollingDirection = Enum.ScrollingDirection.Y
    
    local listLayout = Instance.new("UIListLayout")
    listLayout.Parent = scrollFrame
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 5)
    
    -- Update countdown timer
    local function updateCountdown()
        if not countdownLabel or not countdownLabel.Parent then
            return false
        end
        
        local currentTime = os.time()
        local timeLeft = weeklyData.endTime - currentTime
        
        if timeLeft > 0 then
            countdownLabel.Text = "Next reset in: " .. formatCountdown(timeLeft)
            countdownLabel.TextColor3 = Color3.fromRGB(100, 220, 100)
        else
            countdownLabel.Text = "RESETTING SOON!"
            countdownLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        end
        
        return true
    end
    
    -- Connect countdown updater
    local countdownConnection
    countdownConnection = RunService.Heartbeat:Connect(function()
        if not updateCountdown() then
            countdownConnection:Disconnect()
        end
    end)
    
    -- Prepare player data for display
    local sortedPlayers = {}
    if weeklyData.playerTimes then
        for userId, data in pairs(weeklyData.playerTimes) do
            local currentTime = getCurrentPlayerTime(userId)
            table.insert(sortedPlayers, {
                userId = userId, 
                time = currentTime, 
                name = data.name,
                rank = data.rank
            })
        end
    end
    
    -- Sort by time (highest first)
    table.sort(sortedPlayers, function(a, b) 
        return a.time > b.time 
    end)
    
    -- Display player entries or "no data" message
    if #sortedPlayers == 0 then
        local noDataLabel = Instance.new("TextLabel")
        noDataLabel.Name = "NoDataLabel"
        noDataLabel.Parent = scrollFrame
        noDataLabel.Size = UDim2.new(1, 0, 0, 40)
        noDataLabel.BackgroundTransparency = 1
        noDataLabel.Text = "No time records yet for this week."
        noDataLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
        noDataLabel.Font = Enum.Font.Gotham
        noDataLabel.TextSize = 14
        noDataLabel.TextWrapped = true
        noDataLabel.TextScaled = true
    else
        -- Create entry for each player
        for i, data in ipairs(sortedPlayers) do
            local entry = Instance.new("Frame")
            entry.Name = "PlayerEntry"
            entry.Size = UDim2.new(1, 0, 0, 40)
            entry.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
            entry.BorderSizePixel = 0
            entry.Parent = scrollFrame
            entry.LayoutOrder = i
            
            local entryCorner = Instance.new("UICorner")
            entryCorner.CornerRadius = UDim.new(0, 6)
            entryCorner.Parent = entry
            
            -- Rank badge with color coding
            local rankBadge = Instance.new("Frame")
            rankBadge.Name = "RankBadge"
            rankBadge.Parent = entry
            rankBadge.Size = UDim2.new(0.1, 0, 0.8, 0)
            rankBadge.Position = UDim2.new(0.02, 0, 0.1, 0)
            rankBadge.AnchorPoint = Vector2.new(0, 0)
            
            -- Color code for top 3 positions
            if i == 1 then
                rankBadge.BackgroundColor3 = Color3.fromRGB(255, 215, 0)  -- Gold
            elseif i == 2 then
                rankBadge.BackgroundColor3 = Color3.fromRGB(192, 192, 192)  -- Silver
            elseif i == 3 then
                rankBadge.BackgroundColor3 = Color3.fromRGB(205, 127, 50)  -- Bronze
            else
                rankBadge.BackgroundColor3 = Color3.fromRGB(60, 140, 200)  -- Blue
            end
            
            rankBadge.BorderSizePixel = 0
            
            local badgeCorner = Instance.new("UICorner")
            badgeCorner.CornerRadius = UDim.new(0, 15)
            badgeCorner.Parent = rankBadge
            
            local rankText = Instance.new("TextLabel")
            rankText.Name = "RankText"
            rankText.Parent = rankBadge
            rankText.Size = UDim2.new(1, 0, 1, 0)
            rankText.BackgroundTransparency = 1
            rankText.Text = tostring(i)
            rankText.TextColor3 = Color3.fromRGB(255, 255, 255)
            rankText.Font = Enum.Font.GothamBold
            rankText.TextSize = 14
            rankText.TextScaled = true
            
            -- Player name
            local nameLabel = Instance.new("TextLabel")
            nameLabel.Name = "NameLabel"
            nameLabel.Parent = entry
            nameLabel.Size = UDim2.new(0.4, 0, 0.4, 0)
            nameLabel.Position = UDim2.new(0.15, 0, 0.1, 0)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Text = data.name
            nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
            nameLabel.TextXAlignment = Enum.TextXAlignment.Left
            nameLabel.Font = Enum.Font.Gotham
            nameLabel.TextSize = 14
            nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
            nameLabel.TextScaled = true
            
            -- Player rank
            local rankLabel = Instance.new("TextLabel")
            rankLabel.Name = "RankLabel"
            rankLabel.Parent = entry
            rankLabel.Size = UDim2.new(0.4, 0, 0.3, 0)
            rankLabel.Position = UDim2.new(0.15, 0, 0.5, 0)
            rankLabel.BackgroundTransparency = 1
            rankLabel.Text = "Rank: " .. data.rank
            rankLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
            rankLabel.TextXAlignment = Enum.TextXAlignment.Left
            rankLabel.Font = Enum.Font.Gotham
            rankLabel.TextSize = 11
            rankLabel.TextTruncate = Enum.TextTruncate.AtEnd
            rankLabel.TextScaled = true
            
            -- Player time
            local timeLabel = Instance.new("TextLabel")
            timeLabel.Name = "TimeLabel"
            timeLabel.Parent = entry
            timeLabel.Size = UDim2.new(0.4, 0, 0.4, 0)
            timeLabel.Position = UDim2.new(0.55, 0, 0.3, 0)
            timeLabel.AnchorPoint = Vector2.new(0, 0.5)
            timeLabel.BackgroundTransparency = 1
            timeLabel.Text = formatTime(data.time)
            timeLabel.TextColor3 = Color3.fromRGB(100, 220, 100)
            timeLabel.TextXAlignment = Enum.TextXAlignment.Left
            timeLabel.Font = Enum.Font.GothamBold
            timeLabel.TextSize = 14
            timeLabel.TextScaled = true
        end
    end
    
    -- Close button functionality
    closeButton.MouseButton1Click:Connect(function()
        if countdownConnection then
            countdownConnection:Disconnect()
        end
        gui:Destroy()
    end)
    
    -- Auto-close after 30 seconds
    task.delay(30, function()
        if gui and gui.Parent then
            if countdownConnection then
                countdownConnection:Disconnect()
            end
            gui:Destroy()
        end
    end)
    
    print("GUI created for player: " .. player.Name)
end

--[[
    ON CHATTED
    ==========
    Handles player chat commands
    
    Parameters:
    - player: Player who sent the message
    - message: Chat message content
--]]
local function onChatted(player, message)
    -- Check if message is a command
    if message:sub(1, #COMMAND_PREFIX) == COMMAND_PREFIX then
        local command = message:sub(#COMMAND_PREFIX + 1):lower()
        
        -- !access command - Show time tracker GUI
        if command == "access" then
            local userId = player.UserId
            local currentTime = os.time()
            
            -- Command cooldown check
            if commandCooldowns[userId] and currentTime - commandCooldowns[userId] < COMMAND_COOLDOWN then
                local remaining = COMMAND_COOLDOWN - (currentTime - commandCooldowns[userId])
                local privateMessage = Instance.new("Hint")
                privateMessage.Parent = player.PlayerGui
                privateMessage.Text = string.format("Please wait %d seconds before using !access again.", remaining)
                
                task.delay(3, function()
                    if privateMessage and privateMessage.Parent then
                        privateMessage:Destroy()
                    end
                end)
                return
            end
            
            commandCooldowns[userId] = currentTime
            
            -- Check rank requirement
            if hasGuardRank(player.UserId) then
                showTimeRecords(player)
            else
                local privateMessage = Instance.new("Hint")
                privateMessage.Parent = player.PlayerGui
                privateMessage.Text = "You need to be at least Guard rank to use this command."
                
                task.delay(5, function()
                    if privateMessage and privateMessage.Parent then
                        privateMessage:Destroy()
                    end
                end)
            end
            
        -- !testreport command - Test Discord report (admin only)
        elseif command == "testreport" then
            local userId = player.UserId
            local currentTime = os.time()
            
            -- Command cooldown check
            if commandCooldowns[userId] and currentTime - commandCooldowns[userId] < COMMAND_COOLDOWN then
                local remaining = COMMAND_COOLDOWN - (currentTime - commandCooldowns[userId])
                local privateMessage = Instance.new("Hint")
                privateMessage.Parent = player.PlayerGui
                privateMessage.Text = string.format("Please wait %d seconds before using commands again.", remaining)
                
                task.delay(3, function()
                    if privateMessage and privateMessage.Parent then
                        privateMessage:Destroy()
                    end
                end)
                return
            end
            
            commandCooldowns[userId] = currentTime
            
            -- Check rank requirement
            if hasGuardRank(player.UserId) then
                print("[TEST] Manual Discord report requested by: " .. player.Name)
                
                local privateMessage = Instance.new("Hint")
                privateMessage.Parent = player.PlayerGui
                privateMessage.Text = "📤 Generating Discord test report..."
                
                saveWeeklyData()
                
                local success = sendWeeklyReportToDiscord()
                
                task.delay(2, function()
                    if privateMessage and privateMessage.Parent then
                        if success then
                            privateMessage.Text = "✅ Test report sent to Discord!"
                        else
                            privateMessage.Text = "❌ Failed to send test report."
                        end
                    end
                end)
                
                task.delay(5, function()
                    if privateMessage and privateMessage.Parent then
                        privateMessage:Destroy()
                    end
                end)
                
            else
                local privateMessage = Instance.new("Hint")
                privateMessage.Parent = player.PlayerGui
                privateMessage.Text = "You need to be at least Guard rank to use this command."
                
                task.delay(5, function()
                    if privateMessage and privateMessage.Parent then
                        privateMessage:Destroy()
                    end
                end)
            end
        end
    end
end

--[[
    TRACK PLAYER TIME
    =================
    Starts tracking time for a player if they meet rank requirements
    
    Parameters:
    - player: Player instance to track
--]]
local function trackPlayerTime(player)
    -- Only track players with required rank
    if not hasGuardRank(player.UserId) then 
        return 
    end
    
    local userId = player.UserId
    local playerName = player.Name
    local rankName = getPlayerRankName(userId)
    
    -- Initialize player data structure if needed
    if not weeklyData.playerTimes then
        weeklyData.playerTimes = {}
    end
    
    -- Update or create player entry
    if weeklyData.playerTimes[userId] then
        weeklyData.playerTimes[userId].name = playerName
        weeklyData.playerTimes[userId].rank = rankName
    else
        weeklyData.playerTimes[userId] = {
            name = playerName,
            time = 0,
            rank = rankName
        }
    end
    
    -- Start tracking session
    activeSessions[userId] = os.time()
    dirtyPlayers[userId] = true
    
    -- Track when player leaves
    local leaveConnection
    leaveConnection = player.AncestryChanged:Connect(function(_, parent)
        if parent == nil then
            if activeSessions[userId] then
                local sessionTime = os.time() - activeSessions[userId]
                if weeklyData.playerTimes and weeklyData.playerTimes[userId] then
                    weeklyData.playerTimes[userId].time = weeklyData.playerTimes[userId].time + sessionTime
                end
                activeSessions[userId] = nil
                dirtyPlayers[userId] = true
                
                debouncedSave()
                
                if leaveConnection then
                    leaveConnection:Disconnect()
                end
            end
        end
    end)
end

--[[
    GAME SHUTDOWN HANDLER
    =====================
    Saves all data when server shuts down
--]]
game:BindToClose(function()
    print("Server shutting down, saving all active sessions...")
    
    task.wait(1)  -- Give time for connections to close
    
    -- Save all active sessions
    for userId, startTime in pairs(activeSessions) do
        if weeklyData.playerTimes and weeklyData.playerTimes[userId] then
            local sessionTime = os.time() - startTime
            weeklyData.playerTimes[userId].time = weeklyData.playerTimes[userId].time + sessionTime
        end
    end
    
    -- Perform final save with timeout
    local saveCompleted = false
    task.spawn(function()
        saveWeeklyData()
        saveCompleted = true
    end)
    
    local startWait = os.time()
    while not saveCompleted and os.time() - startWait < 5 do
        task.wait(0.1)
    end
    
    if saveCompleted then
        print("Data saved successfully before shutdown")
    else
        print("Warning: Save may not have completed before shutdown")
    end
    
    task.wait(1)
end)

--[[
    INITIALIZATION
    ==============
    Main initialization sequence
--]]
print("Loading weekly data...")
loadWeeklyData()
print("Weekly data loaded and checked")

-- Setup existing players
for _, player in ipairs(Players:GetPlayers()) do
    trackPlayerTime(player)
    player.Chatted:Connect(function(message)
        onChatted(player, message)
    end)
end

-- Setup new players
Players.PlayerAdded:Connect(function(player)
    trackPlayerTime(player)
    player.Chatted:Connect(function(message)
        onChatted(player, message)
    end)
end)

--[[
    MAIN LOOP
    =========
    Handles automatic saves and weekly resets
--]]
while true do
    task.wait(AUTO_SAVE_INTERVAL)
    
    -- Only process if players are online
    if #Players:GetPlayers() > 0 then
        -- Update active sessions
        for userId, startTime in pairs(activeSessions) do
            if weeklyData.playerTimes and weeklyData.playerTimes[userId] then
                local currentTime = os.time()
                local sessionTime = currentTime - startTime
                weeklyData.playerTimes[userId].time = weeklyData.playerTimes[userId].time + sessionTime
                activeSessions[userId] = currentTime
                dirtyPlayers[userId] = true
            end
        end
        
        -- Auto-save
        saveWeeklyData()
        
        -- Check for upcoming reset
        local currentTime = os.time()
        local timeUntilReset = weeklyData.endTime - currentTime
        
        -- Force final save before reset
        if timeUntilReset > 0 and timeUntilReset < 3600 then
            print("Less than 1 hour until weekly reset, forcing final data collection")
            saveWeeklyData()
        end
        
        -- Handle weekly reset
        if currentTime > weeklyData.endTime then
            print("WEEKLY RESET TRIGGERED")
            
            -- Final save of all sessions
            print("Performing final save of all active sessions...")
            for userId, startTime in pairs(activeSessions) do
                if weeklyData.playerTimes and weeklyData.playerTimes[userId] then
                    local sessionTime = os.time() - startTime
                    weeklyData.playerTimes[userId].time = (weeklyData.playerTimes[userId].time or 0) + sessionTime
                    activeSessions[userId] = os.time()
                    dirtyPlayers[userId] = true
                end
            end
            
            local finalSaveSuccess = saveWeeklyData()
            
            -- Send final report if save succeeded
            if finalSaveSuccess then
                print("Final pre-reset save completed successfully")
                
                if not RunService:IsStudio() then
                    print("Sending Discord weekly report...")
                    sendWeeklyReportToDiscord()
                else
                    -- Studio debugging output
                    print("Studio mode: Skipping Discord report, but data would be:")
                    local totalPlayers = 0
                    local totalTime = 0
                    for userId, data in pairs(weeklyData.playerTimes) do
                        if data and data.name then
                            totalPlayers = totalPlayers + 1
                            totalTime = totalTime + (data.time or 0)
                            print(string.format("  %s: %s", data.name, formatTime(data.time or 0)))
                        end
                    end
                    print(string.format("Total players: %d, Total time: %s", totalPlayers, formatTime(totalTime)))
                end
            else
                print("WARNING: Final save failed, report may be incomplete!")
            end
            
            -- Store old week summary
            local oldWeekData = {
                startTime = weeklyData.startTime,
                endTime = weeklyData.endTime,
                playerCount = 0,
                totalTime = 0
            }
            
            if weeklyData.playerTimes then
                for userId, data in pairs(weeklyData.playerTimes) do
                    if data and data.name then
                        oldWeekData.playerCount = oldWeekData.playerCount + 1
                        oldWeekData.totalTime = oldWeekData.totalTime + (data.time or 0)
                    end
                end
            end
            
            -- Reset for new week
            weeklyData.startTime, weeklyData.endTime = calculateWeekBoundaries()
            weeklyData.playerTimes = {}
            activeSessions = {}
            dirtyPlayers = {}
            
            print(string.format("Weekly reset complete. Old week had %d players with total time %s", 
                oldWeekData.playerCount, formatTime(oldWeekData.totalTime)))
            print("New week period: " .. formatDate(weeklyData.startTime) .. " to " .. formatDate(weeklyData.endTime))
            
            -- Save new week data
            task.spawn(function()
                task.wait(30)
                saveWeeklyData()
            end)
            
            print("Weekly data reset for new week")
        end
    end
end

