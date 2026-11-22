-- List the names of all visible applications (needs Automation permission for System Events).
-- bridgectl as -f examples/applescript/visible-apps.applescript
tell application "System Events"
	set AppleScript's text item delimiters to linefeed
	return (name of every application process whose visible is true) as text
end tell
