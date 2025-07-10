local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local HeartControl = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("HeartControl")
local ServerData = require(script.Parent.ServerData)

-- Configurações
local HEARTS_PER_AREA    = 2
local HEART_DESPAWN_TIME = 30
local PLAYER_COOLDOWN    = 0.7
local BASE_MAX_SPEED     = 25
local COLLECT_RADIUS     = 4
local BROADCAST_COOLDOWN = 15
local RESPAWN_TICK       = 5
local GRID_SIZE          = 16 -- tamanho das células da malha

-- Estado
local areas         = {}
local hearts        = {} -- [id] = {pos=Vector3, area=int, spawn=time, cell=string}
local grid          = {} -- [cellKey] = {heartIds}
local playerTimer   = {}
local lastState     = {}
local minuteLog     = {}
local broadcastTime = {}

-- Célula da malha a partir da posição
local function getCellKey(vec)
    return math.floor(vec.X / GRID_SIZE) .. "|" .. math.floor(vec.Z / GRID_SIZE)
end

-- Ponto aleatório dentro da área
local function randomPoint(area)
    local ref = area.Ref
    local halfX, halfZ = ref.Size.X / 2, ref.Size.Z / 2
    local x = math.floor(math.random(ref.Position.X - halfX, ref.Position.X + halfX) / 8) * 8
    local z = math.floor(math.random(ref.Position.Z - halfZ, ref.Position.Z + halfZ) / 8) * 8
    return Vector3.new(x, ref.Position.Y + 2, z)
end

-- Registra no grid
local function registerHeart(id, pos)
    local key = getCellKey(pos)
    local cell = grid[key]
    if cell then
        cell[#cell + 1] = id
    else
        grid[key] = { id }
    end
    return key
end

-- Remove do grid
local function unregisterHeart(id, cell)
    local list = grid[cell]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == id then
            table.remove(list, i)
            break
        end
    end
    if #list == 0 then
        grid[cell] = nil
    end
end

-- Remove coração existente
local function despawnHeart(id)
    local heart = hearts[id]
    if not heart then return end
    local area = areas[heart.area]
    if area then area.Hearts -= 1 end
    hearts[id] = nil
    unregisterHeart(id, heart.cell)
    HeartControl:FireAllClients(2, id)
end

-- Cria novo coração
local function spawnHeart(area)
    local pos = randomPoint(area)
    local id = HttpService:GenerateGUID(false)
    local cell = registerHeart(id, pos)
    hearts[id] = { pos = pos, area = area.Index, spawn = os.clock(), cell = cell }
    area.Hearts += 1
    HeartControl:FireAllClients(1, id, pos)
end

-- Verifica coleta e expiração para um jogador
local function processPlayer(player, now, hrp)
    local cx = math.floor(hrp.Position.X / GRID_SIZE)
    local cz = math.floor(hrp.Position.Z / GRID_SIZE)

    for dx = -1, 1 do
        for dz = -1, 1 do
            local key = (cx + dx) .. "|" .. (cz + dz)
            local cell = grid[key]
            if cell then
                for i = #cell, 1, -1 do
                    local id = cell[i]
                    local heart = hearts[id]
                    if not heart then
                        table.remove(cell, i)
                    else
                        if now - heart.spawn >= HEART_DESPAWN_TIME then
                            despawnHeart(id)
                        elseif (hrp.Position - heart.pos).Magnitude <= COLLECT_RADIUS then
                            if playerTimer[player] and now - playerTimer[player] < PLAYER_COOLDOWN then
                                break
                            end
                            local last = lastState[player]
                            if last then
                                local dt = now - last.time
                                if dt > 0 then
                                    local dist = (hrp.Position - last.pos).Magnitude
                                    local speed = dist / dt
                                    local limit = BASE_MAX_SPEED + 2 * (heart.area - 1)
                                    if speed > limit then
                                        player:Kick("Speed violation")
                                        return
                                    end
                                end
                            end
                            lastState[player] = { pos = hrp.Position, time = now }
                            playerTimer[player] = now

                            local log = minuteLog[player]
                            if not log then
                                log = {}
                                minuteLog[player] = log
                            end
                            table.insert(log, now)
                            for j = #log, 1, -1 do
                                if now - log[j] > 60 then table.remove(log, j) end
                            end
                            if #log > 120 then
                                player:Kick("Excesso de corações")
                                return
                            end

                            local data = ServerData.GetData(player)
                            if data then data:AddHearts(1) end

                            despawnHeart(id)
                            break
                        end
                    end
                end
            end
        end
    end
end

-- Checagem periódica de expiração
local function expireOldHearts()
    local now = os.clock()
    for id, heart in pairs(hearts) do
        if now - heart.spawn >= HEART_DESPAWN_TIME then
            despawnHeart(id)
        end
    end
end

-- Loop global de Heartbeat
local nextExpire = 0
RunService.Heartbeat:Connect(function()
    local now = os.clock()
    if now >= nextExpire then
        expireOldHearts()
        nextExpire = now + 1
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
        if hrp then
            processPlayer(plr, now, hrp)
        end
    end
end)

-- Respawn automático
local function respawnTicker()
    while true do
        for _, area in pairs(areas) do
            while area.Hearts < HEARTS_PER_AREA do
                spawnHeart(area)
            end
        end
        task.wait(RESPAWN_TICK)
    end
end

-- Controle remoto
HeartControl.OnServerEvent:Connect(function(plr, opcode)
    if typeof(opcode) ~= "number" then return end
    if opcode == 3 then
        HeartControl:FireClient(plr, 3, hearts)
    elseif opcode == 4 then
        local now = os.clock()
        if broadcastTime[plr] and now - broadcastTime[plr] < BROADCAST_COOLDOWN then return end
        broadcastTime[plr] = now
        HeartControl:FireAllClients(4, hearts)
    end
end)

local module = {}

function module.init()
    local spawns = workspace:WaitForChild("HeartsSpawns"):GetChildren()
    for i, part in ipairs(spawns) do
        areas[i] = { Ref = part, Hearts = 0, Index = i }
    end
    for _, area in pairs(areas) do
        while area.Hearts < HEARTS_PER_AREA do
            spawnHeart(area)
        end
    end
    task.spawn(respawnTicker)
    Players.PlayerRemoving:Connect(function(plr)
        playerTimer[plr]   = nil
        lastState[plr]     = nil
        minuteLog[plr]     = nil
        broadcastTime[plr] = nil
    end)
end

return module
