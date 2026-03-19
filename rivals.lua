repeat task.wait() until game:IsLoaded()
print("[unlockall] Game loaded")
assert(hookmetamethod, "[ascida]: Your executor doesn't support this.")
print("[unlockall] hookmetamethod available")

for i, v in getgc() do
    if typeof(v) == "function" and string.find(debug.info(v, "s"), "AnalyticsPipelineController") then
        local orig = hookfunction(v, newcclosure(function(...)
            if checkcaller() then return orig(...) end
            return nil
        end))
        print("[unlockall] AnalyticsPipelineController hooked")
    end
end

local players           = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local httpService       = game:GetService("HttpService")
local localPlayer       = players.LocalPlayer
print("[unlockall] Services acquired")

local function waitForCharacter()
    if not localPlayer.Character then
        print("[unlockall] Waiting for character...")
        localPlayer.CharacterAdded:Wait()
    end
    task.wait(0.3)
end
waitForCharacter()
print("[unlockall] Character ready")

local function awaitChild(parent, name, limit)
    local attempts = 0
    local child
    repeat
        task.wait(1)
        child    = parent:FindFirstChild(name)
        attempts = attempts + 1
        if attempts > (limit or 20) then
            print("[unlockall] ERROR: '" .. name .. "' not found under " .. parent.Name)
            return nil
        end
    until child
    return child
end

local playerScripts = awaitChild(localPlayer, "PlayerScripts")
if not playerScripts then return end
print("[unlockall] PlayerScripts found")

local controllers = awaitChild(playerScripts, "Controllers")
if not controllers then return end
print("[unlockall] Controllers found")

local modules = awaitChild(replicatedStorage, "Modules")
if not modules then return end
print("[unlockall] Modules found")

local function waitForModule(parent, name, timeout)
    local elapsed = 0
    while not parent:FindFirstChild(name) and elapsed < timeout do
        task.wait(0.5)
        elapsed = elapsed + 0.5
    end
    return parent:FindFirstChild(name)
end

print("[unlockall] Waiting for module instances...")
local cosmeticLib = waitForModule(modules,     "CosmeticLibrary",     10)
local itemLib     = waitForModule(modules,     "ItemLibrary",         10)
local dataCtrl    = waitForModule(controllers, "PlayerDataController", 10)
local dataUtility = waitForModule(modules,     "PlayerDataUtility",   10)

print("[unlockall] CosmeticLibrary:",      cosmeticLib and "found" or "MISSING")
print("[unlockall] ItemLibrary:",          itemLib     and "found" or "MISSING")
print("[unlockall] PlayerDataController:", dataCtrl    and "found" or "MISSING")

if not cosmeticLib or not itemLib or not dataCtrl then
    print("[unlockall] ERROR: Required modules missing, aborting")
    return
end

-- ── Module references ─────────────────────────────────────────────────────────
local EnumLibrary, CosmeticLibrary, ItemLibrary, DataController, DataUtility

local loadSuccess, loadErr = pcall(function()
    print("[unlockall] Requiring CosmeticLibrary...")
    CosmeticLibrary = require(cosmeticLib)
    print("[unlockall] CosmeticLibrary OK")

    print("[unlockall] Requiring ItemLibrary...")
    ItemLibrary = require(itemLib)
    print("[unlockall] ItemLibrary OK")

    print("[unlockall] Requiring DataController...")
    DataController = require(dataCtrl)
    print("[unlockall] DataController OK")

    if dataUtility then
        DataUtility = require(dataUtility)
        print("[unlockall] DataUtility OK")
    end

    local enumLib = modules:FindFirstChild("EnumLibrary")
    if enumLib then
        print("[unlockall] Requiring EnumLibrary...")
        EnumLibrary = require(enumLib)
        print("[unlockall] EnumLibrary OK")
        if EnumLibrary and EnumLibrary.WaitForEnumBuilder then
            task.spawn(function()
                pcall(function() EnumLibrary:WaitForEnumBuilder() end)
                print("[unlockall] EnumBuilder ready")
            end)
        end
    else
        print("[unlockall] EnumLibrary not found, skipping")
    end
end)

-- Confirm cosmetics table populated (diagnostic: 1057 plain-string keys)
do
    local count = 0
    if CosmeticLibrary and CosmeticLibrary.Cosmetics then
        for _ in pairs(CosmeticLibrary.Cosmetics) do count = count + 1 end
    end
    print("[unlockall] CosmeticLibrary.Cosmetics entries:", count)
end

print("[unlockall] Module load:", tostring(loadSuccess), loadErr and tostring(loadErr) or "")

if not loadSuccess or not CosmeticLibrary or not ItemLibrary or not DataController then
    print("[unlockall] ERROR: Failed to require core modules, aborting")
    return
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function GetAllWeaponMapsTo(bool)
    local weapons = {}
    if ItemLibrary and ItemLibrary.Items then
        for name in pairs(ItemLibrary.Items) do
            if not name:find("MISSING_") then weapons[name] = bool end
        end
    end
    return weapons
end

print("[unlockall] Patching DataController ownership...")
DataController.OwnsAllWeapons     = function() return true end
DataController.GetUnlockedWeapons = function() return GetAllWeaponMapsTo(true) end
print("[unlockall] DataController ownership patched")

-- ── State ─────────────────────────────────────────────────────────────────────
local equipped  = {}   -- equipped[weaponName][cosmeticType] = clonedData
local favorites = {}   -- favorites[weaponName][cosmeticName] = bool
local constructingWeapon, viewingProfile, lastUsedWeapon
local hooksReady = false

local SKIP_COSMETIC_NAMES = {
    RANDOM_COSMETIC = true,
    NONE            = true,
    [""]            = true,
}

-- ── cloneCosmetic ─────────────────────────────────────────────────────────────
-- Diagnostic confirmed all 1057 Cosmetics keys are plain strings.
-- All previously-failing skins are DIRECT HITs (AKEY-47, AUG, Tommy Gun, etc.).
-- RENAMED_COSMETICS has 12 entries and is applied first as a safety net.
local function cloneCosmetic(name, cosmeticType, options)
    if not name or SKIP_COSMETIC_NAMES[name] then
        print("[unlockall] cloneCosmetic: skipping special name:", tostring(name))
        return nil
    end
    if not CosmeticLibrary or not CosmeticLibrary.Cosmetics then
        print("[unlockall] cloneCosmetic: CosmeticLibrary not ready")
        return nil
    end

    -- 1. Apply the game's own rename map first
    local resolvedName = (CosmeticLibrary.RENAMED_COSMETICS
        and CosmeticLibrary.RENAMED_COSMETICS[name])
        or name

    -- 2. Direct string lookup (covers all normal cases per diagnostic)
    local base = CosmeticLibrary.Cosmetics[resolvedName]

    -- 3. Case-insensitive fallback
    if not base then
        local lower = resolvedName:lower()
        for k, v in pairs(CosmeticLibrary.Cosmetics) do
            if tostring(k):lower() == lower then
                base         = v
                resolvedName = k
                print("[unlockall] cloneCosmetic: case-insensitive match:", name, "->", k)
                break
            end
        end
    end

    -- 4. Enum-based lookup (last resort)
    if not base and EnumLibrary then
        pcall(function()
            local enumId = EnumLibrary:ToEnum(resolvedName)
            if enumId then
                local candidate = CosmeticLibrary.Cosmetics[enumId]
                if candidate then
                    base = candidate
                    print("[unlockall] cloneCosmetic: enum match:", name, "->", tostring(enumId))
                end
            end
        end)
    end

    if not base then
        print("[unlockall] cloneCosmetic: FAILED for:", name, "-> resolved:", resolvedName)
        return nil
    end

    local data = {}
    for k, v in pairs(base) do data[k] = v end
    data.Name = resolvedName   -- canonical name
    data.Type = data.Type or cosmeticType
    data.Seed = math.random(1, 1000000)

    if EnumLibrary then
        pcall(function()
            local enumId = EnumLibrary:ToEnum(resolvedName)
            if enumId then
                data.Enum     = enumId
                data.ObjectID = enumId
            end
        end)
    end

    if options then
        if options.inverted      then data.Inverted         = true end
        if options.favoritesOnly then data.OnlyUseFavorites = true end
    end

    return data
end

-- ── Config persistence ────────────────────────────────────────────────────────
local saveFile = "unlockall/config.json"

local function saveConfig()
    if not writefile then return end
    task.spawn(function()
        pcall(function()
            local config = { equipped = {}, favorites = favorites }
            for weapon, cosmetics in pairs(equipped) do
                config.equipped[weapon] = {}
                for cosmeticType, cosmeticData in pairs(cosmetics) do
                    if cosmeticData and cosmeticData.Name then
                        config.equipped[weapon][cosmeticType] = {
                            name     = cosmeticData.Name,
                            seed     = cosmeticData.Seed,
                            inverted = cosmeticData.Inverted,
                        }
                    end
                end
            end
            if not isfolder("unlockall") then makefolder("unlockall") end
            writefile(saveFile, httpService:JSONEncode(config))
            print("[unlockall] Config saved")
        end)
    end)
end

local function loadConfig()
    if not readfile or not isfile or not isfile(saveFile) then
        print("[unlockall] No config file, starting fresh")
        return
    end
    print("[unlockall] Loading config...")
    pcall(function()
        local config = httpService:JSONDecode(readfile(saveFile))
        if config.equipped then
            for weapon, cosmetics in pairs(config.equipped) do
                equipped[weapon] = {}
                for cosmeticType, cosmeticData in pairs(cosmetics) do
                    local cloned = cloneCosmetic(
                        cosmeticData.name, cosmeticType, { inverted = cosmeticData.inverted }
                    )
                    if cloned then
                        cloned.Seed                      = cosmeticData.seed
                        equipped[weapon][cosmeticType]   = cloned
                        print("[unlockall] Loaded:", weapon, cosmeticType, cosmeticData.name)
                    else
                        print("[unlockall] FAILED to clone:", weapon, cosmeticType, cosmeticData.name)
                    end
                end
            end
        end
        favorites = config.favorites or {}
        print("[unlockall] Config load complete")
    end)
end

-- ── Patch CosmeticLibrary ─────────────────────────────────────────────────────
print("[unlockall] Patching CosmeticLibrary...")
CosmeticLibrary.OwnsCosmeticNormally     = function() return true end
CosmeticLibrary.OwnsCosmeticUniversally  = function() return true end
CosmeticLibrary.OwnsCosmeticForSomething = function() return true end
CosmeticLibrary.OwnsCosmeticForWeapon    = function() return true end
local originalOwnsCosmetic = CosmeticLibrary.OwnsCosmetic
CosmeticLibrary.OwnsCosmetic = function(self, inventory, name, weapon)
    if name and name:find("MISSING_") then
        return originalOwnsCosmetic(self, inventory, name, weapon)
    end
    return true
end
print("[unlockall] CosmeticLibrary patched")

-- ── Patch DataController.Get ──────────────────────────────────────────────────
local originalGet = DataController.Get
DataController.Get = function(self, key)
    local data = originalGet(self, key)
    if key == "CosmeticInventory" then
        return setmetatable({}, { __index = function() return true end })
    end
    if key == "FavoritedCosmetics" then
        local result = {}
        if data then for k, v in pairs(data) do result[k] = v end end
        for weapon, favs in pairs(favorites) do
            result[weapon] = result[weapon] or {}
            for name, isFav in pairs(favs) do result[weapon][name] = isFav end
        end
        return result
    end
    return data
end
print("[unlockall] DataController.Get patched")

-- ── Patch DataController.GetWeaponData ───────────────────────────────────────
local originalGetWeaponData = DataController.GetWeaponData
DataController.GetWeaponData = function(self, weaponName)
    local data         = { Unlocked = true, Level = 100, XP = 99999 }
    local originalData = originalGetWeaponData(self, weaponName)
    if originalData then
        for k, v in pairs(originalData) do data[k] = v end
    end
    if equipped[weaponName] then
        for cosmeticType, cosmeticData in pairs(equipped[weaponName]) do
            data[cosmeticType] = cosmeticData
        end
    end
    return data
end
print("[unlockall] DataController.GetWeaponData patched")

-- ── FighterController ─────────────────────────────────────────────────────────
local FighterController
task.spawn(function()
    local fc = controllers:FindFirstChild("FighterController")
    if fc then
        print("[unlockall] Requiring FighterController...")
        pcall(function() FighterController = require(fc) end)
        print("[unlockall] FighterController:", FighterController and "OK" or "FAILED")
    else
        print("[unlockall] FighterController not found")
    end
end)

-- ── __namecall hook ───────────────────────────────────────────────────────────
task.spawn(function()
    print("[unlockall] Waiting for Remotes...")
    local remotes            = replicatedStorage:WaitForChild("Remotes", 15)
    local dataRemotes        = remotes and remotes:WaitForChild("Data", 10)
    local equipRemote        = dataRemotes and dataRemotes:WaitForChild("EquipCosmetic", 10)
    local favoriteRemote     = dataRemotes and dataRemotes:FindFirstChild("FavoriteCosmetic")
    local replicationRemotes = remotes and remotes:FindFirstChild("Replication")
    local fighterRemotes     = replicationRemotes and replicationRemotes:FindFirstChild("Fighter")
    local useItemRemote      = fighterRemotes and fighterRemotes:FindFirstChild("UseItem")

    print("[unlockall] equipRemote:",    equipRemote    and equipRemote:GetFullName()    or "MISSING")
    print("[unlockall] favoriteRemote:", favoriteRemote and favoriteRemote:GetFullName() or "MISSING")
    print("[unlockall] useItemRemote:",  useItemRemote  and useItemRemote:GetFullName()  or "MISSING")

    if not equipRemote then
        print("[unlockall] ERROR: EquipCosmetic not found, hook NOT installed")
        return
    end

    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if getnamecallmethod() ~= "FireServer" then return oldNamecall(self, ...) end
        local args = { ... }

        -- Track last used weapon for finisher injection
        if useItemRemote and self == useItemRemote and FighterController then
            task.spawn(function()
                pcall(function()
                    local fighter = FighterController:GetFighter(localPlayer)
                    if fighter and fighter.Items then
                        for _, item in pairs(fighter.Items) do
                            if item:Get("ObjectID") == args[1] then
                                lastUsedWeapon = item.Name
                                print("[unlockall] lastUsedWeapon:", lastUsedWeapon)
                                break
                            end
                        end
                    end
                end)
            end)
        end

        if self == equipRemote then
            local weaponName, cosmeticType, cosmeticName = args[1], args[2], args[3]
            local options = args[4] or {}
            print("[unlockall] equipRemote:", weaponName, cosmeticType, cosmeticName)

            -- Pass special internal names straight to the server unchanged
            if SKIP_COSMETIC_NAMES[cosmeticName] then
                print("[unlockall] Passing through special name:", cosmeticName)
                return oldNamecall(self, ...)
            end

            equipped[weaponName] = equipped[weaponName] or {}

            if not cosmeticName or cosmeticName == "None" or cosmeticName == "" then
                print("[unlockall] Clearing", cosmeticType, "on", weaponName)
                equipped[weaponName][cosmeticType] = nil
                if not next(equipped[weaponName]) then equipped[weaponName] = nil end
            else
                local cloned = cloneCosmetic(cosmeticName, cosmeticType, {
                    inverted      = options.IsInverted,
                    favoritesOnly = options.OnlyUseFavorites,
                })
                if cloned then
                    equipped[weaponName][cosmeticType] = cloned
                    print("[unlockall] Equipped", cosmeticName, "->", cosmeticType, "on", weaponName)
                else
                    print("[unlockall] cloneCosmetic nil for", cosmeticName, "- passing through")
                    return oldNamecall(self, ...)
                end
            end

            task.spawn(function()
                local waited = 0
                while not hooksReady and waited < 10 do
                    task.wait(0.1)
                    waited = waited + 0.1
                end
                print("[unlockall] Calling Replicate WeaponInventory...")
                local ok, err = pcall(function()
                    DataController.CurrentData:Replicate("WeaponInventory")
                end)
                print("[unlockall] Replicate:", tostring(ok), err and tostring(err) or "")
                saveConfig()
            end)
            return  -- suppress the original FireServer call
        end

        if favoriteRemote and self == favoriteRemote then
            print("[unlockall] favoriteRemote:", args[1], args[2], tostring(args[3]))
            favorites[args[1]]         = favorites[args[1]] or {}
            favorites[args[1]][args[2]] = args[3] or nil
            saveConfig()
            return  -- suppress the original FireServer call
        end

        return oldNamecall(self, ...)
    end))
    print("[unlockall] __namecall hook installed")
end)

-- ── ItemLibrary image patch ───────────────────────────────────────────────────
print("[unlockall] Patching ItemLibrary.GetViewModelImageFromWeaponData...")
local originalGetViewModelImage = ItemLibrary.GetViewModelImageFromWeaponData
ItemLibrary.GetViewModelImageFromWeaponData = function(self, weaponData, highRes)
    if not weaponData then
        return originalGetViewModelImage(self, weaponData, highRes)
    end
    local weaponName    = weaponData.Name
    local equippedSkins = equipped[weaponName]
    local shouldShowSkin = equippedSkins and equippedSkins.Skin and (
        (weaponData.Skin and weaponData.Skin == equippedSkins.Skin)
        or viewingProfile == localPlayer
    )
    if shouldShowSkin then
        local skinInfo = self.ViewModels[equippedSkins.Skin.Name]
        if skinInfo then
            return skinInfo[highRes and "ImageHighResolution" or "Image"] or skinInfo.Image
        end
    end
    return originalGetViewModelImage(self, weaponData, highRes)
end
print("[unlockall] GetViewModelImageFromWeaponData patched")

-- ── Viewmodel / replication hooks (3 s delay) ─────────────────────────────────
task.spawn(function()
    print("[unlockall] Viewmodel hooks: waiting 3s...")
    task.wait(3)

    -- ClientItem._CreateViewModel
    pcall(function()
        print("[unlockall] Hooking ClientItem._CreateViewModel...")
        local ClientItem = require(
            playerScripts.Modules.ClientReplicatedClasses.ClientFighter.ClientItem
        )
        if not ClientItem._CreateViewModel then
            print("[unlockall] ClientItem._CreateViewModel not found")
            return
        end
        local orig = ClientItem._CreateViewModel
        ClientItem._CreateViewModel = function(self, viewmodelRef)
            local weaponName   = self.Name
            local weaponPlayer = self.ClientFighter and self.ClientFighter.Player
            constructingWeapon = (weaponPlayer == localPlayer) and weaponName or nil
            if weaponPlayer == localPlayer
                    and equipped[weaponName] and equipped[weaponName].Skin
                    and viewmodelRef then
                pcall(function()
                    local dataKey = self:ToEnum("Data")
                    local skinKey = self:ToEnum("Skin")
                    local nameKey = self:ToEnum("Name")
                    if viewmodelRef[dataKey] then
                        viewmodelRef[dataKey][skinKey] = equipped[weaponName].Skin
                        viewmodelRef[dataKey][nameKey] = equipped[weaponName].Skin.Name
                        print("[unlockall] _CreateViewModel: skin injected for", weaponName)
                    elseif viewmodelRef.Data then
                        viewmodelRef.Data.Skin = equipped[weaponName].Skin
                        viewmodelRef.Data.Name = equipped[weaponName].Skin.Name
                        print("[unlockall] _CreateViewModel: skin injected (fallback) for", weaponName)
                    end
                end)
            end
            local result = orig(self, viewmodelRef)
            constructingWeapon = nil
            return result
        end
        print("[unlockall] ClientItem._CreateViewModel hooked")
    end)

    -- ClientViewModel.GetWrap / ClientViewModel.new
    pcall(function()
        print("[unlockall] Hooking ClientViewModel...")
        local vmMod = playerScripts
            .Modules.ClientReplicatedClasses.ClientFighter.ClientItem
            :FindFirstChild("ClientViewModel")
        if not vmMod then
            print("[unlockall] ClientViewModel not found")
            return
        end
        local ClientViewModel = require(vmMod)

        if ClientViewModel.GetWrap then
            local orig = ClientViewModel.GetWrap
            ClientViewModel.GetWrap = function(self)
                local weaponName   = self.ClientItem and self.ClientItem.Name
                local weaponPlayer = self.ClientItem
                    and self.ClientItem.ClientFighter
                    and self.ClientItem.ClientFighter.Player
                if weaponName and weaponPlayer == localPlayer
                        and equipped[weaponName] and equipped[weaponName].Wrap then
                    print("[unlockall] GetWrap: returning wrap for", weaponName)
                    return equipped[weaponName].Wrap
                end
                return orig(self)
            end
            print("[unlockall] ClientViewModel.GetWrap hooked")
        else
            print("[unlockall] ClientViewModel.GetWrap not found")
        end

        local origNew = ClientViewModel.new
        ClientViewModel.new = function(replicatedData, clientItem)
            local weaponPlayer = clientItem.ClientFighter and clientItem.ClientFighter.Player
            local weaponName   = constructingWeapon or clientItem.Name
            if weaponPlayer == localPlayer and equipped[weaponName] then
                pcall(function()
                    local ReplicatedClass = require(replicatedStorage.Modules.ReplicatedClass)
                    local dataKey         = ReplicatedClass:ToEnum("Data")
                    replicatedData[dataKey] = replicatedData[dataKey] or {}
                    local cosmetics = equipped[weaponName]
                    if cosmetics.Skin then
                        replicatedData[dataKey][ReplicatedClass:ToEnum("Skin")]  = cosmetics.Skin
                        print("[unlockall] ClientViewModel.new: Skin for", weaponName)
                    end
                    if cosmetics.Wrap then
                        replicatedData[dataKey][ReplicatedClass:ToEnum("Wrap")]  = cosmetics.Wrap
                        print("[unlockall] ClientViewModel.new: Wrap for", weaponName)
                    end
                    if cosmetics.Charm then
                        replicatedData[dataKey][ReplicatedClass:ToEnum("Charm")] = cosmetics.Charm
                        print("[unlockall] ClientViewModel.new: Charm for", weaponName)
                    end
                end)
            end
            local result = origNew(replicatedData, clientItem)
            if weaponPlayer == localPlayer and equipped[weaponName]
                    and equipped[weaponName].Wrap and result._UpdateWrap then
                task.spawn(function()
                    result:_UpdateWrap()
                    task.wait(0.1)
                    if not result._destroyed then result:_UpdateWrap() end
                end)
            end
            return result
        end
        print("[unlockall] ClientViewModel.new hooked")
    end)

    -- ViewProfile.Fetch
    pcall(function()
        print("[unlockall] Hooking ViewProfile.Fetch...")
        local ViewProfile = require(playerScripts.Modules.Pages.ViewProfile)
        if not (ViewProfile and ViewProfile.Fetch) then
            print("[unlockall] ViewProfile.Fetch not found")
            return
        end
        local orig = ViewProfile.Fetch
        ViewProfile.Fetch = function(self, targetPlayer)
            viewingProfile = targetPlayer
            print("[unlockall] ViewProfile:", targetPlayer and targetPlayer.Name or "nil")
            return orig(self, targetPlayer)
        end
        print("[unlockall] ViewProfile.Fetch hooked")
    end)

    -- ClientEntity.ReplicateFromServer (finisher injection)
    pcall(function()
        print("[unlockall] Hooking ClientEntity.ReplicateFromServer...")
        local ClientEntity = require(
            playerScripts.Modules.ClientReplicatedClasses.ClientEntity
        )
        if not ClientEntity.ReplicateFromServer then
            print("[unlockall] ClientEntity.ReplicateFromServer not found")
            return
        end
        local orig = ClientEntity.ReplicateFromServer
        ClientEntity.ReplicateFromServer = function(self, action, ...)
            if action == "FinisherEffect" then
                local args          = { ... }
                local killerName    = args[3]
                local decodedKiller = killerName
                if type(killerName) == "userdata" and EnumLibrary and EnumLibrary.FromEnum then
                    pcall(function() decodedKiller = EnumLibrary:FromEnum(killerName) end)
                end
                local isOurKill = tostring(decodedKiller) == localPlayer.Name
                    or tostring(decodedKiller):lower() == localPlayer.Name:lower()
                if isOurKill and lastUsedWeapon
                        and equipped[lastUsedWeapon]
                        and equipped[lastUsedWeapon].Finisher then
                    local finisherData = equipped[lastUsedWeapon].Finisher
                    local finisherEnum = finisherData.Enum
                    if not finisherEnum and EnumLibrary then
                        pcall(function()
                            finisherEnum = EnumLibrary:ToEnum(finisherData.Name)
                        end)
                    end
                    if finisherEnum then
                        print("[unlockall] FinisherEffect: injecting for", lastUsedWeapon)
                        args[1] = finisherEnum
                        return orig(self, action, table.unpack(args))
                    end
                end
            end
            return orig(self, action, ...)
        end
        print("[unlockall] ClientEntity.ReplicateFromServer hooked")
    end)

    hooksReady = true
    print("[unlockall] hooksReady = true. Flushing equipped cosmetics...")
    local ok, err = pcall(function()
        DataController.CurrentData:Replicate("WeaponInventory")
    end)
    print("[unlockall] Flush:", tostring(ok), err and tostring(err) or "")
end)

-- ── Load saved config ─────────────────────────────────────────────────────────
print("[unlockall] Loading config...")
loadConfig()
print("[unlockall] Script fully initialised")
