#!/usr/bin/env lua

package.path = "./src/?/init.lua;./src/?.lua;./?/init.lua;"..package.path

require "logging"

local Hue = require "philips-hue"
local copas = require "copas"
local Timer = require "copas.timer"

local hue = Hue.new {
  apikey = os.getenv("HUE_KEY"),
  address = os.getenv("HUE_IP"),
  callback = function(hue, event)
    if event.event == "update" then
      -- print("Event received: ", require("pl.pretty").write(event.received))
    end
  end,
}

copas.loop(function()
  hue:start()

  Timer.new {  -- exit after 120 seconds
    delay = 120,
    callback = function() hue:stop() end
  }
end)

--print("title: ", require("pl.pretty").write(resources))
