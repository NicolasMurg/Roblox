--!strict
-- Client bootstrap: loads every controller under src/client/Controllers and starts Knit.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

Knit.AddControllers(script.Controllers)

Knit.Start()
	:andThen(function()
		print("[Knit] Client started.")
	end)
	:catch(function(err)
		warn("[Knit] Client failed to start:", err)
	end)
