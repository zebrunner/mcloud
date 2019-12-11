Follow below steps to setup automatic services startup/shutdown for connected and disconnected devices

1. Update each plist script in LaunchAgents folder using actual path for
 - ProgramArguments
 - WorkingDirectory
 - StandardErrorPath
 - StandardOutPath

2. Copy all launch agent plist scripts into the $HOME/Library/LaunchAgents
 - com.syncAppium.plist
 - com.syncDevices.plist
 - com.syncSTF.plist
 - com.syncWDA.plist

3. Load scripts one by one:
launchctl load ~/Library/LaunchAgents/com.syncDevices.plist
launchctl load ~/Library/LaunchAgents/com.syncAppium.plist
launchctl load ~/Library/LaunchAgents/com.syncWDA.plist
launchctl load ~/Library/LaunchAgents/com.syncSTF.plist

Note: It is recommended to load in appropriate order as above

4. You can analyze each agent log using:
tail -f ./logs/agent_wda.log

