-- Entry module of the Splits plugin.
local App = require("controller")

fb.log.info(fb.i18n.t("loaded", { version = (fb.plugin and fb.plugin.version) or "?" }))
App.new(fb):start()
