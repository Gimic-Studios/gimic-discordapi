CreateThread(function()
    Wait(5000)
    while not NetworkIsPlayerActive(PlayerId()) do
        Wait(2000)
    end
    TriggerServerEvent('gimic-discordapi:playerConnected')
end)
