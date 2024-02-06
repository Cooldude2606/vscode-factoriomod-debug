local rawxpcall = xpcall
local debug = debug
local table = table
local print = print
local pairs = pairs
local error = error
local type = type
local select = select
---@type fun(ls:LocalisedString)
local localised_print = localised_print
local __DebugAdapter = __DebugAdapter
local setmetatable = setmetatable
local nextuple = require("__debugadapter__/iterutil.lua").nextuple
local json = require("__debugadapter__/json.lua")
local variables = require("__debugadapter__/variables.lua") -- uses pcall

---@class DebugAdapter.Entrypoints
local DAEntrypoints = {}

---Print an exception to the editor
---@param etype string
---@param mesg string|LocalisedString|nil
local function print_exception(etype,mesg)
  if mesg == nil then mesg = "<nil>" end

  if type(mesg) == "table" and not getmetatable(mesg) and #mesg>=1 and type(mesg[1])=="string" then
    mesg = "\xEF\xB7\x94"..variables.translate(mesg)
  end

  print("\xEF\xB7\x91"..json.encode{event="exception", body={
    threadId = __DebugAdapter.this_thread,
    filter = etype,
    mesg = mesg,
    }})
end
DAEntrypoints.print_exception = print_exception

---Generate a breakpoint or exception from mod code
---@param mesg string|LocalisedString|nil
function DAEntrypoints.breakpoint(mesg)
  debug.sethook()
  if mesg then
    print_exception("manual",mesg)
  else
    print("\xEF\xB7\x91"..json.encode{event="stopped", body={
      reason = "breakpoint",
      threadId = __DebugAdapter.this_thread,
      }})
  end
  debug.debug()
  return __DebugAdapter.attach()
end


---Terminate a debug session from mod code
function DAEntrypoints.terminate()
  debug.sethook()
  print("\xEF\xB7\x90\xEE\x80\x8C")
  debug.debug()
end

---Generate handlers for pcall/xpcall wrappers
---@param filter string Where the exception was intercepted
---@param user_handler? function When used as xpcall, the exception will pass to this handler after continuing
---@return function
local function caught(filter, user_handler)
  ---xpcall handler for intercepting pcall/xpcall
  ---@param mesg string|LocalisedString
  ---@return string|LocalisedString mesg
  return __DebugAdapter.stepIgnore(function(mesg)
    debug.sethook()
    print_exception(filter,mesg)
    debug.debug()
    __DebugAdapter.attach()
    if user_handler then
      return user_handler(mesg)
    else
      return mesg
    end
  end)
end
__DebugAdapter.stepIgnore(caught)

---`pcall` replacement to redirect the exception to display in the editor
---@param func function
---@vararg any
---@return boolean success
---@return any result
---@return ...
function pcall(func,...)
  return rawxpcall(func, caught("pcall"), ...)
end
__DebugAdapter.stepIgnore(pcall)

---`xpcall` replacement to redirect the exception to display in the editor
---@param func function
---@param user_handler function
---@vararg any
---@return boolean success
---@return any result
---@return ...
function xpcall(func, user_handler, ...)
  return rawxpcall(func, caught("xpcall",user_handler), ...)
end
__DebugAdapter.stepIgnore(xpcall)

-- don't need the rest in data stage...
if not script then return DAEntrypoints end

---@type table<function,string>
local handlernames = setmetatable({},{__mode="k"})
---@type table<string,function>
local hashandler = {}

---@type {[defines.events|uint|string]:function}
local event_handler = {}
---@param id defines.events|string
---@param f? function
---@return function?
local function save_event_handler(id,f)
  event_handler[id] = f
  return f
end

---@type {[string]:{[string]:function}}
local myRemotes = {}

-- possible entry points (in control stage):
--   main chunks (identified above as "(main chunk)")
--     control.lua init and any files it requires
--     migrations
--     /c __modname__ command
--     simulation scripts (as commands)
--   remote.call
--   event handlers
--     if called by raise_event, has event.mod_name
--   /command handlers
--   special events:
--     on_init, on_load, on_configuration_changed, on_nth_tick

---Look up the label for an entrypoint function
---@param func function
---@return string? label
function DAEntrypoints.getEntryLabel(func)
  do
    local handler = handlernames[func]
    if handler then
      return handler
    end
  end
  -- it would be nice to pre-calculate all this, but changing the functions in a
  -- remote table at runtime is actually valid, so an old result may not be correct!
  for name,interface in pairs(myRemotes) do
    for fname,f in pairs(interface) do
      if f == func then
        return "remote "..fname.."::"..name
      end
    end
  end
  return
end

---Record a handler label for a function and return that functions
---@generic F:function
---@param func? F
---@param entryname string
---@return F? func
local function labelhandler(func,entryname)
  if func then
    if handlernames[func] then
      handlernames[func] = "(shared handler)"
    else
      handlernames[func] = entryname
    end
    do
      local oldhandler = hashandler[entryname]
      if oldhandler and oldhandler ~= func then
        __DebugAdapter.print("Replacing existing {entryname} {oldhandler} with {func}",nil,3,"console",true)
      end
    end
  end
  hashandler[entryname] = func
  return func
end
__DebugAdapter.stepIgnore(labelhandler)

local oldscript = script
local newscript = {
  __raw = oldscript
}

---Simulate an event being raised in the target mod ("level" for the scenario).
---Event data is not validated in any way.
---@param event defines.events|number|string
---@param data EventData
---@param modname string
function DAEntrypoints.raise_event(event,data,modname)
  if modname and modname ~= oldscript.mod_name then
    if game and remote.interfaces["__debugadapter_"..modname] then
      return remote.call("__debugadapter_"..modname,"raise_event",event,data)
    else
      error("cannot raise events here")
    end
  else
    local f = event_handler[event]
    if f then
      return f(data)
    end
  end
end

---@param f? function
function newscript.on_init(f)
  oldscript.on_init(labelhandler(f,"on_init handler"))
end
newscript.on_init()

---@param f? function
function newscript.on_load(f)
  oldscript.on_load(labelhandler(f,"on_load handler"))
end
newscript.on_load()

---@param f? function
function newscript.on_configuration_changed(f)
  return oldscript.on_configuration_changed(labelhandler(f,"on_configuration_changed handler"))
end

---@param tick uint|uint[]|nil
---@param f fun(x:NthTickEventData)|nil
---@overload fun(x:nil)
function newscript.on_nth_tick(tick,f)
  if not tick then
    if f then
      -- pass this through for the error...
      return oldscript.on_nth_tick(tick,f)
    else
      -- just in case somebody gives me a `false`...
      return oldscript.on_nth_tick(tick)
    end
  else
    local ttype = type(tick)
    if ttype == "number" then
      return oldscript.on_nth_tick(tick,labelhandler(f,("on_nth_tick %d handler"):format(tick)))
    elseif ttype == "table" then
      return oldscript.on_nth_tick(tick,labelhandler(f,("on_nth_tick {%s} handler"):format(table.concat(tick,","))))
    else
      error("Bad argument `tick` expected number or table got "..ttype,2)
    end
  end
end

---@param event defines.events|string|defines.events[]
---@param f fun(e:EventData)|nil
---@vararg table
---@overload fun(event:defines.events,f:fun(e:EventData)|nil, filters:table)
---@overload fun(event:string,f:fun(e:EventData)|nil)
---@overload fun(events:defines.events[],f:fun(e:EventData)|nil)
function newscript.on_event(event,f,...)
  -- on_event checks arg count and throws if event is table and filters is present, even if filters is nil
  local etype = type(event)
  ---@type boolean
  local has_filters = select("#",...)  > 0
  if etype == "number" then ---@cast event defines.events
    local evtname = ("event %d"):format(event)
    for k,v in pairs(defines.events) do
      if event == v then
        ---@type string
        evtname = k
        break
      end
    end
    return oldscript.on_event(event,labelhandler(save_event_handler(event,f), ("%s handler"):format(evtname)),...)
  elseif etype == "string" then
    if has_filters then
      error("Filters can only be used when registering single events.",2)
    end
    return oldscript.on_event(event,labelhandler(save_event_handler(event,f), ("%s handler"):format(event)))
  elseif etype == "table" then
    if has_filters then
      error("Filters can only be used when registering single events.",2)
    end
    for _,e in pairs(event) do
      newscript.on_event(e,f)
    end
  else
    error({"","Invalid Event type ",etype},2)
  end
end


local newscriptmeta = {
  __index = oldscript,
  ---@param t table
  ---@param k any
  ---@param v any
  __newindex = function(t,k,v) oldscript[k] = v end,
  __debugline = "<LuaBootstrap Debug Proxy>",
  __debugtype = "DebugAdapter.LuaBootstrap",
}
setmetatable(
  __DebugAdapter.stepIgnore(newscript),
  __DebugAdapter.stepIgnore(newscriptmeta)
)

local oldcommands = commands
local newcommands = {
  __raw = oldcommands,
}

---@param name string
---@param help string|LocalisedString
---@param f function
function newcommands.add_command(name,help,f)
  return oldcommands.add_command(name,help,labelhandler(f, "command /" .. name))
end

---@param name string
function newcommands.remove_command(name)
  labelhandler(nil, "command /" .. name)
  return oldcommands.remove_command(name)
end

local newcommandsmeta = {
  __index = oldcommands,
  ---@param t table
  ---@param k any
  ---@param v any
  __newindex = function(t,k,v) oldcommands[k] = v end,
  __debugline = "<LuaCommandProcessor Debug Proxy>",
  __debugtype = "DebugAdapter.LuaCommandProcessor",
}
setmetatable(
  __DebugAdapter.stepIgnore(newcommands),
  __DebugAdapter.stepIgnore(newcommandsmeta)
)

local oldremote = remote
local newremote = {
  __raw = oldremote,
}

---@param remotename string
---@param funcs table<string,function>
function newremote.add_interface(remotename,funcs)
  myRemotes[remotename] = funcs
  return oldremote.add_interface(remotename,funcs)
end

---@param remotename string
function newremote.remove_interface(remotename)
  myRemotes[remotename] = nil
  return oldremote.remove_interface(remotename)
end

local remotemeta = {
  __index = oldremote,
  ---@param t table
  ---@param k any
  ---@param v any
  __newindex = function(t,k,v) oldremote[k] = v end,
  __debugline = "<LuaRemote Debug Proxy>",
  __debugtype = "DebugAdapter.LuaRemote",
  __debugcontents = function()
    return nextuple, {
      ["interfaces"] = {oldremote.interfaces},
      ["<raw>"] = {oldremote, {rawName = true, virtual = true}},
      ["<myRemotes>"] = {myRemotes, {rawName = true, virtual = true}},
    }
  end,
}
setmetatable(
  __DebugAdapter.stepIgnore(newremote),
  __DebugAdapter.stepIgnore(remotemeta)
)

script = newscript
commands = newcommands
remote = newremote

return DAEntrypoints