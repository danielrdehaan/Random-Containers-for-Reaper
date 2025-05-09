# ReaPack Repository Template

A template for GitHub-hosted ReaPack repositories with automated
[reapack-index](https://github.com/cfillion/reapack-index)
running from GitHub Actions.

Replace the name of the repository in [index.xml](/index.xml) when using this template.
This will be the name shown in ReaPack.

```xml
<index version="1" name="Name of your repository here">
```

Replace the contents of this file ([README.md](/README.md)).
This will be the text shown when using ReaPack's "About this repository" feature.

reapack-index looks for package files in subfolders.
The folder tree represents the package categories shown in ReaPack.

Each package file is expected to begin with a metadata header.
See [Packaging Documentation](https://github.com/cfillion/reapack-index/wiki/Packaging-Documentation) on reapack-index's wiki.



The URL to import in ReaPack is [https://github.com/danielrdehaan/Random-Containers-for-Reaper/raw/master/index.xml](https://github.com/danielrdehaan/Random-Containers-for-Reaper/raw/master/index.xml)


# Requirements:
This REAPER script requires:
 - REAPER 7.20+ (could work with older versions but has not been tested)
 - ReaPack
 - SWS/S&M REAPER extension
 - ReaImGUI
 

# Basic Installation:
 - Install script through ReaPack.
 - Repository Link: [https://github.com/danielrdehaan/Random-Containers-for-Reaper/raw/master/index.xml](https://github.com/danielrdehaan/Random-Containers-for-Reaper/raw/master/index.xml)

--

# Full Installation Instructions:

## Install ReaPack:
1. Download and install ReaPack from [https://reapack.com](https://reapack.com). 
2. Restart REAPER after installing ReaPack.

Note: Users of macOS Catalina or newer may need to click on "Allow Anyway" in System Preferences > Security & Privacy after launching REAPER once for ReaPack to load when installed for the first time. Restart REAPER after approving.

3. Open ReaPack from the menu bar Extensions > ReaPack > Browse Packages... and install the following extensions:
  - SWS/S&M extensions
  - ReaImGui: ReaScript binding for Dear ImGui
4. Restart Reaper
5. Import a new repository via ReaPack by choose from the menu bar Extensions > ReaPack > Import Repositories...
6. Paste the following repository link in the resulting pop-up window and click "OK"
    https://github.com/danielrdehaan/Random-Containers-for-Reaper/raw/master/index.xml
7. Browse for the newly imported repository via ReaPack by choosing from the menu bar Extensions > ReaPack > Browse Packages...
8. Search for and install the "Simple Sound Tools - Random Containers for Reaper" package.

# Running Random Containers for Reaper

1. Open REAPER's Action List and search for the action "Script: Simple-Sound-Tools_Random-Containers.lua"
2. Assign a keyboard shortcut if desired.

