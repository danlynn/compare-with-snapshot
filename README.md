# compare-with-snapshot

## About

compare-with-snapshot is a KDE service menu which adds a 'Compare with Snapshot'
item to the context menu in the Dolphin file manager when right-clicking on a
file.  This requires you to be running the KDE desktop environment, using btrfs
as your file system, and have the snapper package installed.  You must also have
configured snapper to manage snapshots for the btrfs subvolume containing the
file that you right-clicked upon.

## Usage

Selecting 'Compare with Snapshot' will pop up a window showing all the snapshots
where the contents of that file actually changed.  Selecting one of those 
snapshots will pop open the RubyMine diff utility showing the changes for the
selected file between the time of the selected snapshot and its current state.

## Installation

Eventually, I'll add an installation script.