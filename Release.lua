local CONFIG = {
    FIRST_GRACE        = 120,  -- seconds to wait for the first round after joining
    LATER_GRACE        = 240,  -- seconds without a round before the server is considered unresponsive
    POLL               = 1,    -- check interval (seconds)
    STARTUP_WAIT       = 5,    -- delay after the game loads (seconds)
    ROUND_ITEMS        = { "Knife", "Gun" },  -- verify these names in Dex
    ENABLE_SESSION_HOP = false,
    SESSION_HOP_AFTER  = 1800,
    SHOW_GUI           = true,
    MIN_PLAYERS        = 3,    -- minimum players on the target server
    MIN_FREE_SLOTS     = 2,    -- minimum free slots on the target server
    MAX_PAGES          = 5,    -- server list pages to scan
}

local function main()
    local Players          = game:GetService("Players")
    local TeleportService  = game:GetService("TeleportService")
    local HttpService      = game:GetService("HttpService")
    local UserInputService = game:GetService("UserInputService")
    local LocalPlayer      = Players.LocalPlayer

    local env = (type(getgenv) == "function" and getgenv()) or _G
    if env.__MM2_WD_STOP then pcall(env.__MM2_WD_STOP) end
    local running = true
    env.__MM2_WD_STOP = function() running = false end

    ----------------------------------------------------------------
    -- Interface
    ----------------------------------------------------------------
    local ui = {}

    local function fmt(sec)
        if sec < 0 then sec = 0 end
        return string.format("%02d:%02d", math.floor(sec / 60), math.floor(sec % 60))
    end

    local function setStatus(text)
        if ui.status then ui.status.Text = "Status: " .. tostring(text) end
    end

    local function buildGui()
        local parent
        if type(gethui) == "function" then parent = gethui() end
        if not parent then parent = game:GetService("CoreGui") end

        local gui = Instance.new("ScreenGui")
        gui.Name = "MM2Watchdog"
        gui.ResetOnSpawn = false
        gui.Parent = parent

        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(0, 230, 0, 128)
        frame.Position = UDim2.new(0, 10, 0, 60)
        frame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
        frame.BackgroundTransparency = 0.15
        frame.BorderSizePixel = 0
        frame.Active = true
        frame.Parent = gui

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 8)
        corner.Parent = frame

        local function label(y, text, size, bold)
            local l = Instance.new("TextLabel")
            l.Position = UDim2.new(0, 10, 0, y)
            l.Size = UDim2.new(1, -20, 0, size + 4)
            l.BackgroundTransparency = 1
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.TextColor3 = Color3.new(1, 1, 1)
            l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
            l.TextSize = size
            l.Text = text
            l.TextTruncate = Enum.TextTruncate.AtEnd
            l.Parent = frame
            return l
        end

        ui.title   = label(6,  "MM2 Watchdog", 14, true)
        ui.status  = label(28, "Status: Starting", 13)
        ui.round   = label(50, "Round: Unknown", 13)
        ui.noround = label(72, "No round: 00:00 / 02:00", 13)
        ui.session = label(94, "Time on server: 00:00", 13)

        -- Dragging (mouse and touch)
        local dragging, dragStart, startPos
        frame.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                dragStart = i.Position
                startPos = frame.Position
                i.Changed:Connect(function()
                    if i.UserInputState == Enum.UserInputState.End then dragging = false end
                end)
            end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
                or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - dragStart
                frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                           startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end)
    end

    if CONFIG.SHOW_GUI then
        pcall(buildGui)
    end

    ----------------------------------------------------------------
    -- Server hop
    ----------------------------------------------------------------
    local hopping = false
    local teleporting = false
    local lastFailure = ""

    pcall(function()
        TeleportService.TeleportInitFailed:Connect(function(player, result, msg)
            if player ~= LocalPlayer then return end
            teleporting = false
            lastFailure = tostring(result) .. " " .. tostring(msg)
            setStatus("Teleport rejected: " .. lastFailure)
        end)
    end)

    local function httpGet(url)
        local ok, res = pcall(function() return game:HttpGet(url) end)
        if ok and type(res) == "string" and #res > 0 then return res end
        local err = ok and "empty response" or tostring(res)

        local req = request or http_request or (syn and syn.request) or (http and http.request)
        if req then
            local ok2, r = pcall(req, { Url = url, Method = "GET" })
            if ok2 and type(r) == "table" then
                if r.StatusCode == 200 and r.Body then return r.Body end
                return nil, "HTTP " .. tostring(r.StatusCode)
            end
            err = tostring(r)
        end
        return nil, err
    end

    local function fetchServers()
        local list = {}
        local cursor = ""
        for page = 1, CONFIG.MAX_PAGES do
            local url = "https://games.roblox.com/v1/games/" .. tostring(game.PlaceId)
                .. "/servers/Public?sortOrder=Desc&excludeFullGames=true&limit=100"
            if cursor ~= "" then url = url .. "&cursor=" .. cursor end

            local body, err = httpGet(url)
            if not body then return list, err end

            local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
            if not ok or type(data) ~= "table" then return list, "invalid API response" end
            if data.errors then
                local m = data.errors[1] and data.errors[1].message
                return list, "API error: " .. tostring(m)
            end

            for _, s in ipairs(data.data or {}) do table.insert(list, s) end
            cursor = data.nextPageCursor or ""
            if cursor == "" then break end
            task.wait(0.5)
        end
        return list, nil
    end

    local function hopOnce()
        setStatus("Searching for a server")
        local servers, err = fetchServers()

        local candidates = {}
        for _, s in ipairs(servers) do
            if s.id ~= game.JobId and s.playing and s.maxPlayers
                and s.playing >= CONFIG.MIN_PLAYERS
                and (s.maxPlayers - s.playing) >= CONFIG.MIN_FREE_SLOTS then
                table.insert(candidates, s.id)
            end
        end

        if #candidates > 0 then
            local id = candidates[math.random(1, #candidates)]
            teleporting = true
            local ok, e = pcall(function()
                TeleportService:TeleportToPlaceInstance(game.PlaceId, id, LocalPlayer)
            end)
            if not ok then
                teleporting = false
                return false, "Teleport error: " .. tostring(e)
            end
            return true, "Teleporting (" .. #candidates .. " servers available)"
        end

        -- Fallback: let Roblox select a server
        teleporting = true
        local ok, e = pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
        if not ok then
            teleporting = false
            return false, "Fallback teleport error: " .. tostring(e)
        end
        return true, "Fallback teleport (" .. tostring(err or "no suitable servers") .. ")"
    end

    local function doHop()
        if hopping then return end
        hopping = true
        task.spawn(function()
            local attempt = 0
            while running do
                attempt = attempt + 1
                local pok, ok, msg = pcall(hopOnce)
                if not pok then ok, msg = false, tostring(ok) end
                setStatus("Hop #" .. attempt .. ": " .. tostring(msg))

                if ok then
                    local t = os.clock()
                    while running and teleporting and os.clock() - t < 25 do
                        task.wait(0.5)
                    end
                end

                local busy = string.find(lastFailure, "Flooded") or string.find(lastFailure, "IsTeleporting")
                task.wait(busy and 20 or 5)
            end
        end)
    end

    ----------------------------------------------------------------
    -- Round detection
    ----------------------------------------------------------------
    local function hasItem(container)
        if not container then return false end
        for _, name in ipairs(CONFIG.ROUND_ITEMS) do
            if container:FindFirstChild(name) then return true end
        end
        return false
    end

    local function isRoundActive()
        for _, p in ipairs(Players:GetPlayers()) do
            if hasItem(p.Character) or hasItem(p:FindFirstChild("Backpack")) then
                return true
            end
        end
        return false
    end

    ----------------------------------------------------------------
    -- Main loop
    ----------------------------------------------------------------
    task.spawn(function()
        pcall(function()
            if not game:IsLoaded() then game.Loaded:Wait() end
            task.wait(CONFIG.STARTUP_WAIT)

            local joinedAt = os.clock()
            local lastSeen = os.clock()
            local roundSeen = false

            while running do
                local now = os.clock()
                local active = isRoundActive()
                local limit = roundSeen and CONFIG.LATER_GRACE or CONFIG.FIRST_GRACE

                if active then
                    roundSeen = true
                    lastSeen = now
                    setStatus("Operating normally")
                else
                    setStatus(roundSeen and "Awaiting next round" or "Awaiting first round")
                end

                local idle = now - lastSeen
                if ui.round then
                    ui.round.Text = "Round: " .. (active and "Active" or "Inactive")
                    ui.round.TextColor3 = active and Color3.fromRGB(110, 230, 130)
                                                  or Color3.fromRGB(255, 200, 90)
                    ui.noround.Text = "No round: " .. fmt(idle) .. " / " .. fmt(limit)
                    ui.session.Text = "Time on server: " .. fmt(now - joinedAt)
                end

                if not active and idle > limit then
                    setStatus("Server unresponsive, initiating hop")
                    doHop()
                    break
                end

                if CONFIG.ENABLE_SESSION_HOP and (now - joinedAt) > CONFIG.SESSION_HOP_AFTER then
                    setStatus("Scheduled server hop")
                    doHop()
                    break
                end

                task.wait(CONFIG.POLL)
            end
        end)
    end)
end

pcall(main)
