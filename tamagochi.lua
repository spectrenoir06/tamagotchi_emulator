local class  = require 'middleclass'
local lib    = require("tamalib")
local ffi    = require("ffi")
local socket = require("socket")
local bit    = require("bit")
local json = require("JSON")

local vstruct = require "vstruct"
print(vstruct._VERSION)

local SAVE_SIZE = 816
local DATA_SIZE = 76

local Tamagochi = class('Tamagochi')

Tamagochi.static.ram_map = {
    second_lower   = 0x10, -- lower digit
    second_upper   = 0x11, -- upper digit (x10)
    minute_lower   = 0x12, -- lower digit
    minute_upper   = 0x13, -- upper digit (x10)
    hour_lower     = 0x14, -- less significant bit
    hour_upper     = 0x15, -- most significant bit (x16)

    -- time_menu      = 0x2B, -- equal 4 if menu time open
    time_menu      = 0xFF + 0x4F, --  == 3 menu time open  seconde page

    hunger         = 0x40, -- hunger / 8 = (food = 4)
    happiness      = 0x41, -- happiness / 4 = (snack = 4)
    care           = 0x42, -- start at 0 incremement by 1 every miss care
    discipline     = 0x43, -- discipline increment by 4 every discipline
    -- ?
    -- ?
    weight_lower   = 0x46, -- lower digit
    weight_upper   = 0x47, -- upper digit (x10)
    health         = 0x48, -- health (sick if > 8)
    sleep          = 0x4A, -- sleep (if >= 8 sleep)
    light          = 0x4B, -- light on if 0xF
    -- ?
    shit           = 0x4D, -- counter of shit


    age_lower      = 0x54, -- lower digit
    age_upper      = 0x55, -- upper digit
    menu_timeout   = 0x57, -- when button press set at 0xA and decrement to 0 and close the menu
    force_sleep    = 0x5C, -- make it sleep ?
    stage          = 0x5D, -- stage ( what tama is visible )
    menu_select    = 0x75, -- what menu is selected
    submenu        = 0x76, -- 2 if submenu else 8
    select_menu    = 0x90, -- if 7 then select menu 0 else if f then menu 1 
}

function Tamagochi:initialize(tamagochi_name)
    lib.lua_tamalib_init(0)
    self.tamagochi_name = tamagochi_name or "default"

    local file = io.open("saves/"..self.tamagochi_name..".state", "rb") -- r read mode and b binary mode
    if file then
        print("load save")
        local save = file:read "*a" -- read all file
        file:close()
        local c_str = ffi.new("char[?]", #save + 1)
        ffi.copy(c_str, save)
        lib.lua_tamalib_state_load(c_str) -- load save in tamagotchi
        self:setTime()
    else
        print("load start")
        local file = io.open("saves/start.state", "rb") -- r read mode and b binary mode
        if file then
            local save = file:read "*a" -- read all file
            file:close()
            local c_str = ffi.new("char[?]", #save + 1)
            ffi.copy(c_str, save)
            lib.lua_tamalib_state_load(c_str) -- load save in tamagotchi
        end
    end
    self.img = {}
    self.queue = {}
    self.speed_up = false
    self.timer = 0
    self.timer_frame = 0
end

function Tamagochi:update(dt)
    local is_update = false
    lib.lua_tamalib_bigstep() -- calculate tamagotchi
    if #self.queue > 0 then
        -- print(dump(self.queue))
        local event = self.queue[1]
        if event.exe then
            event.exe()
            event.exe = nil
        end
        if event.delay > 0 then
            event.delay = event.delay - dt
        end
        if event.delay <= 0 then
            -- print("remove")
            table.remove(self.queue, 1)
        end
    else
        info = self:getInfo()
        if (info.warning or info.shit > 0 or info.is_sick) and self.speed_up then
            self.speed_up = false
            lib.lua_tamalib_set_speed(1)
        end
        -- print(info.stage)
        if not self.speed_up then
            if info.stage > 0 then -- is alive
                if info.time_menu == 3 then -- menu time is open
                    print("Time MENU IS OPEN")
                    self:press_b()
                else
                    if info.is_sleeping == false then -- is not sleeping
                        if info.is_sick then
                            self:heal()
                        elseif info.shit > 0 then
                            self:clean()
                        elseif info.warning and info.hunger > 0 and info.happiness > 0 then -- is a bitch
                            self:discipline()
                        elseif info.hunger < 13 then
                            self:feed()
                        elseif info.happiness < 13 then
                            self:snack()
                        else
                            -- self.speed_up = true
                            -- lib.lua_tamalib_set_speed(0)
                        end
                    else
                        if info.is_light_on then
                            self:turnLightOff()
                        else
                            -- self.speed_up = true
                            -- lib.lua_tamalib_set_speed(0)
                        end
                    end
                end
            end
        end
    end

    local buf = ffi.new("uint8_t[?]", DATA_SIZE)
    lib.lua_tamalib_get_matrix_data_bin(buf)

    local data = ffi.string(buf, DATA_SIZE)
    self.timer_frame = self.timer_frame + dt
    if data then
        local id = vstruct.readvals("u4", data)
        local off_x = (id*32)%320
        local off_y = math.floor(id/10)*16
        self.img = {}
        for y=0, 15 do
            local d = vstruct.readvals("u4", data:sub(y*4+5))
            self.img[y+1] = d -- save 4byte to img
        end

        self.icone_bin = vstruct.readvals("u1", data:sub(16*4+1+4)) -- is the LCD icon
        self.playsound = vstruct.readvals("u1", data:sub(16*4+1+5)) -- should play sound ?
        self.freq = vstruct.readvals("u4", data:sub(16*4+1+8))      -- sound frequency
        self.warning = bit.band(self.icone_bin, 0x80) == 0x80  -- icone warning is on ?
        if (self.timer_frame > 1) then
            self.timer_frame = 0
            is_update = true
        end
    end

    self.timer = self.timer + dt
    if self.timer > 30 then
        -- print("auto save")
        local save = ffi.new("uint8_t[?]", SAVE_SIZE)
        lib.lua_tamalib_state_save(save)

        local file = io.open("saves/"..self.tamagochi_name..".state", "w")  -- Open the file in write mode
        if file then
            file:write(ffi.string(save, SAVE_SIZE))  -- Write the string to the file
            file:close()  -- Close the file
        else
            print("Failed to open file.")
        end
        self.timer = 0
    end

    return is_update
end

function Tamagochi:setRegister(register, value)
	local save = self:save()
	save[48+register] = value
	lib.lua_tamalib_state_load(save) -- load save in tamagotchi
end

function Tamagochi:feed()
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			self:setRegister(0x57, 0xA) -- timeout reset
			self:setRegister(0x75, 0x1) -- select food
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_B()
			-- print("open food menu")
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_release_B() -- press b to open submenu
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			self:setRegister(0x75, 0x0) -- select food
			-- print("select food")
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_B() -- press b to open submenu
			-- print("press b")
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 4,
		exe = function()
			lib.lua_tamalib_set_release_B() -- press b to feed
			-- print("release b")
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_C() -- press b to open submenu
			-- print("press c")
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_release_C() -- press b to feed
			-- print("release c")
		end
	}
end

function Tamagochi:snack()
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			self:setRegister(0x57, 0xA) -- timeout reset
			self:setRegister(0x75, 0x1) -- select food
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_B()
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_release_B() -- press b to open submenu
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			self:setRegister(0x75, 0x1) -- select snack
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_B() -- press b to open submenu
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 6,
		exe = function()
			lib.lua_tamalib_set_release_B() -- press b to feed
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_C() -- close all menu
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_release_C() -- close all menu
		end
	}
end

function Tamagochi:clean()
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			self:setRegister(0x57, 0xA) -- timeout reset
			self:setRegister(0x75, 0x5) -- select clean
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_B() -- clean
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 6,
		exe = function()
			lib.lua_tamalib_set_release_B()
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_C() -- close all menu
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 1,
		exe = function()
			lib.lua_tamalib_set_release_C() -- close all menu
		end
	}
end

function Tamagochi:heal()
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			self:setRegister(0x57, 0xA) -- timeout reset
			self:setRegister(0x75, 0x4) -- select heal
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_B() -- heal
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 6,
		exe = function()
			lib.lua_tamalib_set_release_B()
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_C() -- close all menu
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_release_C() -- close all menu
		end
	}
end

function Tamagochi:discipline()
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			self:setRegister(0x57, 0xA) -- timeout reset
			self:setRegister(0x75, 0x7) -- select discipline
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_B() -- discipline
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 6,
		exe = function()
			lib.lua_tamalib_set_release_B()
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_C() -- close all menu
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_release_C() -- close all menu
		end
	}
end

function Tamagochi:turnLightOff()
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			self:setRegister(0x57, 0xA) -- timeout reset
			self:setRegister(0x75, 0x2) -- select light
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_B()
			-- print("open light menu")
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_release_B() -- press b to open submenu
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			self:setRegister(0x75, 0x1) -- select food
			-- print("select off")
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_B() -- press b to open submenu
			-- print("press b")
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 6,
		exe = function()
			lib.lua_tamalib_set_release_B() -- press b to feed
			-- print("release b")
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_C() -- press b to open submenu
			-- print("press c")
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 1,
		exe = function()
			lib.lua_tamalib_set_release_C() -- press b to feed
			-- print("release c")
		end
	}
end

function Tamagochi:press_b()
	self.queue[#self.queue + 1] = {
		delay = 0.5,
		exe = function()
			lib.lua_tamalib_set_press_B() -- press b to open submenu
			-- print("press b")
		end
	}
	self.queue[#self.queue + 1] = {
		delay = 1,
		exe = function()
			lib.lua_tamalib_set_release_B() -- press b to feed
			-- print("release b")
		end
	}
end


function Tamagochi:readReg(save, reg)
    return save[48+reg] 
end

function Tamagochi:save()
    local save = ffi.new("uint8_t[?]", SAVE_SIZE)
    lib.lua_tamalib_state_save(save)
    return save
end

function Tamagochi:getInfo()
    local save = self:save()
    local map = Tamagochi.ram_map

    local hour = (
        self:readReg(save, map.hour_lower)
        + self:readReg(save, map.hour_upper)*16
    )

    local minute = (
        self:readReg(save, map.minute_lower)
        + self:readReg(save, map.minute_upper)*10
    )

    local second = (
        self:readReg(save, map.second_lower)
        + self:readReg(save, map.second_upper)*10
    )

    local age = (
        self:readReg(save, map.age_lower)
        + self:readReg(save, map.age_upper)*10
    )

    local weight = (
        self:readReg(save, map.weight_lower)
        + self:readReg(save, map.weight_upper)*10
    )

    local hunger = self:readReg(save, map.hunger)
    local happiness = self:readReg(save, map.happiness)
    local discipline = self:readReg(save, map.discipline)
    local health = self:readReg(save, map.health)
    local stage = self:readReg(save, map.stage)
    local shit = self:readReg(save, map.shit)
    local care = self:readReg(save, map.care)
    local sleep = self:readReg(save, map.sleep)
    local light = self:readReg(save, map.light)
    local time_menu = self:readReg(save, map.time_menu)

    return {
        hour = hour,
        minute = minute,
        second = second,

        age = age,
        weight = weight,
        hunger = hunger,
        happiness = happiness,
        discipline = discipline,
        stage = stage,
        shit = shit,
        care = care,
        is_sleeping = sleep >= 8,
        is_light_on = light == 0xF,
        is_sick = health > 8,
        warning = self.warning,
        icone = self.icone_bin,
        playsound = self.playsound,
        freq = self.freq,
        name = self.tamagochi_name,
        time_menu = time_menu
    }
end 

function Tamagochi:printInfo()
    local info = self:getInfo()
    print("\27[2J\27[H")
    print(string.format("time: %02d:%02d:%02d", info.hour, info.minute, info.second))
    print("weight: "..info.weight)
    print("age: "..info.age)
    print("hunger: "..info.hunger)
    print("happiness: "..info.happiness)
    print("shit: "..info.shit)
    print("care: "..info.care)

    for k,v in ipairs(self.img) do
        str = ""
        for x=0, 31 do
            local pix = bit.band(v, 1) -- get the last bit
            if pix == 0 then
                str = str .. " "
            else
                str = str .. "#"
            end
            v = bit.rshift(v, 1)       -- shift the bits to the right
        end
        print(str)
    end
end

function Tamagochi:sendInfo(client)
    local info = self:getInfo()
    client:send("\27[2J\27[H")
    client:send(string.format("time: %02d:%02d:%02d", info.hour, info.minute, info.second).."\n\r")
    client:send("weight: "..info.weight.."\n\r")
    client:send("age: "..info.age.."\n\r")
    client:send("hunger: "..info.hunger.."\n\r")
    client:send("happiness: "..info.happiness.."\n\r")
    client:send("shit: "..info.shit.."\n\r")
    client:send("care: "..info.care.."\n\r")

    for k,v in ipairs(self.img) do
        str = ""
        for x=0, 31 do
            local pix = bit.band(v, 1) -- get the last bit
            if pix == 0 then
                str = str .. " "
            else
                str = str .. "#"
            end
            v = bit.rshift(v, 1)       -- shift the bits to the right
        end
        client:send(str.."\n\r")
    end
end

function Tamagochi:sendState(client)
    local info = self:getInfo()
    info.img = self.img
    local raw_json_text = json:encode(info)
    -- print(#raw_json_text)
    -- local raw_json_text = json:encode_pretty(info)
    client:send(raw_json_text)
end

function Tamagochi:setTime()
    local hour   = tonumber(os.date("%H"))
    local minute = tonumber(os.date("%M"))
    local second = tonumber(os.date("%S"))

    self:setRegister(0x14, hour%16)
    self:setRegister(0x15, math.floor(hour/16))

    self:setRegister(0x12, minute%10)
    self:setRegister(0x13, math.floor(minute/10))

    self:setRegister(0x10, second%10)
    self:setRegister(0x11, math.floor(second/10))
end

for i, arg in ipairs(arg) do
    print("Argument " .. i .. ": " .. arg)
end

tamagochi_name =  arg[1]

if arg[2] then
    -- the address and port of the server
    local address, port = "127.0.0.1", 12345
    udp = socket.udp()
    udp:settimeout(0)
    udp:setpeername(address, port)
end



local tama = Tamagochi:new(tamagochi_name)

-- local fps = 10
-- local dt = 1/fps

-- print("HELLO")

local time = socket.gettime()
while true do
    local dt = socket.gettime() - time
    if tama:update(dt) then
        -- tama:printInfo()
        if arg[2] then
            -- tama:sendInfo(client)
            tama:sendState(udp)
        end
    end
    -- socket.sleep(dt)
end
