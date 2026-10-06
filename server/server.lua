local format = string.format
local Discord <const> = {
    BASE_URL = 'https://discordapp.com/api',
    HEADERS = {
        ['Content-Type'] = 'application/json',
        ['Authorization'] = ('Bot %s'):format(Config.botToken)
    }
}

local function log(message, ...)
    print(format('^7[^2GIMIC^7] ^5DISCORD^7: ^0%s^7', format(message, ...)))
end

local function trim(str)
    return str and str:gsub("^%s*(.-)%s*$", "%1") or str
end

local function tableContains(tbl, val)
    for _, v in ipairs(tbl) do
        if v == val then return true end
    end
    return false
end

local function formatEndpoint(path)
    return ('%s/%s'):format(Discord.BASE_URL, path:gsub('^/+', ''))
end


function Discord.fetch(endpoint)
    local p = promise.new()
    PerformHttpRequest(formatEndpoint(endpoint), function(status, response)
        if status ~= 200 or not response then
            p:resolve(nil)
            return
        end
        p:resolve(json.decode(response))
    end, 'GET', '', Discord.HEADERS)
    return p
end

function Discord.getGuildMember(guildId, userId)
    return Discord.fetch(('guilds/%s/members/%s'):format(guildId, userId))
end

function Discord.getGuildInfo(guildId)
    return Discord.fetch(('guilds/%s'):format(guildId))
end

local Players = {
    cache = {},
    pending = {}
}

function Players.getIdentifiers(playerId)
    if not playerId or not GetPlayerName(playerId) then return nil end

    local identifiers = {}
    for _, id in ipairs(GetPlayerIdentifiers(playerId)) do
        local prefix, value = id:match("([^:]+):(.+)")
        if prefix then identifiers[prefix] = value end
    end
    return identifiers
end

local function processRoles(roles)
    local processed = {}
    for _, role in ipairs(roles or {}) do
        table.insert(processed, tonumber(role))
    end
    return processed
end

local function getAvatarUrl(user, discordId)
    if not (user and user.avatar) then return nil end
    return ('https://cdn.discordapp.com/avatars/%s/%s.%s'):format(
        discordId,
        user.avatar,
        user.avatar:sub(1, 2) == 'a_' and 'gif' or 'png'
    )
end

function Players.getDiscordData(playerId, options)
    options = options or { rolesOnly = false }
    local identifiers = Players.getIdentifiers(playerId)
    if not identifiers or not identifiers.discord then return nil end

    local memberData = Citizen.Await(Discord.getGuildMember(Config.guildId, identifiers.discord))
    if not memberData then return nil end

    local roles = processRoles(memberData.roles)
    if options.rolesOnly then return roles end

    local user = memberData.user
    return {
        username = user and (user.global_name or user.username),
        avatar = getAvatarUrl(user, identifiers.discord),
        roles = roles
    }
end

function Players.hasRole(playerId, role)
    local roles = Players.getCachedData(playerId, 'roles')
    if not roles then return false end

    if type(role) == 'table' then
        for _, r in ipairs(role) do
            if tableContains(roles, r) then
                return true, r
            end
        end
        return false
    end

    return tableContains(roles, role)
end

function Players.getCachedData(playerId, key)
    if not Players.cache[playerId] then return nil end
    return key and Players.cache[playerId][key] or Players.cache[playerId]
end

local ROLE_CACHE_TTL <const> = 300
local ROLE_CACHE_FAIL_TTL <const> = 300

Players.roleCache = {}

local roleFetches = {}

local function fetchRoles(playerId)
    local existing = roleFetches[playerId]
    if existing then return Citizen.Await(existing) end

    local p = promise.new()
    roleFetches[playerId] = p

    local roles = Players.getDiscordData(playerId, { rolesOnly = true })
    local valid = type(roles) == 'table'

    local entry = {
        ok = valid,
        roles = valid and roles or {},
        expires = os.time() + (valid and ROLE_CACHE_TTL or ROLE_CACHE_FAIL_TTL)
    }

    Players.roleCache[playerId] = entry
    roleFetches[playerId] = nil
    p:resolve(entry)

    return entry
end

local function resolveRoles(playerId)
    local cached = Players.getCachedData(playerId, 'roles')
    if cached then return true, cached end

    local entry = Players.roleCache[playerId]
    if entry and os.time() < entry.expires then
        return entry.ok, entry.roles
    end

    entry = fetchRoles(playerId)
    return entry.ok, entry.roles
end

local function rolesToStrings(roles)
    local out = {}
    for i = 1, #roles do
        out[i] = tostring(roles[i])
    end
    return out
end

local CONNECT_RETRY <const> = 60
local connectAttempt = {}

RegisterNetEvent('gimic-discordapi:playerConnected', function()
    local playerId = source
    if Players.cache[playerId] or Players.pending[playerId] then return end

    local last = connectAttempt[playerId]
    if last and os.time() - last < CONNECT_RETRY then return end
    connectAttempt[playerId] = os.time()

    Players.pending[playerId] = true

    local discordData = Players.getDiscordData(playerId)
    Players.pending[playerId] = nil

    if not discordData then
        local playerName = GetPlayerName(playerId)
        log('^7[^2PLAYER JOINED^7] ^5%s^7 (^3ID: ^3%s^7) - ^1No Discord^7', playerName, playerId)
        return
    end

    Players.cache[playerId] = discordData

    if Config.logConnections then
        local playerName = GetPlayerName(playerId)
        log('^7[^2PLAYER JOINED^7] ^5%s^7 (^3ID: ^3%s^7) - ^2Discord: ^7%s', playerName, playerId, discordData.username)
    end
end)

AddEventHandler('playerDropped', function()
    local playerId = source
    Players.cache[playerId] = nil
    Players.pending[playerId] = nil

    Players.roleCache[playerId] = nil
    roleFetches[playerId] = nil
    connectAttempt[playerId] = nil
end)

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    if not Config.botToken or trim(Config.botToken) == '' then
        return log('^1Invalid Discord bot token in Configuration^0')
    end

    if not Config.guildId or trim(Config.guildId) == '' then
        return log('^1Invalid Discord guild ID in Configuration^0')
    end

    local guildInfo = Citizen.Await(Discord.getGuildInfo(Config.guildId))
    if not guildInfo or not guildInfo.name then
        return log('^1Failed to authenticate with Discord. Please verify your Configuration^0')
    end

    local guildName = trim(guildInfo.name:gsub('[%c%z]', ''))
    log('^2[LINKED]^0: ^5%s^0 (%s)', guildName, Config.guildId)
end)

exports('getPlayerRoles', function(playerId) return Players.getCachedData(playerId, 'roles') end)

exports('doesPlayerHaveRole', function(playerId, role) return Players.hasRole(playerId, role) end)

exports('getPlayerUsername', function(playerId) return Players.getCachedData(playerId, 'username') end)

exports('getPlayerAvatar', function(playerId) return Players.getCachedData(playerId, 'avatar') end)

exports('getPlayerData', function(playerId) return Players.getCachedData(playerId) end)


exports('getPlayerRolesLive', function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return {} end

    local _, roles = resolveRoles(playerId)

    return rolesToStrings(roles)
end)

exports('getPlayerRolesResult', function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return { ok = false } end

    local ok, roles = resolveRoles(playerId)
    if not ok then return { ok = false } end

    return { ok = true, roles = rolesToStrings(roles) }
end)

exports('clearPlayerCache', function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end

    Players.cache[playerId] = nil
    Players.roleCache[playerId] = nil
    connectAttempt[playerId] = nil
end)
