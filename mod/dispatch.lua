
local threads = require("__debugadapter__/threads.lua")

local string = string
local smatch = string.match

local debug = debug
local dgetinfo = debug.getinfo

---@type LuaRemote
local remote = (type(remote)=="table" and rawget(remote,"__raw")) or remote
local rcall = remote and remote.call

local script = script

local pairs = pairs

local env = _ENV
local _ENV = nil

---@class DebugAdapter.Dispatch
local dispatch = {}

local __daremote = {}
local __inner = {}
dispatch.__inner = __inner
local __remote = {}
dispatch.__remote = __remote
if remote then
  if script.mod_name ~= "debugadapter" then
    remote.add_interface("__debugadapter_" .. script.mod_name, __remote)
  else
    remote.add_interface("debugadapter", __daremote)
  end
end

local function isMainChunk()
  local i = 2 -- no need to check getinfo or isMainChunk
  ---@type string
  local what
  while true do
    local info = dgetinfo(i,"S")
    if info then
      what = info.what
      i = i + 1
    else
      break
    end
  end
  return what == "main"
end

local function canRemoteCall()
  -- remote.call is only legal from within events, game catches all but on_load
  -- during on_load, script exists and the root of the stack is no longer the main chunk
  return not not (env.game or script and not isMainChunk())
end

--- call a remote function in all registered mods
---@param funcname string Name of remote function to call
---@param ... Any
function dispatch.callAll(funcname,...)
  if canRemoteCall() then
    for remotename,interface in pairs(remote.interfaces) do
      local modname = smatch(remotename,"^__debugadapter_(.+)$")
      if modname and interface[funcname] then
        rcall(remotename,funcname,...)
      end
    end
  else
    __inner[funcname](...)
  end
end

--- call a remote function in all registered mods until one returns true
---@param funcname string Name of remote function to call
---@param ... Any
---@return boolean
function dispatch.find(funcname,...)
  -- try local first...
  if __inner[funcname](...) then
    return true
  end

  -- then call around if possible...
  if canRemoteCall() then
    for remotename,interface in pairs(remote.interfaces) do
      local modname = smatch(remotename,"^__debugadapter_(.+)$")
      if modname and interface[funcname] then
        if rcall(remotename,funcname,...) then
          return true
        end
      end
    end
  end
  return false
end


--- try to call a remote function in a specific mod
---@param modname string
---@param funcname string Name of remote function to call
---@param ... Any
---@return boolean
---@return ...
function dispatch.callMod(modname, funcname, ...)
  if modname == script.mod_name then
    return true, __inner[funcname](...)
  end

  if canRemoteCall() then
    local remotename = "__debugadapter_"..modname
    local interface = remote.interfaces[remotename]
    if interface and interface[funcname] then
      return true, rcall(remotename, funcname, ...)
    end
  end

  return false
end

--- try to call a remote function in a specific thread
---@param threadid integer
---@param funcname string Name of remote function to call
---@param ... Any
---@return boolean
---@return ...
function dispatch.callThread(threadid, funcname, ...)
  if threadid == threads.this_thread then
    return true, __inner[funcname](...)
  end

  local thread = threads.active_threads[threadid]
  if canRemoteCall() then
    local remotename = "__debugadapter_"..thread.name
    local interface = remote.interfaces[remotename]
    if interface and interface[funcname] then
      return true, rcall(remotename, funcname, ...)
    end
  end

  return false
end

--- try to call a remote function in a specific stack frame
---@param frameId integer
---@param funcname string Name of remote function to call
---@param ... Any
---@return boolean
---@return ...
function dispatch.callFrame(frameId, funcname, ...)
  local thread,i,tag = threads.splitFrameId(frameId)
  if thread.id == threads.this_thread then
    return true, __inner[funcname](i, tag, ...)
  end

  if canRemoteCall() then
    local remotename = "__debugadapter_"..thread.name
    local interface = remote.interfaces[remotename]
    if interface and interface[funcname] then
      return true, rcall(remotename, funcname, i, tag, ...)
    end
  end

  return false
end

do
  ---@type {[string]:function}
  local bindings = {}

  --- get or set functions for late binding
  ---@param name string
  ---@param f? function
  ---@return function?
  function dispatch.bind(name, f)
    if f then
      bindings[name] = f
    else
      return bindings[name]
    end
  end
end


do
  -- functions for passing stepping state across context-switches by handing it to main DA vm

  ---@type number?
  local cross_stepping
  ---@type boolean?
  local cross_step_instr

  ---@param clear? boolean default true
  ---@return number? stepping
  ---@return boolean? step_instr
  function dispatch.getStepping(clear)
    if script and script.mod_name ~= "debugadapter" and canRemoteCall() and remote.interfaces["debugadapter"] then
      return rcall--[[@as fun(string,string,boolean?):number?,boolean?]]("debugadapter", "getStepping", clear)
    else
      local stepping,step_instr = cross_stepping, cross_step_instr
      if clear ~= false then
        cross_stepping,cross_step_instr = nil,nil
      end

      return stepping,step_instr
    end
  end
  __daremote.getStepping = dispatch.getStepping

  ---@param stepping? number
  ---@param step_instr? boolean
  function dispatch.setStepping(stepping, step_instr)
    if script and script.mod_name ~= "debugadapter" and canRemoteCall() and remote.interfaces["debugadapter"] then
      rcall("debugadapter", "setStepping", stepping, step_instr)
      return
    else
      cross_stepping = stepping
      cross_step_instr = step_instr
    end
  end
  __daremote.setStepping = dispatch.setStepping
end


return dispatch