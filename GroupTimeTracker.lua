
--[[
    Time tracker system, this system includes tracking of playtime of our specific roles of our roblox community playing a game and 
can be viewed and reset every week while the report is sended to discord to keep record. This can be used to keep record of game staff and their activity!
--]]


local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- Config.
local GROUP_ID = 269811162                 -- group id
local GUARD_RANK = 0                      -- This will be the minimum role we will be tracking (here i made 0 so everyone can test)
local COMMAND_PREFIX = "!"                 -- This is like command prefix for in-game chat command to view activity and use command
local DATASTORE_NAME = "GroupTimeTracker_Guard_V3"
local RESET_DAY = 7                        -- This as it already shows is day of week to reset (0=Sun, 7=Sun)

-- discord settings
local DISCORD_WEBHOOK_URL = ""            -- here we can add our discord webhook (this will send report automatically at end of week), else will be skipped

-- this section is for making sure everything is stored well and to counter data store problems, also we will be using Cache so better result!
local MAX_DATASTORE_RETRIES = 5 
local RETRY_DELAY = 5 
local MAX_REQUESTS_PER_MINUTE = 30        -- data store rate limit (so it don't go over it)
local CACHE_DURATION = 90                 -- rank cache
local SAVE_COOLDOWN = 60                  -- time between saves
local AUTO_SAVE_INTERVAL = 900
local COMMAND_COOLDOWN = 10
local RESET_BUFFER = 3600

-- below in this section are state management variables (no need to change anything here, just for development use)
local requestCount = 0 
local lastResetTime = os.time()
local lastSaveTime = 0
local pendingSave = false
local sessionCache = {}
local commandCooldowns = {}
local weeklyData = {
    startTime = nil,                      -- Our week start timestamp
    endTime = nil,                        -- Our week end timestamp
    playerTimes = {}                      -- player time records: {userId = {name, time, rank}}
}
local activeSessions = {}                 -- for currently online players: {userId = joinTime}
local dirtyPlayers = {}                   -- These are players with unsaved changes
local initialLoadComplete = false

--queue for data store
local requestQueue = {}
local processingQueue = false

--[[
  Below Functions Processes DataStore operations with rate limiting with sequence so all goes well
--]]
local function processRequestQueue()
    if processingQueue or #requestQueue == 0 then
        return
    end
    
    processingQueue = true
    
    while #requestQueue > 0 do
        local request = table.remove(requestQueue, 1)
        local currentTime = os.time()
        
        if currentTime - lastResetTime >= 60 then
            requestCount = 0
            lastResetTime = currentTime
        end
        
        if requestCount >= MAX_REQUESTS_PER_MINUTE then
            local waitTime = 60 - (currentTime - lastResetTime)
            print(string.format("DataStore rate limit reached. Queueing %d requests, waiting %d seconds...", 
                #requestQueue + 1, waitTime))
            task.wait(waitTime + 1)
            requestCount = 0
            lastResetTime = os.time()
        end
        
        local success, result = pcall(request.operation, unpack(request.args))
        requestCount = requestCount + 1
        
        if request.callback then
            request.callback(success, result)
        end
        
        task.wait(0.1)
    end
    
    processingQueue = false
end

--[[
    Queue Data store
    This adds DataStore operations to the processing queue
--]]
local function queueDataStoreOperation(operation, callback, ...)
    table.insert(requestQueue, {
        operation = operation,
        args = {...},
        callback = callback
    })
    
    if not processingQueue then
        task.spawn(processRequestQueue)
    end
end

--[[
    For Getting Cached session 
like it retrieves cached player data if still valid
--]]
local function getCachedSession(userId)
    if sessionCache[userId] and os.time() - sessionCache[userId].timestamp < CACHE_DURATION then
        return sessionCache[userId].data
    end
    return nil
end


local function setCachedSession(userId, data)
    sessionCache[userId] = {
        data = data,
        timestamp = os.time()
    }
end


local function safeDataStoreOperation(operation, ...)
    local retries = 0
    local lastError
    
    while retries < MAX_DATASTORE_RETRIES do
        local currentTime = os.time()
        
        if currentTime - lastResetTime >= 60 then
            requestCount = 0
            lastResetTime = currentTime
        end
        
        if requestCount >= MAX_REQUESTS_PER_MINUTE then
            local waitTime = 60 - (currentTime - lastResetTime)
            task.wait(waitTime + 1)
            requestCount = 0
            lastResetTime = os.time()
        end
        
        local success, result = pcall(operation, ...)
        
        if success then
            requestCount = requestCount + 1
            return true, result
        else
            lastError = result
            retries = retries + 1
            
            if not string.find(tostring(result), "RequestLimitReached") then
                print(string.format("DataStore operation failed (attempt %d/%d): %s", 
                    retries, MAX_DATASTORE_RETRIES, tostring(result)))
            end
            
            -- backoff
            if retries < MAX_DATASTORE_RETRIES then
                task.wait(RETRY_DELAY * math.pow(2, retries - 1))
            end
        end
    end
    
    return false, lastError
end

--[[
    Format time:
     This Converts seconds to HH:MM:SS format
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
    Format date:
    Similarly like time this converts timestamp to readable date format
    --]]
local function formatDate(timestamp)
    if not timestamp or type(timestamp) ~= "number" then
        return "Unknown"
    end
    return os.date("%Y-%m-%d %H:%M", timestamp)
end

--[[
    format countdown (for showing days, hours)
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
Rank check according to our settings we did above
--]]
local function hasGuardRank(userId)
    -- Check cache
    local cached = getCachedSession(userId)
    if cached and cached.rankCheck then
        return cached.rankCheck >= GUARD_RANK
    end
    
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
        -- Handle API errors
        if not string.find(tostring(result), "429") then
            print("Error checking rank for user " .. userId .. ": " .. tostring(result))
        end
        return false
    end
end

--[[
    This gets the role/rank name of a player in the group
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
    For Calculating Week Boundaries
--]]
local function calculateWeekBoundaries()
    local now = os.time()
    local currentDay = tonumber(os.date("%w", now))  -- 0=Sunday, 6=Saturday
    
    local resetDay = RESET_DAY == 7 and 0 or RESET_DAY
    local daysSinceReset = (currentDay - resetDay) % 7
    if daysSinceReset < 0 then daysSinceReset = daysSinceReset + 7 end
    
    -- start of week
    local startOfWeek = now - (daysSinceReset * 86400)
    local date = os.date("*t", startOfWeek)
    date.hour = 0
    date.min = 0
    date.sec = 0
    startOfWeek = os.time(date)
    
    -- end of week (end of day)
    local endOfWeek = startOfWeek + (7 * 86400) - 1
    
    return startOfWeek, endOfWeek
end

--[[
 This calculates total tracked time for a player including current session
    --]]
local function getCurrentPlayerTime(userId)
    if not weeklyData.playerTimes or not weeklyData.playerTimes[userId] then
        return 0
    end
    
    local totalTime = weeklyData.playerTimes[userId].time or 0
    
    -- we add active session time if player is online
    if activeSessions[userId] then
        totalTime = totalTime + (os.time() - activeSessions[userId])
    end
    
    return totalTime
end

--[[
    Saves current week's data to DataStore with backup
--]]
local function saveWeeklyData()
    if not initialLoadComplete then
        return false
    end
    
    local currentTime = os.time()
    
    if currentTime - lastSaveTime < SAVE_COOLDOWN and not pendingSave then
        pendingSave = true
        task.delay(SAVE_COOLDOWN - (currentTime - lastSaveTime), function()
            pendingSave = false
            saveWeeklyData()
        end)
        return false
    end
    
    pendingSave = false
    
    -- we update active sessions before saving (so we don't miss anything)
    for userId, startTime in pairs(activeSessions) do
        if weeklyData.playerTimes and weeklyData.playerTimes[userId] then
            local sessionTime = os.time() - startTime
            weeklyData.playerTimes[userId].time = (weeklyData.playerTimes[userId].time or 0) + sessionTime
            activeSessions[userId] = os.time()
            dirtyPlayers[userId] = true
        end
    end
    
    -- prepare data for saving
    local saveData = {
        startTime = weeklyData.startTime,
        endTime = weeklyData.endTime,
        playerTimes = {},
        version = 3,
        savedAt = os.time()
    }
    
    -- convert player times table
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
    
    local dataStore = DataStoreService:GetDataStore(DATASTORE_NAME)
    local backupStore = DataStoreService:GetDataStore(DATASTORE_NAME .. "_Backup")
    
    local success, err = safeDataStoreOperation(function()
        dataStore:SetAsync("weeklyData", saveData)
        
        -- backup in separate coroutine
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
        
        -- emergency save
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
  This formats and sends weekly report to our discord webhook
  
--]]
local function sendWeeklyReportToDiscord()
    if not DISCORD_WEBHOOK_URL or DISCORD_WEBHOOK_URL == "" then
        print("Discord webhook not configured, skipping report")
        return false
    end

    -- just for testing in studio
    if RunService:IsStudio() then
        print("Studio: Skipping Discord report")
        return false
    end
    
    if not weeklyData.playerTimes then
        print("No player data available for Discord report")
        return false
    end
    
    -- player data for sorting
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
    
    -- sort
    table.sort(sortedPlayers, function(a, b) 
        return a.time > b.time 
    end)
    
    -- Discord embeds
    local embeds = {}
    
    -- Summary of our discord embeds
    local summaryEmbed = {
        title = "Weekly Time Tracking Report - COMPLETE",
        color = 3447003,
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
        name = "Summary",
        value = string.format(
            "**Total Players:** %d\n**Total Time:** %s\n**Average Time:** %s",
            playerCount, 
            formatTime(totalTime),
            formatTime(averageTime)
        ),
        inline = false
    })
    
    table.insert(embeds, summaryEmbed)
    
    if playerCount > 0 then
        local chunks = {}
        for i = 1, playerCount, 20 do
            local chunk = {}
            for j = i, math.min(i + 19, playerCount) do
                table.insert(chunk, sortedPlayers[j])
            end
            table.insert(chunks, chunk)
        end
        
        for chunkIndex, chunk in ipairs(chunks) do
            local embed = {
                title = string.format(" Player Rankings (%d/%d)", chunkIndex, #chunks),
                color = 15105570,
                fields = {},
                footer = {
                    text = string.format("Page %d/%d • Total Players: %d", chunkIndex, #chunks, playerCount)
                }
            }
            
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
            color = 15158332,
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
        avatar_url = "https://i.imgur.com/6JqQZ7y.png"
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
    This loads weekly data from dataStore and initializes new week if needed
    also includes backup recovery system
--]]
local function loadWeeklyData()
    local dataStore = DataStoreService:GetDataStore(DATASTORE_NAME)
    local backupStore = DataStoreService:GetDataStore(DATASTORE_NAME .. "_Backup")
    
    local function loadFromStore(store, isBackup)
        local success, data = safeDataStoreOperation(function()
            return store:GetAsync(isBackup and "backup_" .. os.date("%Y%m%d") or "weeklyData")
        end)
        
        if success and data then
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
            
            if data.startTime and data.endTime and data.playerTimes then
                return data
            end
        end
        return nil
    end
    
    local data = loadFromStore(dataStore, false)
    
    if not data then
        print("Primary load failed, trying backup...")
        data = loadFromStore(backupStore, true)
    end
    
    if data then
        weeklyData = data
        print("Weekly data loaded successfully")
        
        -- Check if week reset is needed??
        local currentTime = os.time()
        local isFreshSession = RunService:IsStudio() and currentTime - (weeklyData.endTime or 0) > 86400
        
        if isFreshSession or (weeklyData.endTime and currentTime > (weeklyData.endTime + RESET_BUFFER)) then
            print("Week reset detected")
            
            -- send final report before reset (yeayyy)
            if not isFreshSession and not RunService:IsStudio() then
                task.spawn(function()
                    task.wait(10)
                    sendWeeklyReportToDiscord()
                end)
            end
            
            -- reset for new week
            weeklyData.startTime, weeklyData.endTime = calculateWeekBoundaries()
            weeklyData.playerTimes = {}
            dirtyPlayers = {}
            
            -- save new week data
            task.spawn(function()
                task.wait(30)
                saveWeeklyData()
            end)
            
            print("Weekly data reset for new week")
        end
    else
        print("No existing data found, initializing new week")
        weeklyData.startTime, weeklyData.endTime = calculateWeekBoundaries()
        weeklyData.playerTimes = {}
        
        if not RunService:IsStudio() then
            task.spawn(function()
                task.wait(60)
                saveWeeklyData()
            end)
        end
    end
    
    initialLoadComplete = true
end

--[[
    show time records
--]]
local function showTimeRecords(player)
    
    if player.PlayerGui:FindFirstChild("TimeTrackerGUI") then
        player.PlayerGui.TimeTrackerGUI:Destroy()
    end
    
    local gui = Instance.new("ScreenGui")
    gui.Name = "TimeTrackerGUI"
    gui.Parent = player.PlayerGui
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    
    local mainFrame = Instance.new("Frame")
    mainFrame.Name = "MainFrame"
    mainFrame.Parent = gui
    mainFrame.Size = UDim2.new(0.7, 0, 0.65, 0)
    mainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
    mainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
    mainFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
    mainFrame.BorderSizePixel = 0
    mainFrame.ClipsDescendants = true
    
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
    
    local countdownConnection
    countdownConnection = RunService.Heartbeat:Connect(function()
        if not updateCountdown() then
            countdownConnection:Disconnect()
        end
    end)
    
    -- player data for display
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
    
    -- sort
    table.sort(sortedPlayers, function(a, b) 
        return a.time > b.time 
    end)
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
-- entry for each player
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
            
            local rankBadge = Instance.new("Frame")
            rankBadge.Name = "RankBadge"
            rankBadge.Parent = entry
            rankBadge.Size = UDim2.new(0.1, 0, 0.8, 0)
            rankBadge.Position = UDim2.new(0.02, 0, 0.1, 0)
            rankBadge.AnchorPoint = Vector2.new(0, 0)
            
            if i == 1 then
                rankBadge.BackgroundColor3 = Color3.fromRGB(255, 215, 0)
            elseif i == 2 then
                rankBadge.BackgroundColor3 = Color3.fromRGB(192, 192, 192)
            elseif i == 3 then
                rankBadge.BackgroundColor3 = Color3.fromRGB(205, 127, 50)
            else
                rankBadge.BackgroundColor3 = Color3.fromRGB(60, 140, 200)
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
    
    closeButton.MouseButton1Click:Connect(function()
        if countdownConnection then
            countdownConnection:Disconnect()
        end
        gui:Destroy()
    end)
    
    task.delay(30, function()
        if gui and gui.Parent then
            if countdownConnection then
                countdownConnection:Disconnect()
            end
            gui:Destroy()
        end
    end)
    
end

--[[
    Handles player chat commands
--]]
local function onChatted(player, message)
    if message:sub(1, #COMMAND_PREFIX) == COMMAND_PREFIX then
        local command = message:sub(#COMMAND_PREFIX + 1):lower()
        
        -- !access command
        if command == "access" then
            local userId = player.UserId
            local currentTime = os.time()
            
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
            
            -- rank requirement
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
            
        -- !testreport command to test discord report (just for me or admins you can ignore)
        elseif command == "testreport" then
            local userId = player.UserId
            local currentTime = os.time()
            
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
                privateMessage.Text = " Generating Discord test report"
                
                saveWeeklyData()
                
                local success = sendWeeklyReportToDiscord()
                
                task.delay(2, function()
                    if privateMessage and privateMessage.Parent then
                        if success then
                            privateMessage.Text = "Test report sent to Discord!"
                        else
                            privateMessage.Text = " Failed to send test report."
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
  tracking time for a player if they meet rank requirements
--]]
local function trackPlayerTime(player)
    if not hasGuardRank(player.UserId) then 
        return 
    end
    
    local userId = player.UserId
    local playerName = player.Name
    local rankName = getPlayerRankName(userId)
    
    if not weeklyData.playerTimes then
        weeklyData.playerTimes = {}
    end
    
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
    
    activeSessions[userId] = os.time()
    dirtyPlayers[userId] = true
    
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
    Game shutdown handler or server
--]]
game:BindToClose(function()
    print("Server shutting down, saving all active sessions")
    
    task.wait(1)
    
    -- all active sessions
    for userId, startTime in pairs(activeSessions) do
        if weeklyData.playerTimes and weeklyData.playerTimes[userId] then
            local sessionTime = os.time() - startTime
            weeklyData.playerTimes[userId].time = weeklyData.playerTimes[userId].time + sessionTime
        end
    end
    
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
        print("saved successfully before shutdown")
    else
        print("Save may not have completed before shutdown")
    end
    
    task.wait(1)
end)


print("Loading weekly data")
loadWeeklyData()
print("Weekly data loaded and checked")

for _, player in ipairs(Players:GetPlayers()) do
    trackPlayerTime(player)
    player.Chatted:Connect(function(message)
        onChatted(player, message)
    end)
end

Players.PlayerAdded:Connect(function(player)
    trackPlayerTime(player)
    player.Chatted:Connect(function(message)
        onChatted(player, message)
    end)
end)

--[[
  This handles automatic saves and weekly resets
--]]
while true do
    task.wait(AUTO_SAVE_INTERVAL)
    
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
        
        -- auto save
        saveWeeklyData()
        
        -- for upcoming reset
        local currentTime = os.time()
        local timeUntilReset = weeklyData.endTime - currentTime
        
        if timeUntilReset > 0 and timeUntilReset < 3600 then
    --        print("Less than 1 hour until weekly reset, forcing final data collection")
            saveWeeklyData()
        end
        
        if currentTime > weeklyData.endTime then
            print("WEEKLY RESET TRIGGERED")
            
          --  print("Performing final save of all active sessions")
            for userId, startTime in pairs(activeSessions) do
                if weeklyData.playerTimes and weeklyData.playerTimes[userId] then
                    local sessionTime = os.time() - startTime
                    weeklyData.playerTimes[userId].time = (weeklyData.playerTimes[userId].time or 0) + sessionTime
                    activeSessions[userId] = os.time()
                    dirtyPlayers[userId] = true
                end
            end
            
            local finalSaveSuccess = saveWeeklyData()
            
            if finalSaveSuccess then
           --     print("Final prereset save completed successfully")
                
                if not RunService:IsStudio() then
            --        print("Sending Discord weekly report")
                    sendWeeklyReportToDiscord()
                else
--                print("Studio: skipping Discord report, but data would be:")
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
        --        print("WARNING: Final save failed, report may be incomplete!")
            end
            
            -- store old week summary
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
            
            weeklyData.startTime, weeklyData.endTime = calculateWeekBoundaries()
            weeklyData.playerTimes = {}
            activeSessions = {}
            dirtyPlayers = {}
            
            print(string.format("Weekly reset complete. Old week had %d players with total time %s", 
                oldWeekData.playerCount, formatTime(oldWeekData.totalTime)))
            print("New week period: " .. formatDate(weeklyData.startTime) .. " to " .. formatDate(weeklyData.endTime))
            
            task.spawn(function()
                task.wait(30)
                saveWeeklyData()
            end)
            
        --    print("Weekly data reset for new week")
        end
    end
end

