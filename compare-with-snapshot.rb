#!/usr/bin/env ruby

require 'pathname'
require 'time'
require 'fileutils'
require 'tempfile'
require 'json'


# Note that this script should be setup in sudoers file to run as root so that
# it can access the contents of the .snapshots dirs.  For security reasons this
# script file should be owned by root:root and have permissions 'rwxrwx---'.
#
# Install and configure this script as follows:
#
#   1. Copy this script file to wherever you prefer to store automation scripts
#      (eg: /home/danlynn/Documents/automation/compare-with-snapshot.rb)
#   2. Change permissions on these scripts to be executable by anyone
#   2. Make this script file read/write/executable only by owner & group:
#      sudo chmod 770 ~/Documents/automation/compare-with-snapshot.rb
#   3. Change the owner of this script file:
#      sudo chown root:root ~/Documents/automation/compare-with-snapshot.rb
#   4. Create a new file named compare-with-snapshot-util to /etc/sudoers.d/ dir:
#      (eg: vi /etc/sudoers.d/compare-with-snapshot-util)
#   5. That new file should contain the following line:
#      danlynn ALL=(ALL) NOPASSWD: /home/danlynn/Documents/automation/compare-with-snapshot-util.rb
#      (be sure to adjust the username and file path)
#   6. Change the permissions of this new file to '-r--r----- 1 root root':
#      sudo chmod 440 /etc/sudoers.d/compare-with-snapshot-util
#      sudo chown root:root /etc/sudoers.d/compare-with-snapshot-util
#      (the permissions must be correct to work correctly)
#   7. Restart the machine.  You must terminate all login sessions in order to
#      pick up the new sudoers.d/ file changes.
#   8. Make sure that the ~/.local/share/kservices5/ServiceMenus/ dir exists
#   8. Copy compare-with-snapshot.desktop file to ~/.local/share/kservices5/ServiceMenus/ dir
#      ...more on setting up dolphin service menu...
#      see: https://www.phind.com/search?cache=mhof1u4ajvdic8zjilxkgxir
#
# Ideas for Dolphin service menu:
#   * Compare with snapshot
#   * Restore copy from snapshot --> copies snapshot to <filename>-<timestamp>.<ext>
#   * Compare 2 snapshots
#   * Changed files since snapshot --> display html dialog listing file links
#       see: https://www.phind.com/search?cache=cl2hn2emjpfiqiatbueogijf
#            (How to list all the files that have changed in a btrfs snapshot)
#            sudo snapper -c home status 393..394 | rg "/home/danlynn/Documents/automation/compare-with-snapshot"
#   * Choose diff utility
#   
# Dialogs are facilitated by the yad (Yet Another Dialog) utility:
#   * github: https://github.com/v1cont/yad
#   * usage: https://yad-guide.ingk.se/
#
# TODO: Add command-line-only support to this script.
#       This will allow use from the terminal.  Perhaps use cursor based interactive lists and selections.
#       It might be useful to have a different diff utility config'd when in cli mode.
#
# TODO: Add install/uninstall scripts.  Research on whether KDE store installs support
#       more sophisticated installs.  Check-out the github pages of other service menus.
#
#
# Files:
#   compare-with-snapshot-util      - functions that interact with snapshot dirs
#   compare-with-snapshot-util.erb  - sudo config file
#   compare-with-snapshot.desktop   - configures dolphin service menu
#   compare-with-snapshot.yml       - configures diff command
#   compare-with-snapshot           - user interface & code for service menu
#
#
# Commands:
#   compare-with-snapshot-util --differing-snapshots <local-path> --> CSV output: {"label", "path"}
#   compare-with-snapshot-util --copy-to-tempfile <snapshot-label> <snapshot-path> --> <tempfile-path>
#   compare-with-snapshot-util --delete-tempfile <tempfile-path> --> success/fail response
#
#   compare-with-snapshot --install
#   compare-with-snapshot --uninstall
#   compare-with-snapshot <local-path>


# Get reference to the log file
#
# @return [File] log File instance to write to
def logger
  $logger_file ||= begin
    log_dir = ENV['XDG_STATE_HOME'] || "#{Dir.home}/.local/state"
    log_path = File.join(log_dir, "compare-with-snapshot.log")
    file = File.open(log_path, 'a+')
    at_exit do
      file.close
    end
    file
  end
end


def rubymine_bin
  bin = `which rubymine`.chomp
  if bin == ""
    bin = "#{Dir.home}/.local/share/JetBrains/Toolbox/scripts/rubymine" # in case not in $PATH
    unless File.exists?(bin)
      `yad --title="Compare with Snapshot" --error --text="ERROR: Could not find rubymine command-line tool in $PATH or at #{bin}."`
      exit 1
    end
  end
  "#{bin} -Dnosplash=true" # prevent annoying splash screen from appearing and sometimes not going away
end


# Get list of available snapshots for the file specified by 'pathname' where
# only snapshots where the file contents changed is retained in the list.
#
# @param pathname [String|Pathname] path of file
# @return [Array<Hash>] list of snapshots [{:label, :pathname}, ...]
#   of each different snapshot.
def differing_snapshots(pathname)
  logger.puts("=== call --differing-snapshots")
  json_str = `sudo ./compare-with-snapshot-util.rb --differing-snapshots "#{pathname}"`
  logger.puts("=== return --differing-snapshots: exitstatus=#{$?.exitstatus}")
  unless $?.success?
    raise "ERROR: Failed to retrieve differing snapshots (exit status: #{$?.exitstatus})"
  end
  snapshots = JSON.parse(json_str, symbolize_names: true)
  snapshots.each{|snapshot| snapshot[:pathname] = Pathname(snapshot[:pathname])}
  snapshots
end


# Copy the 'snapshot_path' file out to /tmp where apps that are not running as
# root (like rubymine) can access it.
#
# @param snapshot [Hash] {:label, :pathname}
# @return [Pathname] path to new temp file
def copy_to_tempfile(snapshot)
  logger.puts("=== call --copy-to-tempfile")
  json_str = `sudo ./compare-with-snapshot-util.rb --copy-to-tempfile "#{snapshot[:label]}" "#{snapshot[:pathname]}"`.chomp
  logger.puts("=== return --copy-to-tempfile: exitstatus=#{$?.exitstatus}")
  unless $?.success?
    raise "ERROR: Failed to copy snapshot to tempfile (exit status: #{$?.exitstatus})"
  end
  Pathname.new(JSON.parse(json_str, symbolize_names: true)[:path])
end


# Copy the 'snapshot_path' file out to /tmp where apps that are not running as
# root (like rubymine) can access it.
# @param snapshot [Hash] {:label, :pathname}
def delete_tempfile(snapshot)
  logger.puts("=== call --delete-tempfile")
  `sudo ./compare-with-snapshot-util.rb --delete-tempfile "#{snapshot[:label]}" "#{snapshot[:pathname]}"`
  unless $?.success?
    raise "ERROR: Failed to copy snapshot to tempfile (exit status: #{$?.exitstatus})"
  end
end


# Copy the 'snapshot_path' file out to /tmp where apps that are not running as
# root (like rubymine) can access it.  Then delete the copied file after it has
# been displayed by the diff utility.
def invoke_diff_util(pathname, selected_snapshot)
  # TODO: ask for and store location of favorite diff utility
  logger.puts("\ninvoking diff utility to compare:")
  logger.puts("  snapshot:   #{selected_snapshot[:label]} -> #{selected_snapshot[:pathname]}")
  logger.puts("  to current: #{pathname}\n\n")
  tempfile_pathname = copy_to_tempfile(selected_snapshot)
  cmd = "#{rubymine_bin} diff '#{tempfile_pathname}' '#{pathname}'"
  logger.puts("=== cmd: #{cmd}")
  `#{cmd}`
  delete_tempfile(selected_snapshot)
end


def compare_with_snapshot(path)
  selection_data = []
  pathname = Pathname.new(path)
  diff_snapshots = differing_snapshots(pathname)
  if diff_snapshots.size == 0
    msg = "No snapshots with different contents from current"
    logger.puts("\ndiffering snapshots:")
    logger.puts("  NONE - #{msg}")
    `yad --title="Compare with Snapshot" --error --text="#{msg}"`
  else
    logger.puts("\ndiffering snapshots:")
    diff_snapshots.reverse_each do |diff_snapshot|
      logger.puts("  #{diff_snapshot[:label]} -> #{diff_snapshot[:pathname]}")
    end
    diff_snapshots.each do |diff_snapshot|
      selection_data << diff_snapshot[:pathname] # actual value
      selection_data << diff_snapshot[:label] # display value
    end
    selected_snapshot_path = `echo "#{selection_data.join("\n")}" | yad --title="Compare with Snapshot" --list --text="Select which snapshot to compare with:" --hide-column=1 --column="path" --column="snapshot" --width=350 --height=350`.chomp
    selected_snapshot_path = selected_snapshot_path[/^.*?(?=\|)/]
    logger.puts("=== selected_snapshot_path: #{selected_snapshot_path.inspect}")
    logger.puts("\nsnapshot selection:")
    if selected_snapshot_path.nil? || selected_snapshot_path == "" # selection cancelled
      logger.puts("  CANCELLED")
    else
      selected_snapshot_pathname = Pathname.new(selected_snapshot_path)
      selected_snapshot = diff_snapshots.find{|diff_snapshot| diff_snapshot[:pathname] == selected_snapshot_pathname}
      logger.puts("  #{selected_snapshot ? "#{selected_snapshot[:label]} -> #{selected_snapshot[:pathname]}" : "ERROR: selection did not match any snapshot"}")
      invoke_diff_util(pathname, selected_snapshot)
    end
  end
  exit 0
rescue => e
  logger.puts(e.message)
  `yad --title="Compare with Snapshot" --error --text="#{e.message}"`
  exit 1
end


# puts "\n#{available_snapshots(ARGV[0])}"
# puts "\n#{differing_snapshots(ARGV[0])}"
# differing_snapshots(ARGV[0])


logger.puts("\n\n--- #{Time.now.strftime('%a %m/%d %l:%M %p')} ----------------------------------------------------------")
logger.puts("\nFind snapshots to compare with file:\n  #{ARGV[0]}")
compare_with_snapshot(ARGV[0])

