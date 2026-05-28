--!strict
-- Server bootstrap: loads every service under src/server/Services and starts Knit.
-- Services self-register by calling Knit.CreateService in their module bodies.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

Knit.AddServices(script.Services)

Knit.Start()
	:andThen(function()
		print("[Knit] Server started — Marvin's Dense Forest online.")
	end)
	:catch(function(err)
		warn("[Knit] Server failed to start:", err)
	end)
