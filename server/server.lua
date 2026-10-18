local convarToken <const> = GetConvar('gimic_discord_token', '')
local TOKEN <const> = convarToken ~= '' and convarToken or Config.botToken or ''
local GUILD <const> = tostring(Config.guildId or '')

local API <const> = 'https://discord.com/api/v10/'
local HEADERS <const> = { ['Content-Type'] = 'application/json', ['Authorization'] = 'Bot ' .. TOKEN }

local TTL <const> = 300      -- seconds a player's details are kept
local LIVE_TTL <const> = 60  -- the Live and Result exports read again after this
local FAIL_TTL <const> = 30  -- seconds before a failed lookup is tried again
local GAP <const> = 100      -- ms between requests
local TIMEOUT <const> = 15000
local RETRIES <const> = 3

local PREFIX <const> = ('\27[38;2;255;122;24m[%s]\27[0m'):format(GetCurrentResourceName())

local function log(tag, message, ...)
    print(('%s %s %s^7'):format(PREFIX, tag, message:format(...)))
end

-- strips ^ colour codes and control characters
local function plain(text)
    return (tostring(text):gsub('%^[%d%*_~]?', ''):gsub('%c', ''))
end

-- Requests

local nextAt = 0 -- GetGameTimer when the next request may go
local disabled = false

local function header(headers, name)
    for key, value in pairs(headers or {}) do
        if type(key) == 'string' and key:lower() == name then return value end
    end
end

-- status 0 when Discord never answered
local function send(path)
    local p, done = promise.new(), false
    local function finish(status, body, headers)
        if done then return end
        done = true
        p:resolve({ status = tonumber(status) or 0, body = body, headers = headers })
    end

    PerformHttpRequest(API .. path, finish, 'GET', '', HEADERS)
    SetTimeout(TIMEOUT, function() finish(0) end)
    return Citizen.Await(p)
end

-- the decoded body and the status. 404 means not in the server, 0 means Discord didn't answer
local function request(path)
    for _ = 0, RETRIES do
        if disabled then return nil, 401 end

        -- take the next free slot before waiting, so requests go out one by one
        local now = GetGameTimer()
        local at = math.max(nextAt, now)
        nextAt = at + GAP
        if at > now then Wait(at - now) end

        local reply = send(path)
        local status = reply.status

        if status == 429 then
            local seconds = tonumber(header(reply.headers, 'retry-after')) or 5
            nextAt = math.max(nextAt, GetGameTimer() + math.floor(math.min(seconds, 60) * 1000))
        elseif status >= 200 and status < 300 then
            local ok, data = pcall(json.decode, reply.body or '')
            return ok and type(data) == 'table' and data or nil, status
        else
            if status == 401 and not disabled then
                disabled = true
                log('^1[ERROR]', 'Discord says the bot token is wrong, fix gimic_discord_token and restart')
            end
            return nil, status
        end
    end
    return nil, 429
end

-- Players

-- playerId -> { ok, member, roles, username, avatar, at, expires }
-- ok is false when Discord couldn't say, member is false when they aren't linked or in the server
local members = {}
local loading = {}

local function discordId(playerId)
    local id = GetPlayerIdentifierByType(playerId, 'discord')
    return id and id:match('^discord:(%d+)$')
end

local function lookup(playerId)
    local id = discordId(playerId)
    if not id then return { ok = true, member = false, roles = {} } end

    local data, status = request(('guilds/%s/members/%s'):format(GUILD, id))
    if data then
        local user = data.user or {}
        local avatar = user.avatar and ('https://cdn.discordapp.com/avatars/%s/%s.%s'):format(id, user.avatar, user.avatar:find('^a_') and 'gif' or 'png')
        local roles = {}
        for i, role in ipairs(data.roles or {}) do roles[i] = tostring(role) end
        return { ok = true, member = true, roles = roles, username = user.global_name or user.username, avatar = avatar }
    end
    if status == 404 then return { ok = true, member = false, roles = {} } end

    -- Discord couldn't say, keep what we knew for a short while
    local known = members[playerId]
    if known and known.ok then return { ok = true, member = known.member, roles = known.roles, username = known.username, avatar = known.avatar, failed = true } end
    return { ok = false, member = false, roles = {}, failed = true }
end

-- waits for Discord, nil when the player left meanwhile
local function load(playerId)
    if loading[playerId] then return Citizen.Await(loading[playerId]) end
    if not GetPlayerName(playerId) then return end

    local p = promise.new()
    loading[playerId] = p

    local ok, entry = pcall(lookup, playerId)
    if not ok then
        log('^1[ERROR]', 'reading Discord for player %s failed: %s', playerId, entry)
        entry = { ok = false, member = false, roles = {}, failed = true }
    end

    local now = os.time()
    entry.at, entry.expires = now, now + (entry.failed and FAIL_TTL or TTL)

    if loading[playerId] == p then
        loading[playerId] = nil
        members[playerId] = entry
    else
        entry = nil
    end
    p:resolve(entry)
    return entry
end

local function refresh(playerId)
    if not loading[playerId] and not disabled then CreateThread(function() load(playerId) end) end
end

-- the cached entry, read again in the background once stale. Waits for Discord only when
-- nothing is cached, or with fresh when it's older than LIVE_TTL, and only if the caller can wait
local function get(playerId, fresh)
    playerId = tonumber(playerId)
    if not playerId then return end

    local entry, now = members[playerId], os.time()
    if entry and now < entry.expires and not (fresh and now - entry.at >= LIVE_TTL) then return entry end

    if coroutine.isyieldable() and (fresh or not entry) then return load(playerId) or entry end
    refresh(playerId)
    return entry
end

local function hasRole(roles, role)
    role = tostring(role)
    for _, id in ipairs(roles) do
        if id == role then return true end
    end
    return false
end

local function roleNumbers(roles)
    local list = {}
    for i, role in ipairs(roles) do list[i] = tonumber(role) end
    return list
end

-- Events

-- sent once by the client, ignored while anything is cached so it can't be spammed
RegisterNetEvent('gimic-discordapi:playerConnected', function()
    local playerId = source
    if members[playerId] or loading[playerId] or disabled then return end

    local entry = load(playerId)
    if not (entry and entry.ok and Config.logConnections) then return end

    local name = plain(GetPlayerName(playerId))
    if entry.member then
        log('^7[INFO]', '%s (id %s) joined, Discord %s', name, playerId, plain(entry.username))
    else
        log('^7[INFO]', '%s (id %s) joined without Discord linked or is not in the Discord server', name, playerId)
    end
end)

AddEventHandler('playerDropped', function()
    members[source] = nil
    loading[source] = nil
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    if not TOKEN:find('%S') then
        disabled = true
        return log('^1[ERROR]', 'no bot token, add set gimic_discord_token "your-token" to server.cfg')
    end
    if not GUILD:find('%S') then
        disabled = true
        return log('^1[ERROR]', 'the guild id in config.lua is empty')
    end

    local guild, status = request('guilds/' .. GUILD)
    if guild and guild.name then
        log('^7[INFO]', 'linked to %s (%s)', plain(guild.name), GUILD)
    elseif status == 403 or status == 404 then
        log('^1[ERROR]', 'Discord refused guild %s (%s), check the guild id and that the bot is in the server', GUILD, status)
    elseif status ~= 401 then
        log('^3[WARN]', 'could not reach Discord (status %s), players are read once it answers', status)
    end

    -- after a restart, read the players already online
    for _, id in ipairs(GetPlayers()) do refresh(tonumber(id)) end
end)

-- Exports

exports('getPlayerRoles', function(playerId)
    local entry = get(playerId)
    return entry and entry.ok and roleNumbers(entry.roles) or nil
end)

-- role is one id or a list, a list also returns the id that matched
exports('doesPlayerHaveRole', function(playerId, role)
    local entry = get(playerId)
    if not (entry and entry.ok) then return false end

    if type(role) ~= 'table' then return hasRole(entry.roles, role) end
    for _, id in ipairs(role) do
        if hasRole(entry.roles, id) then return true, id end
    end
    return false
end)

exports('getPlayerUsername', function(playerId)
    local entry = get(playerId)
    return entry and entry.username
end)

exports('getPlayerAvatar', function(playerId)
    local entry = get(playerId)
    return entry and entry.avatar
end)

exports('getPlayerData', function(playerId)
    local entry = get(playerId)
    if not (entry and entry.member) then return end
    return { username = entry.username, avatar = entry.avatar, roles = roleNumbers(entry.roles) }
end)

exports('getPlayerRolesLive', function(playerId)
    local entry = get(playerId, true)
    return entry and entry.ok and { table.unpack(entry.roles) } or {}
end)

exports('getPlayerRolesResult', function(playerId)
    local entry = get(playerId, true)
    if not (entry and entry.ok) then return { ok = false } end
    return { ok = true, roles = { table.unpack(entry.roles) } }
end)

exports('clearPlayerCache', function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end

    members[playerId] = nil
    refresh(playerId)
end)
