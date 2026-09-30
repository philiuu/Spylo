--[[
    BANANACAT AUTO SPY v5.0 — FULL INSPECTOR
    - Click NPC  → dump model/attributes/remote calls liên quan
    - Auto log mọi RemoteEvent/RemoteFunction được FireServer/InvokeServer
    - Scan cổng dịch chuyển (ProximityPrompt, TouchInterest, Teleport part)
    - Scan anticheat (ModuleScript tên Anti/AC/Security, Remote có tên lạ)
    - Xuất .lua + .json
]]

local Players     = game:GetService("Players")
local Workspace   = game:GetService("Workspace")
local StarterGui  = game:GetService("StarterGui")
local CoreGui     = game:GetService("CoreGui")
local RS          = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UIS         = game:GetService("UserInputService")
local RunService  = game:GetService("RunService")
local plr         = Players.LocalPlayer

-- ================================================================
-- 1. DATABASE
-- ================================================================
local DB = {
    Islands       = {},   -- [name] = "CFrame.new(...)"
    NPCs          = {},   -- [name] = {... full dump ...}
    Enemies       = {},
    Teleports     = {},   -- [name] = {cf, prompt, touch, class}
    AntiCheat     = {},   -- [name] = {className, path, notes}
    RemoteLog     = {},   -- [tick] = {kind, path, args}
    NPCInteractLog= {},   -- [npcName] = { [remote] = count }
}

local MAX_LOG = 5000

local function PushLog(tbl, key, val)
    tbl[key] = val
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    if n > MAX_LOG then
        -- xóa entry cũ nhất
        local oldest, oldestK = math.huge, nil
        for k in pairs(tbl) do
            if type(k) == "number" and k < oldest then oldest, oldestK = k, k end
        end
        if oldestK then tbl[oldestK] = nil end
    end
end

-- ================================================================
-- 2. UTILS
-- ================================================================
local function Notify(title, text)
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = 3 })
    end)
end

local function GetFullPath(inst)
    local parts, cur = {}, inst
    while cur and cur ~= game do
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
    end
    return table.concat(parts, ".")
end

local function SerializeValue(v)
    local t = typeof(v)
    if t == "Vector3"       then return string.format("Vector3.new(%.4f,%.4f,%.4f)", v.X, v.Y, v.Z) end
    if t == "CFrame"        then return string.format("CFrame.new(%.4f,%.4f,%.4f)", v.X, v.Y, v.Z) end
    if t == "Color3"        then return string.format("Color3.fromRGB(%d,%d,%d)", v.R*255, v.G*255, v.B*255) end
    if t == "Instance"      then return GetFullPath(v) end
    if t == "table"         then
        local p = {}
        for k, vv in pairs(v) do
            if #p > 20 then p[#p+1] = "..." break end
            p[#p+1] = tostring(k).."="..SerializeValue(vv)
        end
        return "{"..table.concat(p, ",").."}"
    end
    if t == "string"        then return string.format("%q", v) end
    return tostring(v)
end
-- ================================================================
-- 3. HOOK __namecall ĐỂ LOG REMOTE (bao gồm cả anticheat)
-- ================================================================
local function SafeHookNamecall()
    local ok = pcall(function()
        local mt = getrawmetatable(game)
        if not mt then return end
        local old = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = newcclosure(function(self, ...)
            local method = getnamecallmethod()
            local args = {...}

            if (method == "FireServer" or method == "InvokeServer")
                and typeof(self) == "Instance"
                and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction"))
            then
                local path = GetFullPath(self)
                local key  = tick()
                -- Ghi log bình thường
                PushLog(DB.RemoteLog, key, {
                    kind = method,
                    path = path,
                    name = self.Name,
                    args = (function()
                        local a = {}
                        for i, v in ipairs(args) do
                            if i > 10 then a[i] = "..." break end
                            a[i] = SerializeValue(v)
                        end
                        return a
                    end)(),
                })

                -- Nếu remote này nằm trong Anticheat folder / có tên lạ → ghi vào AntiCheat
                local lower = string.lower(self.Name)
                local plower = string.lower(path)
                if string.find(lower, "anti") or string.find(lower, "ac_")
                   or string.find(lower, "security") or string.find(lower, "detect")
                   or string.find(lower, "kick") or string.find(lower, "ban")
                   or string.find(plower, "anticheat") or string.find(plower, "ac.")
                   or string.find(plower, "security")
                then
                    DB.AntiCheat[path] = DB.AntiCheat[path] or {
                        path = path, name = self.Name, className = self.ClassName,
                        calls = {}, firstFire = tick(),
                    }
                    local entry = DB.AntiCheat[path]
                    entry.calls[#entry.calls+1] = {
                        t = tick(), method = method,
                        args = (function()
                            local a = {}
                            for i, v in ipairs(args) do
                                if i > 10 then a[i] = "..." break end
                                a[i] = SerializeValue(v)
                            end
                            return a
                        end)(),
                    }
                end

                -- Nếu NPC gần đây được click → gán remote vào NPC
                if getgenv().BNN_LastClickedNPC then
                    local npc = getgenv().BNN_LastClickedNPC
                    DB.NPCInteractLog[npc] = DB.NPCInteractLog[npc] or {}
                    local cnt = DB.NPCInteractLog[npc]
                    cnt[path] = (cnt[path] or 0) + 1
                end
            end

            return old(self, ...)
        end)
        setreadonly(mt, true)
    end)
    return ok
end

-- Fallback: hookmetamethod
local function SafeHookMeta()
    if SafeHookNamecall() then return true end
    local ok = pcall(function()
        local old
        old = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if (method == "FireServer" or method == "InvokeServer")
                and typeof(self) == "Instance"
                and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction"))
            then
                local key = tick()
                PushLog(DB.RemoteLog, key, {
                    kind = method,
                    path = GetFullPath(self),
                    name = self.Name,
                    args = (function()
                        local a = {}
                        local args = {...}
                        for i, v in ipairs(args) do
                            if i > 10 then a[i] = "..." break end
                            a[i] = SerializeValue(v)
                        end
                        return a
                    end)(),
                })
            end
            return old(self, ...)
        end)
    end)
    return ok
end

local hooked = SafeHookMeta()
Notify("Spy Hook", hooked and "Remote hook OK" or "Hook fail (executor limit)")

-- ================================================================
-- 4. DUMP NPC KHI CLICK
-- ================================================================
local function DumpNPC(model)
    if not model or not model:IsA("Model") then return end
    local root = model:FindFirstChild("HumanoidRootPart")
    local dump = {
        name = model.Name,
        className = model.ClassName,
        path = GetFullPath(model),
        cframe = root and SerializeValue(root.CFrame) or "nil",
        attributes = {},
        children = {},
        descendantsCount = 0,
        prompts = {},
        remotesInside = {},
        humanoid = nil,
        tags = {},
    }

    -- Attributes
    for k, v in pairs(model:GetAttributes()) do
        dump.attributes[k] = SerializeValue(v)
    end

    -- Children cấp 1
    for _, c in ipairs(model:GetChildren()) do
        dump.children[#dump.children+1] = string.format("%s (%s)", c.Name, c.ClassName)
    end

    -- Humanoid
    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum then
        dump.humanoid = {
            Health = hum.Health,
            MaxHealth = hum.MaxHealth,
            WalkSpeed = hum.WalkSpeed,
            RigType = tostring(hum.RigType),
        }
    end

    -- Đếm + liệt kê ProximityPrompt, ClickDetector, Remote
    for _, d in ipairs(model:GetDescendants()) do
        dump.descendantsCount = dump.descendantsCount + 1
        if d:IsA("ProximityPrompt") then
            dump.prompts[#dump.prompts+1] = {
                path = GetFullPath(d),
                actionText = d.ActionText,
                objectText = d.ObjectText,
                holdDuration = d.HoldDuration,
                maxActivationDistance = d.MaxActivationDistance,
                enabled = d.Enabled,
            }
        elseif d:IsA("ClickDetector") then
            dump.prompts[#dump.prompts+1] = { path = GetFullPath(d), kind = "ClickDetector" }
        elseif d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            dump.remotesInside[#dump.remotesInside+1] = GetFullPath(d)
        end
    end

    -- Tags (CollectionService)
    pcall(function()
        local CS = game:GetService("CollectionService")
        for _, t in ipairs(CS:GetTags(model)) do dump.tags[#dump.tags+1] = t end
    end)

    DB.NPCs[model.Name] = dump
    getgenv().BNN_LastClickedNPC = model.Name
    Notify("NPC Dumped", model.Name .. " → database")

    -- In ra console ngay
    print("=== NPC DUMP:", model.Name, "===")
    print(HttpService:JSONEncode(dump))
    return dump
end

-- ================================================================
-- 5. CLICK DETECT — dùng camera raycast
-- ================================================================
local function FindAncestorModel(inst)
    local cur = inst
    while cur and cur ~= Workspace do
        if cur:IsA("Model") then
            local hum = cur:FindFirstChildOfClass("Humanoid")
            if hum then return cur end
        end
        cur = cur.Parent
    end
    return nil
end
local mouse = plr:GetMouse()
local clickConn = mouse.Button1Down:Connect(function()
    local target = mouse.Target
    if not target then return end
    local model = FindAncestorModel(target)
    if model and Players:GetPlayerFromCharacter(model) == nil then
        DumpNPC(model)
    end
end)

-- ================================================================
-- 6. SCAN TELEPORT / GATE / PORTAL
-- ================================================================
local TELEPORT_KEYS = {
    "teleport","tp","portal","gate","door","entrance","exit",
    "travel","warp","cave","hole","secret","pedestal","trial",
}

local function IsTeleportLike(inst)
    local n = string.lower(inst.Name)
    for _, k in ipairs(TELEPORT_KEYS) do
        if string.find(n, k, 1, true) then return true end
    end
    return false
end

local function ScanTeleports()
    for _, v in ipairs(Workspace:GetDescendants()) do
        if (v:IsA("BasePart") or v:IsA("Model")) and IsTeleportLike(v) then
            local entry = DB.Teleports[v.Name] or {}
            local pos
            if v:IsA("BasePart") then pos = v.Position
            else
                local root = v.PrimaryPart or v:FindFirstChildWhichIsA("BasePart", true)
                pos = root and root.Position
            end
            if pos and not entry.cf then
                entry.cf    = string.format("CFrame.new(%.2f,%.2f,%.2f)", pos.X, pos.Y, pos.Z)
                entry.class = v.ClassName
                entry.path  = GetFullPath(v)
                entry.tags  = {}
                pcall(function()
                    local CS = game:GetService("CollectionService")
                    for _, t in ipairs(CS:GetTags(v)) do entry.tags[#entry.tags+1] = t end
                end)

                -- Prompt / Touch
                for _, d in ipairs(v:GetDescendants()) do
                    if d:IsA("ProximityPrompt") then
                        entry.prompt = GetFullPath(d)
                        entry.actionText = d.ActionText
                    elseif d.Name == "TouchInterest" then
                        entry.touch = GetFullPath(d)
                    elseif d:IsA("ClickDetector") then
                        entry.click = GetFullPath(d)
                    elseif d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
                        entry.remote = entry.remote or {}
                        entry.remote[#entry.remote+1] = GetFullPath(d)
                    end
                end

                DB.Teleports[v.Name] = entry
            end
        end
    end
end

-- ================================================================
-- 7. SCAN ANTICHEAT (Module/Remote/RemoteEvent)
-- ================================================================
local AC_KEYS = {
    "anti","anticheat","ac_","_ac","security","detect","kick","ban",
    "hack","exploit","cheat","guard","protect","sanction",
}

local function IsAnticheatName(name)
    local n = string.lower(name)
    for _, k in ipairs(AC_KEYS) do
        if string.find(n, k, 1, true) then return true end
    end
    return false
end

local function ScanAntiCheat()
    -- Search toàn bộ ReplicatedStorage, ReplicatedFirst, các service có client-visible
    local containers = { RS, game:GetService("ReplicatedFirst") }
    for _, root in ipairs(containers) do
        for _, v in ipairs(root:GetDescendants()) do
            if IsAnticheatName(v.Name) then
                local path = GetFullPath(v)
                DB.AntiCheat[path] = DB.AntiCheat[path] or {}
                DB.AntiCheat[path].path      = path
                DB.AntiCheat[path].name      = v.Name
                DB.AntiCheat[path].className = v.ClassName
                if not DB.AntiCheat[path].notes then
                    DB.AntiCheat[path].notes = "Detected by name pattern"
                end
            end
        end
    end

    -- Search RemoteEvent/RemoteFunction nằm trong PlayerGui (client-side)
    if plr:FindFirstChild("PlayerGui") then
        for _, v in ipairs(plr.PlayerGui:GetDescendants()) do
            if v:IsA("RemoteEvent") or v:IsA("RemoteFunction") then
                local path = GetFullPath(v)
                DB.AntiCheat[path] = DB.AntiCheat[path] or {}
                DB.AntiCheat[path].path      = path
                DB.AntiCheat[path].className = v.ClassName
                DB.AntiCheat[path].notes     = "client Remote in PlayerGui"
            end
        end
    end
end

-- ================================================================
-- 8. SCAN ISLAND / ENEMY / NPC FALLBACK (như cũ)
-- ================================================================
local Sea1Islands = {
    ["Pirate Starter"]      = Vector3.new(1080, 16, 1420),
    ["Marine Starter"]      = Vector3.new(-2565, 7, 2050),
    ["Jungle"]              = Vector3.new(-1610, 37, 150),
    ["Pirate Village"]      = Vector3.new(-1120, 5, 3850),
    ["Desert"]              = Vector3.new(1095, 6, 4370),
    ["Frozen Village"]      = Vector3.new(1185, 27, -1325),
    ["Middle Town"]         = Vector3.new(-650, 15, 1580),
    ["Marine Fortress"]     = Vector3.new(-5000, 20, 4350),
    ["Skylands T1"]         = Vector3.new(-4800, 715, -2600),
    ["Upper Skylands"]      = Vector3.new(-7880, 5740, -5600),
    ["Prison"]              = Vector3.new(4850, 5, 740),
    ["Colosseum"]           = Vector3.new(-1430, 7, -2780),
    ["Magma Village"]       = Vector3.new(-5250, 8, 8850),
    ["Underwater City"]     = Vector3.new(3860, -1925, 5485),
    ["Fountain City"]       = Vector3.new(5120, 4, 4100),
    ["Mob Island"]          = Vector3.new(-5200, 2, -7500),
}
local function AutoScanWhileFarm()
    local char = plr.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local myPos = hrp.Position

    -- Islands
    for name, pos in pairs(Sea1Islands) do
        if (myPos - pos).Magnitude <= 1000 and not DB.Islands[name] then
            DB.Islands[name] = string.format("CFrame.new(%.2f, %.2f, %.2f)", pos.X, pos.Y, pos.Z)
        end
    end

    -- NPCs & Enemies
    pcall(function()
        for _, v in ipairs(Workspace:GetDescendants()) do
            if v:IsA("Model") and v:FindFirstChild("HumanoidRootPart") then
                local isPlayer = Players:GetPlayerFromCharacter(v) ~= nil
                if not isPlayer then
                    local cf = v.HumanoidRootPart.CFrame
                    local d  = (cf.Position - myPos).Magnitude
                    if d <= 600 then
                        local folder = v.Parent and v.Parent.Name or ""
                        if folder == "Enemies" then
                            DB.Enemies[v.Name] = DB.Enemies[v.Name]
                                or string.format("CFrame.new(%.2f, %.2f, %.2f)", cf.X, cf.Y, cf.Z)
                        else
                            DB.NPCs[v.Name] = DB.NPCs[v.Name] or {
                                name = v.Name, path = GetFullPath(v),
                                cframe = string.format("CFrame.new(%.2f, %.2f, %.2f)", cf.X, cf.Y, cf.Z),
                                auto = true,
                            }
                        end
                    end
                end
            end
        end
    end)
end

-- ================================================================
-- 9. EXPORT FILE
-- ================================================================
local function DumpToLua()
    local out = {}
    table.insert(out, "-- ============================================")
    table.insert(out, "-- BANANACAT SPY v5.0 — FULL DATA")
    table.insert(out, ("-- Generated: %s"):format(os.date("%Y-%m-%d %H:%M:%S")))
    table.insert(out, "-- ============================================\n")

    table.insert(out, "return {")

    -- Islands
    table.insert(out, "  Islands = {")
    for k, v in pairs(DB.Islands) do
        table.insert(out, string.format("    [%q] = %s,", k, v))
    end
    table.insert(out, "  },")

    -- NPCs
    table.insert(out, "  NPCs = {")
    for k, v in pairs(DB.NPCs) do
        table.insert(out, string.format("    [%q] = %s,", k, HttpService:JSONEncode(v)))
    end
    table.insert(out, "  },")

    -- Enemies
    table.insert(out, "  Enemies = {")
    for k, v in pairs(DB.Enemies) do
        table.insert(out, string.format("    [%q] = %s,", k, v))
    end
    table.insert(out, "  },")

    -- Teleports
    table.insert(out, "  Teleports = {")
    for k, v in pairs(DB.Teleports) do
        table.insert(out, string.format("    [%q] = %s,", k, HttpService:JSONEncode(v)))
    end
    table.insert(out, "  },")

    -- AntiCheat
    table.insert(out, "  AntiCheat = {")
    for k, v in pairs(DB.AntiCheat) do
        table.insert(out, string.format("    [%q] = %s,", k, HttpService:JSONEncode(v)))
    end
    table.insert(out, "  },")

    -- RemoteLog
    table.insert(out, "  RemoteLog = {")
    for k, v in pairs(DB.RemoteLog) do
        table.insert(out, string.format("    [%s] = %s,", tostring(k), HttpService:JSONEncode(v)))
    end
    table.insert(out, "  },")

    -- NPCInteractLog
    table.insert(out, "  NPCInteractLog = {")
    for k, v in pairs(DB.NPCInteractLog) do
        table.insert(out, string.format("    [%q] = %s,", k, HttpService:JSONEncode(v)))
    end
    table.insert(out, "  },")

    table.insert(out, "}")
    return table.concat(out, "\n")
end

local function SaveToFile()
    local txt  = DumpToLua()
    local json = HttpService:JSONEncode(DB)

    if writefile then
        pcall(function() writefile("BananaCat_Spy_v5.lua",  txt)  end)
        pcall(function() writefile("BananaCat_Spy_v5.json", json) end)
        Notify("SAVED", "BananaCat_Spy_v5.lua + .json")
    else
        print(txt)
        Notify("F9 CONSOLE", "Copy dữ liệu từ console")
    end
end
-- ================================================================
-- 10. UI
-- ================================================================
local Gui = Instance.new("ScreenGui")
Gui.Name = "BananaCat_Spy_v5"
Gui.ResetOnSpawn = false
Gui.DisplayOrder = 999999
pcall(function()
    if gethui then Gui.Parent = gethui()
    else Gui.Parent = plr:WaitForChild("PlayerGui") end
end)

local function MakeBtn(text, color, yPos, callback)
    local b = Instance.new("TextButton")
    b.Parent = Gui
    b.Size = UDim2.new(0, 220, 0, 40)
    b.Position = UDim2.new(0.5, -110, 0, yPos)
    b.BackgroundColor3 = color
    b.BorderSizePixel = 0
    b.Font = Enum.Font.SourceSansBold
    b.TextSize = 15
    b.TextColor3 = Color3.new(1,1,1)
    b.Text = text
    b.Active = true

    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 10); c.Parent = b
    local s = Instance.new("UIStroke"); s.Thickness = 2; s.Color = Color3.new(1,1,1); s.Parent = b

    b.MouseButton1Click:Connect(callback)
    return b
end

MakeBtn("💾 SAVE DATA", Color3.fromRGB(255,120,0), 180, function()
    SaveToFile()
end)

MakeBtn("🔍 SCAN TELEPORTS", Color3.fromRGB(60,160,255), 225, function()
    ScanTeleports()
    Notify("Teleports", ("%d entries"):format((function()
        local n=0; for _ in pairs(DB.Teleports) do n=n+1 end; return n end)()))
end)

MakeBtn("🛡️ SCAN ANTICHEAT", Color3.fromRGB(200,60,80), 270, function()
    ScanAntiCheat()
    Notify("AntiCheat", ("%d entries"):format((function()
        local n=0; for _ in pairs(DB.AntiCheat) do n=n+1 end; return n end)()))
end)

MakeBtn("👁️ CLICK NPC TO DUMP", Color3.fromRGB(40,180,120), 315, function()
    Notify("Hint", "Di chuột vào NPC, click trái để dump")
end)

MakeBtn("❌ CLOSE", Color3.fromRGB(80,80,80), 360, function()
    Gui:Destroy()
end)

-- ================================================================
-- 11. WORKER LOOP
-- ================================================================
task.spawn(function()
    Notify("BananaCat Spy v5.0", "Click NPC để dump. Nút lưu ở giữa màn hình.")
    while task.wait(2) do
        pcall(AutoScanWhileFarm)
    end
end)

task.spawn(function()
    while task.wait(8) do
        pcall(ScanTeleports)
        pcall(ScanAntiCheat)
    end
end)
```

---

Cách hoạt động

1. Click NPC → tự động dump

· Hook mouse.Button1Down, raycast vào mouse.Target
· Tìm ancestor Model có Humanoid
· Ghi lại: path, CFrame, attributes, children, Humanoid stats, ProximityPrompt, ClickDetector, Remote bên trong, tags

2. Log mọi Remote call

· Hook __namecall trên metatable
· Bắt FireServer / InvokeServer của mọi RemoteEvent / RemoteFunction
· Ghi path, args, tick() vào DB.RemoteLog (giới hạn 5000 dòng)

3. Phát hiện anticheat

· Remote có tên chứa anti|ac_|security|detect|kick|ban|hack|exploit|cheat|guard → tự động vào DB.AntiCheat với mọi call + args
· ModuleScript trong ReplicatedStorage / ReplicatedFirst có tên khớp pattern → thêm vào danh sách để bạn đọc code thủ công
· Remote lạ trong PlayerGui → đánh dấu

4. Cổng dịch chuyển

· Scan mọi part/model có tên chứa teleport|portal|gate|door|entrance|exit|travel|warp|cave|trial|pedestal
· Ghi vị trí + ProximityPrompt + TouchInterest + ClickDetector + Remote bên trong + CollectionService tags

5. Export

· Nút 💾 SAVE DATA xuất ra 2 file: BananaCat_Spy_v5.lua (dạng table Lua) và BananaCat_Spy_v5.json (raw JSON) — bạn có thể load lại và merge vào script chính

---

Sau khi dump xong

File .json sẽ có dạng:

```json
{
  "NPCs": {
    "Mysterious Force": {
      "path": "Workspace.NPCs.Mysterious Force",
      "cframe": "CFrame.new(4345.09,1198.24,-6159.00)",
      "attributes": {"NPCLoaded": true, "NPCReady": true},
      "prompts": [{"path":"...", "actionText":"Interact"}],
      "remotesInside": ["ReplicatedStorage.Remotes.CommF_"]
    }
  },
  "Teleports": {
    "TrialTeleport": {"cf":"CFrame.new(...)", "prompt":"...", "actionText":"Enter"}
  },
  "AntiCheat": {
    "ReplicatedStorage.AntiCheat.Report": {
      "calls": [{"t": 1234.5, "method":"FireServer", "args":["Move", Vector3.new(...)]}]
    }
  }
}