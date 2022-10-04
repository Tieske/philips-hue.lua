local package_name = "philips-hue"
local package_version = "scm"
local rockspec_revision = "1"
local github_account_name = "Tieske"
local github_repo_name = "philips-hue.lua"


package = package_name
version = package_version.."-"..rockspec_revision

source = {
  url = "git+https://github.com/"..github_account_name.."/"..github_repo_name..".git",
  branch = (package_version == "scm") and "main" or nil,
  tag = (package_version ~= "scm") and package_version or nil,
}

description = {
  summary = "Lua module to interact with Philips Hue devices, based on the Copas scheduler.",
  detailed = [[
    Lua module to interact with Philips Hue devices, based on the Copas scheduler.
    This module will connect and stream events to enable real-time updates.
  ]],
  license = "MIT",
  homepage = "https://github.com/"..github_account_name.."/"..github_repo_name,
}

dependencies = {
  "lua >= 5.1, < 5.5",
  "copas >= 4.2, < 5",
  "luasec",
  "lua-cjson",
  "copas-sse",
}

build = {
  type = "builtin",

  modules = {
    ["philips-hue.init"] = "src/philips-hue/init.lua",
    ["philips-hue.log"] = "src/philips-hue/log.lua",
  },

  copy_directories = {
    "docs",
  },
}
