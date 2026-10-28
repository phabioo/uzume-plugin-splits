-- Entry module of the Splits plugin.
local App = require("controller")

uz.log.info(uz.i18n.t("loaded", { version = (uz.plugin and uz.plugin.version) or "?" }))
App.new(uz):start()
