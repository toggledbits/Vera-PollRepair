--[[
	L_PollRepair.lua - Core module for PollRepair
	Copyright 20162017,2018 Patrick H. Rigney, All Rights Reserved.
	This file is part of PollRepair. For license information, see LICENSE at https://github.com/toggledbits/PollRepair
--]]
--luacheck: std lua51,module,read globals luup,ignore 542 611 612 614 111/_,no max line length

module("L_PollRepair", package.seeall)

local debugMode = false

local _PLUGIN_ID = 99999
local _PLUGIN_NAME = "PollRepair"
local _PLUGIN_VERSION = "0.1develop-20241"
local _PLUGIN_URL = "https://www.toggledbits.com/"
local _CONFIGVERSION = 20241

local MYSID = "urn:toggledbits-com:serviceId:PollRepair"
local MYTYPE = "urn:schemas-toggledbits-com:device:PollRepair:1"

local ZWDEVSID = "urn:micasaverde-com:serviceId:ZWaveDevice1"
local ZWNETSID = "urn:micasaverde-com:serviceId:ZWaveNetwork1"
local HASID = "urn:micasaverde-com:serviceId:HaDevice1"

local isALTUI = false
local isOpenLuup = false
local sysScheduler
local pluginDevice
local pollDevices = {}
local pollHoldOff = false
local watchData = {}

POLL_REPORT_LEVEL = debugMode and 50 or 4

local function dump(t)
	if t == nil then return "nil" end
	local sep = ""
	local str = "{ "
	for k,v in pairs(t) do
		local val
		if type(v) == "table" then
			val = dump(v)
		elseif type(v) == "function" then
			val = "(function)"
		elseif type(v) == "string" then
			val = string.format("%q", v)
		elseif type(v) == "number" and (math.abs(v-os.time()) <= 86400) then
			val = tostring(v) .. "(" .. os.date("%x.%X", v) .. ")"
		else
			val = tostring(v)
		end
		str = str .. sep .. k .. "=" .. val
		sep = ", "
	end
	str = str .. " }"
	return str
end

local function L(msg, ...) -- luacheck: ignore 212
	local str
	local level = 50
	if type(msg) == "table" then
		str = tostring(msg.prefix or _PLUGIN_NAME) .. ": " .. tostring(msg.msg or msg[1])
		level = msg.level or level
	else
		str = _PLUGIN_NAME .. ": " .. tostring(msg)
	end
	str = string.gsub(str, "%%(%d+)", function( n )
			n = tonumber(n, 10)
			if n < 1 or n > #arg then return "nil" end
			local val = arg[n]
			if type(val) == "table" then
				return dump(val)
			elseif type(val) == "string" then
				return string.format("%q", val)
			elseif type(val) == "number" and math.abs(val-os.time()) <= 86400 then
				return tostring(val) .. "(" .. os.date("%x.%X", val) .. ")"
			end
			return tostring(val)
		end
	)
	luup.log(str, level)
end

local function D(msg, ...)
	if debugMode then
		L( { msg=msg,prefix=(_PLUGIN_NAME .. "(debug)::") }, ... )
	end
end

local function E(msg, ...) L({level=1,msg=msg}, ...) end

local function W(msg, ...) L({level=2,msg=msg}, ...) end

local function T(msg, ...) L(msg, ...) if debug and debug.traceback then luup.log(debug.traceback()) end end

local function checkVersion(dev)
	local ui7Check = luup.variable_get(MYSID, "UI7Check", dev) or ""
	if isOpenLuup then
		return true
	end
	if (luup.version_branch == 1 and luup.version_major >= 7) then
		if ui7Check == "" then
			-- One-time init for UI7 or better
			luup.variable_set(MYSID, "UI7Check", "true", dev)
		end
		return true
	end
	return false
end

-- Add, if not already set, a watch on a device and service.
local function addWatch( dev, svc, var )
	local watchkey = string.format("%d/%s/%s", dev or 0, svc or "X", var or "X")
	if watchData[watchkey] == nil then
		D("addWatch() adding system watch for %1", watchkey)
		luup.variable_watch( "pollRepairWatch", svc or "X", var or "X", dev or 0 )
		watchData[watchkey] = true
	end
end

local function unWatch( dev, svc, var )
	local watchkey = string.format("%d/%s/%s", dev or 0, svc or "X", var or "X")
	watchData[watchkey] = nil
end

-- Initialize a variable if it does not already exist.
local function initVar( name, dflt, dev, sid )
	-- D("initVar(%1,%2,%3,%4)", name, dflt, dev, sid)
	assert( not name:match( "^urn" ), "SID in wrong position" )
	assert( dev ~= nil )
	assert( sid ~= nil, "SID required for "..tostring(name) )
	local currVal = luup.variable_get( sid, name, dev )
	if currVal == nil then
		luup.variable_set( sid, name, tostring(dflt), dev )
		return dflt
	end
	return currVal
end

-- Set variable, only if value has changed.
local function setVar( sid, name, val, dev )
	-- D("setVar(%1,%2,%3,%4)", sid, name, val, dev )
	if dev <= 1 then E("Invalid device number %1", dev) end
	assert( dev ~= nil and type(dev) == "number", "Invalid set device for "..dump({sid=sid,name=name,val=val,dev=dev}) )
	assert( dev > 0, "Invalid device number "..tostring(dev) )
	assert( sid and sid:match( "^urn" ), "SID required for "..tostring(name) )
	val = (val == nil) and "" or tostring(val)
	local s = luup.variable_get( sid, name, dev )
	-- D("setVar(%1,%2,%3,%4) old value %5", sid, name, val, dev, s )
	if s ~= val then
		luup.variable_set( sid, name, val, dev )
	end
	return s
end

-- Get variable or default
local function getVar( name, dflt, dev, sid, doinit )
	assert( name ~= nil )
	assert( dev ~= nil )
	assert( sid ~= nil, "SID required for "..tostring(name) )
	local s = luup.variable_get( sid, name, dev )
	if s == nil and doinit then
		luup.variable_set( sid, name, tostring(dflt), dev )
		return dflt
	end
	return (s or "") == "" and dflt or s
end

-- Get numeric variable, or return default value if not set or blank
local function getVarNumeric( name, dflt, dev, sid, doinit )
	local s = getVar( name, dflt, dev, sid, doinit )
	if s == "" then return dflt end
	return tonumber(s) or dflt
end

local function getVarBool( name, dflt, dev, sid, doinit )
	local v = getVarNumeric( name, dflt and 1 or 0, dev, sid, doinit )
	return v ~= 0
end

-- Enabled?
local function isEnabled( dev )
	return getVarNumeric( "Enabled", 0, dev or pluginDevice, MYSID ) ~= 0
end

local function setMessage( m )
	setVar( MYSID, "Message", m or "", pluginDevice )
end

TaskManager = function( luupCallbackName )
	local DEBUG = true
	local callback = luupCallbackName
	local runStamp = 1
	local tickTasks = { __sched={ id="__sched" } }
	local Task = { id=false, when=0 }
	local nextident = 0

	local D = DEBUG and _G.D or ( function() end ) -- luacheck: ignore 431

	-- Schedule a timer tick for a future (absolute) time. If the time is sooner than
	-- any currently scheduled time, the task tick is advanced; otherwise, it is
	-- ignored (as the existing task will come sooner), unless repl=true, in which
	-- case the existing task will be deferred until the provided time.
	local function scheduleTick( tkey, timeTick, flags )
		local tinfo = tickTasks[tkey]
		assert( tinfo, "Task not found" )
		assert( type(timeTick) == "number" and timeTick > 0, "Invalid schedule time" )
		flags = flags or {}
		if ( tinfo.when or 0 ) == 0 or timeTick < tinfo.when or flags.replace then
			-- Not scheduled, requested sooner than currently scheduled, or forced replacement
			tinfo.when = timeTick
		end
		-- If new tick is earlier than next plugin tick, reschedule Luup timer
		if tickTasks.__sched.when == 0 then return end -- in queue processing
		if tickTasks.__sched.when == nil or timeTick < tickTasks.__sched.when then
			tickTasks.__sched.when = timeTick
			local delay = timeTick - os.time()
			if delay < 0 then delay = 0 end
			runStamp = runStamp + 1
			luup.call_delay( callback, delay, runStamp )
		end
	end

	-- Remove tasks from queue. Should only be called from Task::close()
	local function removeTask( tkey )
		tickTasks[ tkey ] = nil
	end

	-- Plugin timer tick. Using the tickTasks table, we keep track of
	-- tasks that need to be run and when, and try to stay on schedule. This
	-- keeps us light on resources: typically one system timer only for any
	-- number of devices.
	local function runReadyTasks( luupCallbackArg )
		local stamp = tonumber(luupCallbackArg)
		if stamp ~= runStamp then
			-- runStamp changed, different from stamp on this call, just exit.
			return
		end

		local now = os.time()
		local nextTick = nil
		tickTasks.__sched.when = 0 -- marker (run in progress)

		-- Since the tasks can manipulate the tickTasks table (via calls to
		-- scheduleTick()), the iterator is likely to be disrupted, so make a
		-- separate list of tasks that need service (to-do list).
		local todo = {}
		for t,v in pairs(tickTasks) do
			if t ~= "__sched" and ( v.when or 0 ) ~= 0 and v.when <= now then
				D("Task:runReadyTasks() ready %1 %2", v.id, v.when)
				table.insert( todo, v )
			else
				D("Task:runReadyTasks() not ready %1 %2", v.id, v.when)
			end
		end

		-- Run the to-do list tasks.
		table.sort( todo, function( a, b ) return a.when < b.when end )
		for _,v in ipairs(todo) do
			D("Task:runReadyTasks() running %1", v.id)
			v:run()
			if (v.when or 0) > 0 and (now + 2) > v.when then
				L("Task %1 has scheduled itself for %2 (immediate)", v.id, v.when)
			end
		end

		-- Things change while we work. Take another pass to find next task.
		for t,v in pairs(tickTasks) do
			D("Task:runReadyTasks() waiting %1 %2", v.id, v.when)
			if t ~= "__sched" and ( v.when or 0 ) ~= 0 then
				if nextTick == nil or v.when < nextTick then
					nextTick = v.when
				end
			end
		end

		-- Reschedule scheduler if scheduled tasks pending
		if nextTick ~= nil then
			now = os.time() -- Get the actual time now; above tasks can take a while.
			local delay = nextTick - now
			if delay < 0 then delay = 0 end
			tickTasks.__sched.when = now + delay -- that may not be nextTick
			D("Task:runReadyTasks() next in %1", delay)
			luup.call_delay( callback, delay, luupCallbackArg )
		else
			tickTasks.__sched.when = nil -- remove when to signal no timer running
		end
	end

	function Task:schedule( when, flags, args )
		assert(self.id, "Can't reschedule() a closed task")
		if args then self.args = args end
		scheduleTick( self.id, when, flags )
		return self
	end

	function Task:delay( delay, flags, args )
		assert(self.id, "Can't delay() a closed task")
		if args then self.args = args end
		scheduleTick( self.id, os.time()+delay, flags )
		return self
	end

	function Task:suspend()
		self.when = 0
		return self
	end

	function Task:suspended() return self.when == 0 end

	function Task:run()
		assert(self.id, "Can't run() a closed task")
		self.when = 0
		-- local success, err = pcall( self.func, self, unpack( self.args or {} ) )
		local success = xpcall(
			function() return self.func( self, unpack(self.args or {}) ) end,
			function( er )
				self.lasterr = er
				T({level=1,msg="%1 (#%2) tick failed: %3"},
					(luup.devices[self.owner] or {}).description, self.owner, er)
			end
		)
		if success then self.lasterr = nil end
		return self
	end

	function Task:close()
		removeTask( self.id )
		self.id = nil
		self.when = nil
		self.args = nil
		self.func = nil
		setmetatable(self,nil)
		return self
	end

	function Task:new( id, owner, tickFunction, args, desc )
		assert( id == nil or tickTasks[tostring(id)] == nil,
			"Task already exists with id "..tostring(id)..": "..tostring(tickTasks[tostring(id)]) )
		assert( type(owner) == "number", "Invalid owner for task "..tostring(id) )
		assert( type(tickFunction) == "function" )

		local obj = { when=0, owner=owner, func=tickFunction, args=args }
		obj.id = tostring( id or obj )
		obj.name = desc or obj.id
		setmetatable(obj, self)
		self.__index = self
		self.__tostring = function(e) return string.format("Task(%s)", e.id) end

		tickTasks[ obj.id ] = obj
		return obj
	end

	local function getOwnerTasks( owner )
		local res = {}
		for k,v in pairs( tickTasks ) do
			if owner == nil or v.owner == owner then
				table.insert( res, k )
			end
		end
		return res
	end

	local function getTask( id )
		return tickTasks[tostring(id)]
	end

	-- Convenience function to create a delayed call to the given func in its own task
	local function delay( func, delaySecs, args )
		nextident = nextident + 1
		local t = Task:new( "_delay"..nextident, pluginDevice, func, args )
		t:delay( math.max(0, delaySecs) )
		return t
	end

	return {
		runReadyTasks = runReadyTasks,
		getOwnerTasks = getOwnerTasks,
		getTask = getTask,
		delay = delay,
		Task = Task,
		_tt = tickTasks
	}
end

local check_job -- fwd decl
local function poll_device()
	D("poll_device() list contains %1 devices", #pollDevices)
	if not isEnabled() then
		setMessage("Disabled")
		return
	end

	local now = os.time()
	if pollHoldOff and now < pollHoldOff then
		local delay = pollHoldOff - now
		sysScheduler.getTask("poller"):delay(delay)
		D("poller() deferring until %1 (%2s), mesh busy holdoff", pollHoldOff, delay)
		setMessage("Mesh busy; delaying to " .. os.date("%X", pollHoldOff))
		return
	end
	pollHoldOff = false

	local ix = 1
	while ix <= #pollDevices do
		local del = false
		local p = pollDevices[ix]
		del = del or ( p.notpollable )
		del = del or ( not luup.devices[p.device] )
		del = del or ( getVar( "tb_pollsettings", "X", p.device, ZWDEVSID ) == "X" )
		if del then
			L({level=POLL_REPORT_LEVEL,msg="Removing unpollable device %1 (#%2) from list"},
				(luup.devices[p.device] or {}).description or "unknown", p.device)
			unWatch( p.device, ZWDEVSID, "PollSettings" )
			table.remove( pollDevices, ix )
		else
			ix = ix + 1
		end
	end

	-- Take care of next scheduled item.
	local delay = 60
	table.sort( pollDevices, function(a,b)
		local a_tardy = now - a.nextattempt
		local b_tardy = now - b.nextattempt
		return a_tardy > b_tardy
	end)
	local tardy = #pollDevices
	for k,p in ipairs(pollDevices) do
		if p.nextattempt > now then
			tardy = k - 1
			break
		end
	end
	setMessage(string.format("Managing %d devices; %d ready", #pollDevices, tardy))
	if #pollDevices > 0 then
		local p = pollDevices[1]
		D("poll_device() now %2 candidate %1", p, now)
		if p.nextattempt > ( now + 5 ) then
			-- Scheduled time more than five seconds away, defer
			delay = p.nextattempt - now
			D("poll_device() device not ready for %1s, deferring", delay)
			setMessage(string.format("Managing %d devices; next in %ds", #pollDevices, delay))
		else
			D("poll_device() device %1 (#%2) ready to poll", luup.devices[p.device].description, p.device)
			p.interval = getVarNumeric( "tb_pollsettings", 1800, p.device, ZWDEVSID )
			if p.interval == 0 then p.interval = 1800 end
			if p.interval < 60 then p.interval = 60 end
			-- local ra,rb,rc,rd = luup.call_action( MYSID, "PollDevice", { DeviceNum=p.device }, pluginDevice )
			L({level=POLL_REPORT_LEVEL,msg="Polling %1 (device %2, ZWave node %3) delayed %4s"},
				luup.devices[p.device].description, p.device, luup.devices[p.device].id,
				now-p.nextattempt)
			local ra,rb,rc,rd = luup.call_action( HASID, "Poll", {}, p.device )
			D("poll_device() job data %1,%2,%3,%4", ra, rb, rc, rd)
			local job = rc
			if job == 0 and rd and rd.JobID then
				job = tonumber(rd.JobID)
			end
			D("poll_device() job number is %1", job)
			p.job = job
			p.lastattempt = now
			p.nextattempt = now + p.interval -- just for now
			sysScheduler.Task:new( "jobcheck"..job, pluginDevice, check_job, { job, p.device } ):delay( 5 )
			-- We'll reschedule through check_job
			return
		end
	end

	D("poller() scheduling run for %1s %2", delay, now+delay)
	sysScheduler.getTask("poller"):delay(delay)
end

check_job = function( task, jobnum, dev, retries )
	D("check_job(%1,%2,%3)", task, jobnum, dev)
	local st, note = luup.job.status( jobnum, dev )
	D("check_job() job %3 status is %1, %2", st, note, jobnum)
	for _,p in ipairs( pollDevices ) do
		if p.device == dev then
			if st == 4 then -- and p.job == jobnum then
				-- Success!
				p.job = nil
				p.nextattempt = p.lastattempt + p.interval + math.random(-20, 40)
				-- It seems the poll job updates the variables for us... need to confirm.
				-- setVar( ZWNETSID, "LastPollSuccess", p.lastattempt, p.device )
				-- ??? PollRatings?
				-- setVar( ZWDEVSID, "PollOk", getVarNumeric( "PollOk", 0, p.device, ZWDEVSID ) + 1, p.device )
				p.failedattempts = nil
				-- setVar( ZWNETSID, "ConsecutivePollFails", 0, p.device )
				L({level=POLL_REPORT_LEVEL, msg="Successful poll of %1 (#%2), next %3 (interval %4)"},
					luup.devices[p.device].description, p.device, p.nextattempt, p.interval)
				poll_device()
				D("check_job() closing task %1", tostring(task))
				task:close()
				return
			elseif st < 0 or st == 2 or st == 3 or (retries or 0) >= 5 then
				if st == 3 and (note or ""):lower():find("no commands to poll") then
					-- That means it's not a pollable device
					E("Not a pollable device #%1. Do something about it", dev)
					p.notpollable = true
				end
				L("Poll failed for %1 (#%2), marking for retry...", luup.devices[p.device].description, p.device)
				p.job = nil
				p.failedattempts = (p.failedattempts or 0) + 1
				p.nextattempt = p.lastattempt + 120 * math.min( 15, math.ceil(p.failedattempts / 2) )
				-- setVar( ZWDEVSID, "ConsecutivePollFails", p.failedattempts, p.device )
				setVar( ZWDEVSID, "PollOk", 0, p.device )
				-- ??? if 10 consecutive failed, stop polling it? only if we're watching the device, too
				L({level=2,msg="FAILED poll of %1 (#%2), %3 consecutive failures, next attempt %4"},
					luup.devices[p.device].description, p.device, p.failedattempts, p.nextattempt)
				poll_device()
				D("check_job() closing task %1", tostring(task))
				task:close()
				return
			elseif st == 0 then
				D("check_job() job still waiting to start")
				task:delay(5)
				return
			end
			D("check_job() status inconclusive, waiting...")
			task:delay(5, {}, { jobnum, dev, (retries or 0) + 1 })
			return
		end
	end
	E("Didn't find device for scheduled job %1 check; device %2", jobnum, dev)
	D("check_job() closing task %1", tostring(task))
	task:close()
end

-- poller
local function poller( task )
	D("poller(%1)", task)
	if not isEnabled() then
		setMessage("Disabled")
		return
	end

	task:delay(1800) -- default timing, may be moved in by poll_device()
	poll_device()
end

local function validDevice( k, v )
	D("validDevice(%1,%2)", k, v)
	if v.description == "_Scene Controller" and
		v.device_type == "urn:schemas-micasaverde-com:device:SceneController:1" and
		v.invisible then return false end
	-- Wakeup devices are not polled by this plugin, Vera must do it.
	if getVarNumeric( "WakeupInterval", -999, k, ZWDEVSID ) >= 0 then return false end
	-- Battery devices (which are wakeup devices); extra check.
	if getVarNumeric( "BatteryLevel", -999, k, HASID ) >= 0 then return false end
	-- Otherwise it's good!
	return true
end

local function hookEligibleDevices()
	D("hookEligibleDevices()")
	local pt = sysScheduler.getTask("poller")
	if pt then pt:suspend() end
	pollDevices = {}
	for k,v in pairs( luup.devices ) do
		unWatch( k, ZWDEVSID, "PollSettings" ) -- unconditional
		if v.device_num_parent == 1 and validDevice( k, v ) then
			-- Z-Wave device
			D("hookEligibleDevices() evaluating %1 (#%2)", v.description, k)
			local pc = getVar( "PollCommands", "", k, ZWDEVSID )
			if pc == "X" then
				D("hookEligibleDevices() ignoring %1 (#%2): does not respond to poll commands", v.description, k)
			elseif getVarNumeric( "tb_verapollonly", 0, k, ZWDEVSID ) ~= 0 then
				L("Skipping %1 (#%2), configured for Vera polling only", v.description, k)
			else
				local pv = getVar( "PollSettings", "", k, ZWDEVSID )
				local tpv = luup.variable_get( ZWDEVSID, "tb_pollsettings", k )
				if tpv == nil or tpv == "X" then
					-- First time seeing this device.
					L("Taking over polling for %1 (#%2)", v.description, k)
					setVar( ZWDEVSID, "tb_pollsettings", pv, k )
					setVar( ZWDEVSID, "PollSettings", 0, k )
					tpv = pv
				else
					setVar( ZWDEVSID, "PollSettings", 0, k )
				end
				addWatch( k, ZWDEVSID, "PollSettings" )
				tpv = tonumber(tpv) or 1800
				if tpv == 0 then tpv = 1800 elseif tpv < 60 then tpv = 60 end
				local lp = getVarNumeric( "LastPollSuccess", 0, k, ZWNETSID )
				table.insert( pollDevices, { device=k, interval=tpv, lastattempt=lp, nextattempt=lp+tpv } )
				L("Added %1 (#%2) to list, interval %3, next %4", v.description, k, tpv, lp+tpv)
			end
		else
			D("hookEligibleDevices() ineligible device #%1 %2", k, v)
		end
	end
end

local function unhook( k )
	D("unhook(%1)", k)
	unWatch( k, ZWDEVSID, "PollSettings" )
	local pc = getVar( "PollCommands", "", k, ZWDEVSID )
	if pc ~= "X" then
		pc = getVar( "tb_pollsettings", "X", k, ZWDEVSID )
		if pc ~= "X" then
			setVar( ZWDEVSID, "tb_pollsettings", "X", k )
			setVar( ZWDEVSID, "PollSettings", pc, k )
		end
	end
end

-- plugin_runOnce() looks to see if a core state variable exists; if not, a one-time initialization
-- takes place.
local function plugin_runOnce( pdev )
	D("plugin_runOnce(%1)", pdev)
	local s = getVarNumeric("Version", 0, pdev, MYSID)
	if s == 0 then
		L("First run, setting up new plugin instance...")
	end

	initVar( "Message", "Initializing...", pdev, MYSID )
	initVar( "Enabled", "0", pdev, MYSID )
	initVar( "DebugMode", "0", pdev, MYSID )
	initVar( "MeshBusyHoldOff", "", pdev, MYSID )

	-- Consider per-version changes.

	-- Update version last.
	setVar( MYSID, "Version", _CONFIGVERSION, pdev )
end

function actionPollDevice( dev, param, job )
	D("actionPollDevice(%1,%2,%3)", dev, param, job)
	local n = tonumber(param.DeviceNum) or -1
	if n and luup.devices[n] and luup.devices[n].device_num_parent == 1 then
		ix = (ix or 0) + 1
		luup.job.set("comments", ix)
		local ra,rb,rc,rd = luup.call_action( HASID, "Poll", {}, tonumber(param.DeviceNum) or -1 )
		D("actionPollDevice() Poll action returns %1, %2, %3, %4", ra, rb, rc, rd)
		return 4,0
	else
		E("Device %1 not found or not ZWave device", param.DeviceNum)
		return 2,0
	end
end

function actionSetEnabled( tdev, param )
	D("setEnabled(%1,%2)", tdev, param)
	local enabled = param.NewEnabledState
	if type(enabled) == "string" then
		if enabled:lower() == "false" or enabled:lower() == "disabled" or enabled == "0" then
			enabled = false
		else
			enabled = true
		end
	elseif type(enabled) == "number" then
		enabled = enabled ~= 0
	elseif type(enabled) ~= "boolean" then
		return
	end
	setVar( MYSID, "Enabled", enabled and "1" or "0", tdev )
end

function actionSetDebug( tdev, param ) -- luacheck: ignore 212
	local d = param.debug or "1"
	debugMode = d ~= "0"
	if debugMode then
		D("Debug enabled")
	end
end

local function waitSystemReady( task, pdev )
	D("waitSystemReady(%1,%2)", tostring(task), pdev)
	if not getVarBool( "SuppressSystemReadyCheck", false, pdev, MYSID ) then
		for n,d in pairs(luup.devices) do
			if d.device_type == "urn:schemas-micasaverde-com:device:ZWaveNetwork:1" then
				local sysStatus = luup.variable_get( "urn:micasaverde-com:serviceId:ZWaveNetwork1", "NetStatusID", n )
				if sysStatus ~= nil and sysStatus ~= "1" then
					-- Z-Wave not yet ready
					setMessage("Waiting for Z-Wave ready")
					L("waiting for Z-Wave ready, status %1", sysStatus)
					task:delay(5)
					return
				else
					L("Z-Wave ready detected!")
				end
				break
			end
		end
	end
	pollHoldOff = os.time() + 60
	sysScheduler.getTask("poller"):delay(1)
	task:close()
end

-- Start plugin running.
function startPlugin( pdev )
	L("version %2, device %1 (%3)", pdev, _PLUGIN_VERSION, luup.devices[pdev].description)
	assert( ( luup.devices[pdev].device_num_parent or 0 ) == 0 )

	-- Early inits
	pluginDevice = pdev
	isALTUI = false
	isOpenLuup = false
	pollDevices = {}
	math.randomseed(os.time())

	-- Check for ALTUI and OpenLuup
	for k,v in pairs(luup.devices) do
		if v.device_type == "urn:schemas-upnp-org:device:altui:1" and v.device_num_parent == 0 then
			D("start() detected ALTUI at %1", k)
			isALTUI = true
			local rc,rs,jj,ra = luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin",
				{
					newDeviceType=MYTYPE,
					newScriptFile="J_PollRepair_ALTUI.js",
					newDeviceDrawFunc="PollRepair_ALTUI.deviceDraw",
					newStyleFunc="PollRepair_ALTUI.getStyle"
				}, k )
			D("startTimer() ALTUI's RegisterPlugin action for %5 returned resultCode=%1, resultString=%2, job=%3, returnArguments=%4", rc,rs,jj,ra, MYTYPE)
		elseif v.device_type == "openLuup" then
			D("start() detected openLuup")
			isOpenLuup = true
		end
	end

	-- Check UI version
	if not checkVersion( pdev ) then
		L({level=1,msg="This plugin does not run on this firmware."})
		luup.set_failure( 1, pdev )
		return false, "Incompatible firmware", _PLUGIN_NAME
	end

	-- One-time stuff
	plugin_runOnce( pdev )

	-- Debug?
	if getVarNumeric( "DebugMode", 0, pdev, MYSID ) ~= 0 then
		debugMode = true
		L("Debug mode enabled by state variable")
	end

	-- Initialize and start the scheduler; create the poller task, but don't start it yet.
	sysScheduler = TaskManager( "pollRepairTick" )
	sysScheduler.Task:new( "poller", pdev, poller, { pdev } )

	if getVarNumeric( "MeshBusyHoldOff", 20, pluginDevice, MYSID ) > 0 then
		luup.job_watch( 'pollRepairJob' )
	end
	addWatch( pdev, MYSID, "Enabled" )
	addWatch( pdev, MYSID, "DebugMode" )

	if not isEnabled( pdev )then
		setMessage("Disabled")
		L{level=2,msg="PollRepair has been disabled by configuration; startup aborting."}
		return true, "Disabled", _PLUGIN_NAME
	end

	-- Set up devices
	hookEligibleDevices()
	L("%1 eligible devices at startup", #pollDevices)

	-- Wait for system ready. When ready, it will start the poller.
	setMessage("Waiting for Z-Wave ready")
	sysScheduler.Task:new("sysready", pdev, waitSystemReady, { pdev } ):delay(15)

	-- Return success
	luup.set_failure( 0, pdev )
	return true, "Ready", _PLUGIN_NAME
end

function timer_callback(p)
	D("timer_callback(%1)", p)
	sysScheduler.runReadyTasks(p)
end

function watch_callback( dev, sid, var, oldVal, newVal )
	D("watch_callback(%1,%2,%3,%4,%5)", dev, sid, var, oldVal, newVal)
	if oldVal == newVal then return end -- no change
	if dev == pluginDevice and sid == MYSID then
		if var == "DebugMode" then
			debugMode = newVal ~= "0"
			L("Debug logging "..(debugMode and "enabled" or "disabled"))
		elseif var == "Enabled" then
			if newVal ~= "0" then
				-- start new timer thread
				setMessage("Restarting...")
				local task = sysScheduler.getTask("poller")
				if task then task:suspend() end
				hookEligibleDevices()
				if #pollDevices > 0 then
					task:delay(0)
				else
					W("No eligible devices.")
				end
			else
				-- Disable
				setMessage("Disabled.")
				local task = sysScheduler.getTask("poller")
				if task then task:suspend() end
				while #pollDevices > 0 do
					unhook( pollDevices[1].device )
					table.remove( pollDevices, 1 )
				end
			end
		end
	elseif sid == ZWDEVSID then
		local watchkey = string.format("%d/%s/%s", dev or 0, sid or "X", var or "X")
		if not watchData[watchkey] then return end
		-- We know it's a managed device
		if var == "PollSettings" then
			D("watch_callback() PollSettings %3 -> %4 on %1 (#%2)", luup.devices[dev].description, dev, oldVal, newVal)
			local nnew = tonumber(newVal)
			if nnew ~= 0 then
				L("Detected PollSettings change for %1 (#%2); now %3", luup.devices[dev].description, dev, nnew)
				setVar( ZWDEVSID, "tb_pollsettings", newVal, dev ) -- yes, newVal (benign fail for string value)
				setVar( ZWDEVSID, "PollSettings", 0, dev ) -- nada if already 0
			end
		end
	end
end

function job_callback( jobdata, b, c )
	D("job_callback(%1,%2,%3)", jobdata, b, c)
	if jobdata.type ~= "ZWJob_PollNode" then
		-- Something other than polling is going on, defer new poll jobs
		-- NB can't really tell what type of job, so must assume all jobs are mesh-related. Harmless?
		local m = getVarNumeric( "MeshBusyHoldOff", 20, pluginDevice, MYSID )
		if m > 0 then
			pollHoldOff = os.time() + m
			D("job_callback() holding off new poll jobs until %1", pollHoldOff)
		end
	end
end

local EOL = "\r\n"

function request( lul_request, lul_parameters, lul_outputformat )
	D("request(%1,%2,%3) luup.device=%4", lul_request, lul_parameters, lul_outputformat, luup.device)
	local action = lul_parameters['action'] or lul_parameters['command'] or ""
	--local deviceNum = tonumber( lul_parameters['device'], 10 ) or luup.device
	if action == "debug" then
		debugMode = not debugMode
		D("debug mode is now %1", debugMode)
		return "Debug mode is now " .. ( debugMode and "on" or "off" ), "text/plain"
	end

	if action == "capabilities" then
		return "{actors={}}", "application/json"
	elseif action == "status" then
		local json = require "dkjson"
		local st = {
			name=_PLUGIN_NAME,
			plugin=_PLUGIN_ID,
			version=_PLUGIN_VERSION,
			configversion=_CONFIGVERSION,
			author="Patrick H. Rigney (rigpapa)",
			url=_PLUGIN_URL,
			['type']=MYTYPE,
			responder=luup.device,
			timestamp=os.time(),
			system = {
				version=luup.version,
				isOpenLuup=isOpenLuup,
				isALTUI=isALTUI,
				units=luup.attr_get( "TemperatureFormat", 0 ),
			},
			devices={},
			pollDevices=pollDevices
		}
		return "PLEASE COPY THIS ENTIRE OUTPUT WITHOUT CHANGES"..EOL.."```"..EOL..json.encode( st )..EOL.."```", "text/plain"
	else
		return "Not implemented: " .. action, "text/plain"
	end
end
