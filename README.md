# Requirements:
This REAPER script requires:
 - REAPER 7.20+ (could work with older versions but has not been tested)
 - ReaPack
 - SWS/S&M REAPER extension
 - ReaImGUI
 

# Basic Installation:
 - Install script through ReaPack.
 - Repository Link: [https://github.com/danielrdehaan/Random-Containers-for-Reaper/raw/master/index.xml](https://github.com/danielrdehaan/Random-Containers-for-Reaper/raw/master/index.xml)

# Full Installation Instructions:

1. Download and install ReaPack from [https://reapack.com](https://reapack.com). 
2. Restart REAPER after installing ReaPack.

**Note: Users of macOS Catalina or newer may need to click on "Allow Anyway" in System Preferences > Security & Privacy after launching REAPER once for ReaPack to load when installed for the first time. Restart REAPER after approving.**

3. Open ReaPack from the menu bar Extensions > ReaPack > Browse Packages... and install the following extensions:
	- SWS/S&M extensions
	- ReaImGui: ReaScript binding for Dear ImGui
4. Restart Reaper
5. Import a new repository via ReaPack by choose from the menu bar Extensions > ReaPack > Import Repositories...
6. Paste the following repository link in the resulting pop-up window and click "OK"
    https://github.com/danielrdehaan/Random-Containers-for-Reaper/raw/master/index.xml
7. Browse for the newly imported repository via ReaPack by choosing from the menu bar Extensions > ReaPack > Browse Packages...
8. Search for and install the "Random Containers for Reaper" package by "Simple Sound Tools"

# Running Random Containers for Reaper

1. Open REAPER's Action List and search for the action "Script: Simple-Sound-Tools_Random-Containers.lua"
2. Assign a keyboard shortcut if desired.

# Using Random Container for Reaper

## The Window

The Random Container's window can be floated or docked to Reaper's docker. To dock the window simply drag it via it's menu bar to any of the sides of the main Reaper window.

## Enabling Randomization During Playback

The button located at the top of the Random Container window allows you to enable/disable the randomization of audio items during playback.

## Randomizing Audio Item Parameters

To randomize the parameters of an audio item simply select one or multiple audio items and...
1. Enable the type of randomization you want to apply. Then...
2. Adjust the amount and/or type of randomization you want for each parameter.

# Advanced Options

In some situation you may find that the script performs better if you set Reaper's Media Buffer Size to smaller values. This setting can be found in Reaper's Preferences > Buffering.