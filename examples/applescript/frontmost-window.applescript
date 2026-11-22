-- Frontmost app and its front window title (needs Accessibility + Automation for System Events).
-- bridgectl as -f examples/applescript/frontmost-window.applescript
tell application "System Events"
	set p to first application process whose frontmost is true
	set appName to name of p
	try
		set winName to name of front window of p
	on error
		set winName to "(no window)"
	end try
	return appName & " | " & winName
end tell
