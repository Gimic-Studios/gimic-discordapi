local format = string.format

-- the server.cfg convar wins over config.lua
local convarToken <const> = GetConvar('gimic_discord_token', '')
local botToken <const> = convarToken ~= '' and convarToken or Config.botToken or ''

local BASE_URL <const> = 'https://discord.com/api/v10'
local HEADERS <const> = {
    ['Content-Type'] = 'application/json',
    ['Authorization'] = ('Bot %s'):format(botToken)
}

local MEMBER_TTL <const> = 300     -- seconds a player's roles, name and avatar are kept before they're read again
local LIVE_TTL <const> = 60        -- the Live and Result exports read again after this, permissions follow Discord quickly
local FAIL_TTL <const> = 30        -- seconds before a lookup Discord didn't answer is tried again
local REQUEST_GAP <const> = 100    -- ms between requests, so a full server joining at once stays under Discord's limit
local REQUEST_TIMEOUT <const> = 15000 -- ms before a request Discord never answered counts as failed
local MAX_RETRIES <const> = 3      -- times a rate limited request is sent again

-- same console style as the other Gimic resources: the name in the brand orange, the message in white
local PREFIX <const> = ('\27[38;2;255;122;24m[%s]\27[0m'):format(GetCurrentResourceName())

local function write(tag, message, ...)
    print(format('%s %s %s^7', PREFIX, tag, format(message, ...)))
end

local function info(message, ...)
    write('^7[INFO]', message, ...)
end

local function warn(message, ...)
    write('^3[WARN]', message, ...)
end

local function fail(message, ...)
    write('^1[ERROR]', message, ...)
end

local function trim(str)
    return str and str:gsub("^%s*(.-)%s*$", "%1") or str
end

-- drops ^ colour codes and control characters so names log cleanly
local function plain(text)
    return (tostring(text):gsub('%^[%d%*_~]?', ''):gsub('%c', ''))
end

-- Requests ------------------------------------------------------------------------------------------

local nextSlot = 0     -- GetGameTimer when the next request may go
local pausedUntil = 0  -- GetGameTimer, Discord asked us to wait until then
local disabled = false -- no token or guild id, or Discord said the token is wrong
local warned = {}      -- statuses already explained in the console

-- header names come back in whatever case Discord sent
local function headerOf(headers, name)
    if type(headers) ~= 'table' then return nil end
    local wanted = name:lower()
    for key, value in pairs(headers) do
        if type(key) == 'string' and key:lower() == wanted then return tostring(value) end
    end
    return nil -- tonumber() of no value at all throws
end

-- one request at a time leaves, spaced out and held while Discord asked us to wait
local function waitTurn()
    while true do
        local now = GetGameTimer()
        local at = math.max(nextSlot, pausedUntil)
        if at <= now then
            nextSlot = now + REQUEST_GAP
            return
        end
        Wait(at - now)
    end
end

-- status 0 when Discord never answered
local function send(path)
    local p = promise.new()
    local done = false
    local function finish(status, body, headers)
        if done then return end
        done = true
        p:resolve({ status = tonumber(status) or 0, body = body, headers = headers })
    end

    PerformHttpRequest(('%s/%s'):format(BASE_URL, path), finish, 'GET', '', HEADERS)
    SetTimeout(REQUEST_TIMEOUT, function() finish(0) end)
    return Citizen.Await(p)
end

local function retryAfter(reply)
    local seconds = tonumber(headerOf(reply.headers, 'Retry-After'))
    if not seconds then
        local ok, data = pcall(json.decode, reply.body or '')
        seconds = ok and type(data) == 'table' and tonumber(data.retry_after) or nil
    end
    return math.floor(math.min(math.max(seconds or 5, 0.5), 60) * 1000)
end

local function explain(status)
    if warned[status] then return end
    warned[status] = true

    if status == 401 then
        disabled = true
        fail('Discord says the bot token is wrong (401). Lookups are off until you fix gimic_discord_token and restart')
    elseif status == 403 then
        fail('Discord refused the lookup (403). Check the bot is in your Discord server and the guild id is right')
    end
end

-- the decoded answer and the status. Status 404 is a real answer (not in the server), 0 means unreachable
local function request(path)
    if disabled then return nil, 401 end

    for _ = 1, MAX_RETRIES + 1 do
        waitTurn()
        local reply = send(path)
        local status = reply.status

        -- this bucket is empty, the next request waits for it to fill again
        if headerOf(reply.headers, 'X-RateLimit-Remaining') == '0' then
            local reset = tonumber(headerOf(reply.headers, 'X-RateLimit-Reset-After'))
            if reset then pausedUntil = math.max(pausedUntil, GetGameTimer() + math.ceil(reset * 1000)) end
        end

        if status == 429 then
            pausedUntil = math.max(pausedUntil, GetGameTimer() + retryAfter(reply))
        elseif status >= 200 and status < 300 then
            local ok, data = pcall(json.decode, reply.body or '')
            if ok and type(data) == 'table' then return data, status end
            return nil, 0
        else
            explain(status)
            return nil, status
        end
    end

    return nil, 429
end

-- Members -------------------------------------------------------------------------------------------

-- playerId -> { ok, member, roles = { string ids }, username, avatar, at, expires }
-- ok = false only when Discord couldn't say. member = false for someone not linked or not in the server
local members = {}
local loading = {} -- playerId -> promise while their lookup runs

local function discordIdOf(playerId)
    for _, id in ipairs(GetPlayerIdentifiers(playerId)) do
        local value = id:match('^discord:(%d+)$')
        if value then return value end
    end
end

local function avatarOf(user, discordId)
    if not (user and user.avatar) then return nil end
    return ('https://cdn.discordapp.com/avatars/%s/%s.%s'):format(discordId, user.avatar, user.avatar:sub(1, 2) == 'a_' and 'gif' or 'png')
end

-- role ids stay strings: they are too big for JSON numbers in other languages
local function rolesOf(list)
    local roles = {}
    for _, role in ipairs(type(list) == 'table' and list or {}) do roles[#roles + 1] = tostring(role) end
    return roles
end

local function entryOf(ok, member, roles, username, avatar, ttl)
    local now = os.time()
    return { ok = ok, member = member, roles = roles, username = username, avatar = avatar, at = now, expires = now + ttl }
end

local function lookup(playerId)
    local discordId = discordIdOf(playerId)
    if not discordId then return entryOf(true, false, {}, nil, nil, MEMBER_TTL) end

    local data, status = request(('guilds/%s/members/%s'):format(Config.guildId, discordId))
    if data then
        local user = data.user
        return entryOf(true, true, rolesOf(data.roles), user and (user.global_name or user.username), avatarOf(user, discordId), MEMBER_TTL)
    end

    -- not in the server: an answer, not an outage
    if status == 404 then return entryOf(true, false, {}, nil, nil, MEMBER_TTL) end

    -- Discord couldn't say: what we knew stays in use until the next try
    local previous = members[playerId]
    if previous and previous.ok then
        return entryOf(true, previous.member, previous.roles, previous.username, previous.avatar, FAIL_TTL)
    end
    return entryOf(false, false, {}, nil, nil, FAIL_TTL)
end

-- waits for Discord. nil when the player left
local function load(playerId)
    local pending = loading[playerId]
    if pending then return Citizen.Await(pending) end
    if not GetPlayerName(playerId) then return nil end

    local p = promise.new()
    loading[playerId] = p

    local ok, entry = pcall(lookup, playerId)
    if not ok then
        fail('reading Discord for player %s failed: %s', playerId, tostring(entry))
        entry = entryOf(false, false, {}, nil, nil, FAIL_TTL)
    end

    -- they may have dropped while Discord answered
    if loading[playerId] == p then
        loading[playerId] = nil
        members[playerId] = entry
    else
        entry = nil
    end

    p:resolve(entry)
    return entry
end

local function loadLater(playerId)
    if loading[playerId] or disabled then return end
    CreateThread(function() load(playerId) end)
end

-- what's cached, read again in the background once stale. Only waits when nothing is cached yet
-- and the caller can wait
local function current(playerId)
    playerId = tonumber(playerId)
    if not playerId then return nil end

    local entry = members[playerId]
    if entry then
        if entry.expires <= os.time() then loadLater(playerId) end
        return entry
    end

    if coroutine.isyieldable() then return load(playerId) end
    loadLater(playerId)
end

-- for permission checks: waits for a fresh answer once the entry is older than LIVE_TTL
local function live(playerId)
    playerId = tonumber(playerId)
    if not playerId then return nil end

    local entry = members[playerId]
    if entry and os.time() < math.min(entry.expires, entry.at + LIVE_TTL) then return entry end

    if not coroutine.isyieldable() then
        loadLater(playerId)
        return entry
    end
    return load(playerId) or entry
end

-- numbers, like before roles were kept as strings
local function roleNumbers(roles)
    local list = {}
    for i, role in ipairs(roles) do list[i] = math.tointeger(tonumber(role)) or tonumber(role) end
    return list
end

local function copy(roles)
    return table.move(roles, 1, #roles, 1, {})
end

-- role ids can be numbers or strings
local function hasRole(roles, role)
    local wanted = tostring(role)
    for _, id in ipairs(roles) do
        if id == wanted then return true end
    end
    return false
end

-- Events --------------------------------------------------------------------------------------------

-- the client says it's in once. Only a player with nothing cached is looked up, so it can't be spammed
RegisterNetEvent('gimic-discordapi:playerConnected', function()
    local playerId = source
    if members[playerId] or loading[playerId] or disabled then return end

    local entry = load(playerId)
    if not (entry and Config.logConnections) then return end

    if entry.member then
        info('%s (id %s) joined, Discord %s', plain(GetPlayerName(playerId)), playerId, plain(entry.username))
    elseif entry.ok then
        info('%s (id %s) joined without Discord linked or is not in the Discord server', plain(GetPlayerName(playerId)), playerId)
    end
end)

AddEventHandler('playerDropped', function()
    local playerId = source
    members[playerId] = nil
    loading[playerId] = nil
end)

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    if trim(botToken) == '' then
        disabled = true
        return fail('no bot token, add set gimic_discord_token "your-token" to server.cfg')
    end

    if not Config.guildId or trim(Config.guildId) == '' then
        disabled = true
        return fail('the guild id in config.lua is empty')
    end

    local guild, status = request(('guilds/%s'):format(Config.guildId))
    if not guild or not guild.name then
        if status == 404 then
            fail('no Discord server has the guild id %s, check config.lua', Config.guildId)
        elseif status ~= 401 and status ~= 403 then
            warn('could not reach Discord (status %s), players are read once it answers', tostring(status))
        end
    else
        info('linked to %s (%s)', trim(guild.name:gsub('[%c%z]', '')), Config.guildId)
    end

    -- after a restart, players already online are read without waiting for their client
    for _, id in ipairs(GetPlayers()) do loadLater(tonumber(id)) end
end)

-- Exports -------------------------------------------------------------------------------------------

exports('getPlayerRoles', function(playerId)
    local entry = current(playerId)
    if not (entry and entry.ok) then return nil end
    return roleNumbers(entry.roles)
end)

-- role can be one id or a list, a list also gives back the id that matched
exports('doesPlayerHaveRole', function(playerId, role)
    local entry = current(playerId)
    if not (entry and entry.ok) then return false end

    if type(role) == 'table' then
        for _, r in ipairs(role) do
            if hasRole(entry.roles, r) then return true, r end
        end
        return false
    end
    return hasRole(entry.roles, role)
end)

exports('getPlayerUsername', function(playerId)
    local entry = current(playerId)
    return entry and entry.username or nil
end)

exports('getPlayerAvatar', function(playerId)
    local entry = current(playerId)
    return entry and entry.avatar or nil
end)

-- nil for someone not linked or not in the Discord server
exports('getPlayerData', function(playerId)
    local entry = current(playerId)
    if not (entry and entry.member) then return nil end
    return { username = entry.username, avatar = entry.avatar, roles = roleNumbers(entry.roles) }
end)

-- string ids, read again when older than a minute
exports('getPlayerRolesLive', function(playerId)
    local entry = live(playerId)
    return entry and entry.ok and copy(entry.roles) or {}
end)

-- { ok = true, roles = { string ids } }, or { ok = false } when Discord couldn't say
exports('getPlayerRolesResult', function(playerId)
    local entry = live(playerId)
    if not (entry and entry.ok) then return { ok = false } end
    return { ok = true, roles = copy(entry.roles) }
end)

-- forgets the player and reads them again
exports('clearPlayerCache', function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end

    members[playerId] = nil
    if GetPlayerName(playerId) then loadLater(playerId) end
end)
