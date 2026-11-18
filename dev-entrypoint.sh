#!/bin/sh
# exec replaces this shell process so dotnet receives signals directly, not the shell.
exec dotnet watch --project ./RPA.CPH.NonSubsidy.Web run --urls "http://*:${PORT}"
