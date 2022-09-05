--- Module to interact with the Philips Hue api.
-- This module will connect and stream events to enable real-time updates.
--
-- This requires the Copas scheduler.
--
-- @copyright Copyright (c) 2022-2022 Thijs Schreijer
-- @author Thijs Schreijer
-- @license MIT, see `LICENSE`.


local url = require "socket.url"
local ltn12 = require "ltn12"
local json = require "cjson.safe"
local sse = require "copas-sse.client"
local http = require "copas.http"
local Lock = require("copas.lock")

--- The module table
-- @table Hue
--
-- @field log
-- Logger is set on the module table, to be able to override it.
-- Default is the LuaLogging default logger (if loaded), or a no-op function.

local Hue = {}
Hue._VERSION = "0.0.1"
Hue._COPYRIGHT = "Copyright (c) 2022-2022 Thijs Schreijer"
Hue._DESCRIPTION = "Lua module to interact with Philips Hue devices, based on the Copas scheduler."
Hue.__index = Hue
Hue.log = require "philips-hue.log"

--- Current connection state (read-only). See `Hue.states`.
-- @field Hue.state


--- Constants to match `hue.state` (read-only). Eg. `if hue.state ==
-- Hue.states.CONNECTING then ...`.
-- Values are; `INITIALIZING`, `CONNECTING`, `OPEN`, `CLOSED`.
-- @field Hue.states
Hue.states = setmetatable({
  INITIALIZING = "initializing",
  CONNECTING = "connecting",
  OPEN = "open",
  CLOSED = "closed",
}, {
  __index = function(self, key)
    error("'"..tostring(key).."' is not a valid state, use 'INITIALIZING', 'CONNECTING', 'OPEN', or 'CLOSED'", 2)
  end,
})


local function set_state(self, new_state)
  if self.state == new_state then return end
  self.state = new_state
  self:callback {
    client = self,
    type = "status",
    event = self.state,
  }
end


local function deepcopy(t)
  -- TODO: poor man's copying
  return json.decode(json.encode(t))
end


local function urlencode(t)
  if t == nil then
    return ""
  end
  local result = {}
  local i = 0  -- 0: first '&' will hence be dropped, by concat
  for k, v in pairs(t) do
    result[i] = "&"
    result[i+1] = url.escape(k)
    result[i+2] = "="
    result[i+3] = url.escape(v)
    i = i + 4
  end
  return table.concat(result)
end



-- Performs a HTTP request on the Hue API.
-- @param path (string) the relative path within the API base path
-- @tparam[opt="GET"] string method HTTP method to use
-- @param headers (table) optional header table
-- @param query (table) optional query parameters (will be escaped)
-- @param body (table/string) optional body. If set the "Content-Length" will be
-- added to the headers. If a table, it will be send as json-encoded, and the
-- "Content-Type" header will be set to "application/json".
-- @return ok, response_body, response_code, response_headers, response_status_line
local function hue_request(self, path, method, headers, query, body)
  local response_body = {}
  headers = headers or {}

  query = "?" .. urlencode(query)
  if query == "?" then
    query = ""
  end

  if type(body) == "table" then
    body = json.encode(body)
    headers["Content-Type"] =  "application/json"
  end
  headers["Content-Length"] = #(body or "")

  local r = {
    method = method or "GET",
    url = assert(path, "1st parameter 'path' missing") .. query,
    headers = headers,
    source = ltn12.source.string(body or ""),
    sink = ltn12.sink.table(response_body),
  }
  self.log:debug("[hue] making api request to: %s %s", r.method, r.url)

  local ok, response_code, response_headers, response_status_line = http.request(r)
  if not ok then
    self.log:error("[hue] api request failed with: %s", response_code)
    return ok, response_code, response_headers, response_status_line
  end

  if type(response_body) == "table" then
    response_body = table.concat(response_body)
  end

  for name, value in pairs(response_headers) do
    if name:lower() == "content-type" and value:find("application/json", 1, true) then
      -- json body, decode
      response_body = assert(json.decode(response_body))
      break
    end
  end

  self.log:debug("[hue] api request returned: %s", response_code)

  return ok, response_body, response_code, response_headers, response_status_line
end



local discover_bridge do

  -- retrieves a single IP for the bridge, or nil+err
  local function discover_bridge_nupnp()
    local body, status, _, line = http.request("https://discovery.meethue.com")
    if not body then
      return nil, "pupnp discovery failed: ".. tostring(status)
    end

    if tonumber(status) ~= 200 then
      return nil, "pupnp discovery failed: ".. tostring(line)
    end

    local data, err = json.decode(body)
    if not data then
      return nil, "pupnp discovery, failed decoding json: "..tostring(err)
    end

    local result = {}
    for _, record in ipairs(data) do
      result[#result + 1] = record.internalipaddress
    end

    if #result ~= 1 then
      if #result == 0 then
        return nil, "pupnp discovery, could not find bridge"
      end
      return nil, "pupnp discovery, too many bridges, please specify one. Found: "..table.concat(result, ", ")
    end

    return result[1]
  end


  local address, discovery_err, lock
  function discover_bridge(self)
    -- uses a lock to ensure we do this only once
    if address or discovery_err then
      return address, discovery_err
    end

    if not lock then
      lock = Lock.new(60)
    end

    lock:get()

    if address or discovery_err then
      -- a result was set by another thread
      lock:release()
      return address, discovery_err
    end

    address, discovery_err = discover_bridge_nupnp()
    lock:release()
    if address then
      self.log:info("[Hue] Found Hue bridge at "..address)
    else
      self.log:warn("[Hue] " .. discovery_err)
    end

    return address, discovery_err
  end
end


--- Performs a HTTP request on the Hue API.
-- NOTE: if the response_body is json, then it will be decoded and returned as
-- a Lua table.
-- @tparam string rel_path the relative path within the API base path (starts with '/')
-- @tparam[opt="GET"] string method HTTP method to use
-- @tparam[opt] table headers header table
-- @tparam[opt] table query query parameters (will be escaped)
-- @tparam[opt] table|string body if set the "Content-Length" will be
-- added to the headers. If a table, it will be send as JSON, and the
-- "Content-Type" header will be set to "application/json".
-- @return `ok`, `response_body`, `response_code`, `response_headers`, `response_status_line`
function Hue:request(rel_path, method, headers, query, body)
  local path = self.base_url .. rel_path

  headers = headers or {}
  headers["Hue-Application-Key"] = self.apikey

  return hue_request(self, path, method, headers, query, body)
end


-- Rewrite errors to Lua format (nil+error).
-- Takes the output of the `request` function and validates it for errors;
--
-- - nil+err
-- - body with "errors" field (json array)
-- - mismatch in expected status code (a 200 expected, but a 404 received)
--
-- This reduces the error handling to standard Lua errors, instead of having to
-- validate each of the situations above individually.
-- @tparam[opt=nil] number expected expected status code, if nil, it will be ignored
-- @param ... same parameters as the `request` method
-- @return nil+err or the input arguments
-- @usage
-- local Hue = require "philips-hue"
-- local client = Hue.new { apikey = "abcde" }
--
-- -- Make a request where we expect a 200 result
-- local ok, response_body, status, headers, statusline = client:rewrite_error(200, client:request("/devices", "GET"))
-- if not ok then
--   return nil, response_body -- a 404 will also follow this path now, since we only want 200's
-- end
local function rewrite_error(expected, ok, body, status, headers, ...)
  if not ok then
    return ok, body
  end

  if type(body) == "table" and type(body.errors) == "table" and #body.errors > 0 then
    return nil, tostring(status)..": "..json.encode(body.errors)
  end

  if expected ~= nil and expected ~= status then
    if type(body) == "table" then
      body = json.encode({body = body, headers = headers})
    end
    return nil, "bad return code, expected " .. expected .. ", got "..status..". Response: "..body
  end

  return ok, body, status, headers, ...
end



-- Gets resource data.
-- @tparam[opt] string rtype the resource type to retrieve, retrieves all if not specified
-- @return data element + full response, or nil+err
local function get_resource_data(self, rtype)
  local path = "/resource"
  if rtype then
    path = path .. "/" .. rtype
  end

  local ok, response_body = rewrite_error(200, self:request(path))
  if not ok then
    return nil, "failed to get data: "..response_body
  end

  return response_body.data
end


-- cleans object of deprecated properties
local hue_clean_object do
  -- fields listed per resource-type will be removed because they are obsolete
  local obsolete = {
    light = { "metadata" },
  }

  function hue_clean_object(resource)
    local to_clean = obsolete[resource.type] or {}
    for _, prop_name in ipairs(to_clean) do
      resource[prop_name] = nil
    end
  end
end


-- references will be replaced, and arrays of references will become weak hash-tables (by id).
-- calling this on recursive tables will hang!! so call it only once on every resource!!
local function hue_dereference(self, resource)
  for key, value in pairs(resource) do
    if type(value) == "table" then
      if value.rid and value.rtype then
        -- local str = tostring(resource.type) .. " has single ref to type " .. value.rtype
        -- check = check or {}
        -- if not check[str] then print(str); check[str] = true end

        -- replace by actual object if that exists
        if self.resources[value.rid] then
          resource[key] = self.resources[value.rid]
        end

      elseif (value[1] or {}).rid and (value[1] or {}).rtype then
        -- local str = tostring(resource.type) .. " has ref array to type " .. value[1].rtype
        -- check = check or {}
        -- if not check[str] then print(str); check[str] = true end

        -- replace an array of references, by weak hash-table, if objects exist
        if self.resources[value[1].rid] then
          local result = setmetatable({}, { __mode = "v" })
          for i, reference in ipairs(value) do
            local id = assert(reference.rid, "no 'rid' field in reference")
            result[id] = assert(self.resources[reference.rid], "object not found: "..reference.rtype.." "..reference.rid)
          end
          resource[key] = result
        end

      else
        -- recurse into the deeper structure
        hue_dereference(self, value)
      end
    end
  end
end


local function raise_hue_event(self, event, current, received)
  self:callback {
    client = self,
    type = "hue",
    event = event,
    current = current,
    received = received,
  }
end

-- This creates/adds to two structures
-- self.resources[id]   ; this table anchors the objects
-- self.types.light[id] ; (where "light" is just one type), these tables are weak!!!
local function hue_add_resources(self, list)
  for _, resource in ipairs(list) do
    if self.resources[resource.id] then
      self.log:error("[hue] adding a resource that already existed, type '%s': %s", resource.type, resource.id)
    end

    self.resources[resource.id] = resource
    self.types[resource.type][resource.id] = resource
    self.log:debug("[hue] added a '%s' with id '%s'", resource.type, resource.id)
  end

  -- all ID's are now inserted, hence 'known'. So we can start dereferencing.
  local list_copy = deepcopy(list)  -- copy; the event will pass data without dereferencing
  for _, resource in ipairs(list) do
    hue_dereference(self, resource)
  end

  for i = 1, #list do
    -- pass stored (dereferenced) as well as received resource (not dereferenced) to event handler
    raise_hue_event(self, "add", list[i], list_copy[i])
  end
end


local hue_update_resources do
  local function update_resource_table(self, existing, new, trace)
    -- copy data into existing resource, to keep table-equality alive
    -- DO NOT copy reference fields!
    -- does the recieved data have ALL fields? or just changed fields?
    -- former: then delete field not in new object, latter: only take fields from new, do not delete any
    for key, value in pairs(new) do
      if type(value) ~= "table" then
        -- scalar value
        if existing[key] == value then
          new[key] = nil -- no change, so do not report
        else
          self.log:debug("[hue] update value '%s.%s = %s' from '%s'", trace, key, tostring(value), tostring(existing[key]))
          existing[key] = value -- changed, so update and leave to report
        end

      else -- a table
        if value.rid and value.rtype then
          -- a reference value
          if type(existing[key]) == "table" and existing[key].id == value.rid then
            -- a reference, but it didn't change
            new[key] = nil -- clear to not report

          elseif type(existing[key]) == "table" and existing[key].rid == value.rid then
            -- a reference that was not dereferenced, also didn't change
            new[key] = nil -- clear to not report

          elseif existing[key] == nil then
            -- a reference that is new
            existing[key] = self.resources[value.rid]
            if not existing[key] then
              -- dereference failed, keep the ref
              existing[key] = {
                rid = value.rid,
                rtype = value.rtype,
              }
            end

          else
            -- This is wrong? a non-table changed to a reference table
            self.log:error("[hue] updating a resource: a non-table changed to a reference table, key: '%s'", key)
          end

        else
          -- a non-reference sub table
          if existing[key] == nil then
            existing[key] = {}
          end
          if type(existing[key]) ~= "table" then
            -- This is wrong? a non-table changed to a table
            self.log:error("[hue] updating a resource: a non-table changed to a table, key: '%s'", key)
          else
            update_resource_table(self, existing[key], value, trace .. "." .. tostring(key))  -- recurse sub table
            if not next(value) then
              -- table returned empty, so drop it
              new[key] = nil
            end
          end
        end
      end
    end
  end

  function hue_update_resources(self, list)
    for _, resource in ipairs(list) do
      local existing = self.resources[resource.id]
      if not existing then
        self.log:error("[hue] updating a resource that doesn't exist, type '%s': %s", resource.type, resource.id)
      else
        self.log:debug("[hue] updated '%s' with id '%s'", resource.type, resource.id)
        update_resource_table(self, existing, resource, resource.id)
        raise_hue_event(self, "update", existing, resource)
      end
    end
  end
end


local function hue_delete_resources(self, list)
  for _, resource in ipairs(list) do
    local existing_resource = self.resources[resource.id]
    if not existing_resource then
      self.log:error("[hue] deleting a resource that doesn't exist, type '%s': %s", resource.type, resource.id)
    else
      self.resources[resource.id] = nil
      self.types[resource.type][resource.id] = nil
      self.log:debug("[hue] deleted '%s' with id '%s'", resource.type, resource.id)
      -- pass "existing_resource" (dereferenced) as well as received resource (not dereferenced) to event handler
      raise_hue_event(self, "delete", existing_resource, resource)
    end
  end
end



-- Handles list of Hue events.
local function event_list_handler(self, event_data, event_name, event_id)
  for _, hue_events in ipairs(event_data) do
    local hue_event_type = hue_events.type -- 'update', 'add', 'delete', or 'error'

    -- cleanup resource list
    for _, resource in ipairs(hue_events.data) do
      hue_clean_object(resource)
    end

    -- handle list of events of this specific type
    if hue_event_type == "update" then
      hue_update_resources(self, hue_events.data)

    elseif hue_event_type == "add" then
      hue_add_resources(self, hue_events.data)

    elseif hue_event_type == "delete" then
      hue_delete_resources(self, hue_events.data)

    elseif hue_event_type == "error" then
      self.log:error("[hue] received Hue error: '%s'", json.encode(event_data))

    else
      self.log:warn("[hue] received unknown Hue event, expected one of 'update', 'add', 'delete', or 'error'. Got: '%s'", hue_event_type)
    end
  end
end


-- Handles incoming events from the eventstream
local function eventstream_handler(self, msg)
  if msg.type == "event" then
    -- Hue event received
    local event_name = msg.event
    local event_id = msg.id
    local event_data, err = json.decode(msg.data)
    if not event_data then
      self.log:debug("[hue] error decoding Hue event: '%s', from data: '%s'", err, msg.data)
    else
      -- Handle Hue events
      local ok, err = pcall(event_list_handler, self, event_data, event_name, event_id)
      if not ok then
        self.log:error("[hue] failed handling event data, with '%s', for data '%s'", err, msg.data)
      end
    end

  elseif msg.type == "connect" then
    -- event stream connecivity updates
    if msg.data == "connecting" then
      self.log:debug("[hue] evenstream connection state: '%s'", msg.data)
      set_state(self, Hue.states.CONNECTING)
    elseif msg.data == "open" then
      self.log:debug("[hue] evenstream connection state: '%s'", msg.data)
      set_state(self, Hue.states.OPEN)
    elseif msg.data == "closed" then
      self.log:debug("[hue] evenstream connection state: '%s'", msg.data)
    else
      self.log:warn("[hue] received unknown 'connect' event: '%s'", msg.data)
    end

  elseif msg.type == "comment" then
    -- event stream comment received
    self.log:debug("[hue] received eventstream comment: '%s'", msg.data)

  elseif msg.type == "error" then
    -- event stream error received
    self.log:debug("[hue] received eventstream error: '%s'", msg.data)

  else
    self.log:warn("[hue] received unknown SSE-client event type: '%s'", msg.data)
  end
end


-- creates the initial device list, simulates an "add" event
local function parse_initial_resources(self, list)
  -- clean the tracking tables
  self.resources = {}
  self.types = setmetatable({},{  -- auto-table automaticaly creating subtables
    __index = function(self, key)
      self[key] = setmetatable({}, { __mode = "v" })
      return self[key]
    end,
  })

  local event_data = {{
    type = "add",
    data = list,
  }}
  event_list_handler(self, event_data)
end



--- Creates a new Hue client instance.
-- @tparam table opts options table supporting the following fields:
-- @tparam string opts.apikey The api-key to use for access (previously Hue called this 'username')
-- @tparam[opt] string opts.address IP address of the bridge, if omitted will be discovered
-- automatically (discovery will only work if there is exactly 1 bridge)
-- @tparam function opts.callback callback receiving events
-- @tparam numer|nil opts.sse_event_timout timeout (seconds idle) for reconnecting to SSE stream. Default
-- 90 seconds; Home Assistant assures events every 60 seconds)
-- @tparam[opt] logger opts.log LuaLogging compatible logger, defaults to the one on the
-- module table if omitted.
-- @return Hue client object
function Hue.new(opts)
  local self = {
    log = opts.log or Hue.log,
    apikey = assert(opts.apikey, "option 'apikey' is missing"),
    address = opts.address,
    callback = assert(type(opts.callback) == "function" and opts.callback, "expected option 'callback' to be a function"),
    sse_event_timeout = opts.sse_event_timeout or 90,
    state = Hue.states.CLOSED, -- set directly to not emnit event
  }

  return setmetatable(self, Hue)
end



--- Starts the client.
-- Collects resource data and starts listening to the event-stream for updates.
function Hue:start()
  assert(self.state == Hue.states.CLOSED, "client already started")

  self.address = self.address or assert(discover_bridge(self))
  self.base_url = "https://" .. self.address .. "/clip/v2"
  self.stream_url = "https://" .. self.address .. "/eventstream/clip/v2"

  set_state(self, Hue.states.INITIALIZING)

  self.sse_client = assert(sse.new {
    url = self.stream_url,
    headers = { ["Hue-Application-Key"] = self.apikey },
    event_timeout = self.sse_event_timeout
  })

  self.queue = self.sse_client:start()
  -- TODO: wait here for event connection to be open?

  -- get initial data
  local resources, err = get_resource_data(self)
  if not resources then
    self:stop()
    error(err)
  end

  parse_initial_resources(self, resources)

  set_state(self, Hue.states.CONNECTING)

  -- start handling event stream
  self.queue:add_worker(function(msg)
    return eventstream_handler(self, msg)
  end)

  return true
end



--- Stops the client.
-- Closes the open connections.
function Hue:stop()
  if self.sse_client then
    self.sse_client:close()
    self.sse_client = nil
  end
  self.queue = nil
  set_state(self, Hue.states.CLOSED)
  return true
end


return Hue
