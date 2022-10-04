#!/usr/bin/env lua

package.path = "./src/?/init.lua;./src/?.lua;./?/init.lua;"..package.path

require "logging"

local Hue = require "philips-hue"
local copas = require "copas"
local Timer = require "copas.timer"

local hue = Hue.new {
  apikey = os.getenv("HUE_KEY"),
  address = os.getenv("HUE_IP"),
  callback = function(hue, event_data)
    if event_data.type == "status" then
      -- Hue client status changed
      print("------------------ Hue client status is now: ", event_data.event)

    elseif event_data.type == "hue" then
      -- resources changed/added/deleted
      if event_data.event == "update" then
        print("Changes received for resource "..event_data.current.id..": ", require("pl.pretty").write(event_data.received))
      end

    else
      -- this should not happen
      print("Received an unknown event type, expected either 'hue' or 'status', got: "..tostring(event_data.type))
    end
  end,
}

copas(function()
  hue:start()  -- start the Hue client

  Timer.new {  -- exit after 5 minutes
    delay = 5 * 60,
    callback = function() hue:stop() end
  }
end)
