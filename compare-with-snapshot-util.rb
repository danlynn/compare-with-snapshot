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
#   2. Make this script file read/write/executable only by owner & group:
#      sudo chmod 770 ~/Documents/automation/compare-with-snapshot.rb
#   3. Change the owner of this script file:
#      sudo chown root:root ~/Documents/automation/compare-with-snapshot.rb
#   4. Create a new file named compare-with-snapshot to /etc/sudoers.d/ dir:
#      (eg: vi /etc/sudoers.d/compare-with-snapshot)
#   5. That new file should contain the following line:
#      danlynn ALL=(ALL) NOPASSWD: /home/danlynn/Documents/automation/compare-with-snapshot.rb
#      (be sure to adjust the username and file path)
#   6. Change the permissions of this new file to '-r--r----- 1 root root':
#      sudo chmod 440 /etc/sudoers.d/compare-with-snapshot
#      sudo chown root:root /etc/sudoers.d/compare-with-snapshot
#      (the permissions must be correct to work correctly)
#   7. Copy compare-with-snapshot.desktop file to ~/.local/share/kservices5/ServiceMenus/ dir
#      ...more on setting up dolphin service menu...
#      see: https://www.phind.com/search?cache=mhof1u4ajvdic8zjilxkgxir
#
# TODO: Add command-line-only support to this script.
#       This will allow use from the terminal.  Perhaps use cursor based interactive lists and selections.
#       It might be useful to have a different diff utility config'd when in cli mode.
#
#
# Files:
#   compare-with-snapshot-util      - functions that interact with snapshot dirs
#   compare-with-snapshot-util.erb  - sudo config file
#   compare-with-snapshot.desktop   - configures dolphin service menu
#   compare-with-snapshot.yml       - configures diff command
#   compare-with-snapshot           - user interface & code for service menu
#


# Get reference to the log file
#
# @return [File] log File instance to write to
def logger
  $logger_file ||= begin
    log_path = "/var/log/compare-with-snapshot-util.log"
    file = File.open(log_path, 'a+')
    at_exit do
      file.close
    end
    file
  end
end


# Find '.snapshots' dir for the btrfs subvolume that contains 'pathname'.
#
# @param [String|Pathname] file or dir of file whose .snapshots dir is to be found
# @return [Pathname, nil] Path to '.snapshots' associated with 'pathname' - else nil
# @example
#   snapshots_dir('/home/username/Documents/proj/test.md') #=> <pathname:/home/.snapshots>
def snapshots_dir(pathname)
  Pathname.new(pathname).ascend do |path|
    pathname = Pathname(pathname).realpath # convert to Pathname if String
    return path + '.snapshots' if (path + '.snapshots').directory?
  end
  nil
end

##
# Get list of available snapshots for a the file specified by 'pathname'.
# The snapshots are returned as an list of {:label, :pathname} where the :label
# value is a human readable timestamp and the :pathname value is the Pathname of
# the file in a snapshot.
#
# @param pathname [String|Pathname] path of file
# @return [Array<Hash>>] list of snapshots [{:label, :pathname}, ...]
def available_snapshots(pathname)
  pathname = Pathname(pathname).realpath # convert to Pathname if String
  return [] unless pathname.exist?
  snapshots = []
  snapshots_dir = snapshots_dir(pathname)
  raise "Snapshots are not configured for the subvolume of the current file." unless snapshots_dir
  subvol_dir = snapshots_dir.parent
  relative_pathname = pathname.relative_path_from(subvol_dir)
  logger.puts("\navailable_snapshots:")
  snapshots_dir.each_child do |snapshot|
    snapshot_pathname = snapshot + 'snapshot' + relative_pathname
    if snapshot_pathname.exist?
      snapshot_info = (snapshot + 'info.xml').read
      snapshot_time_str = snapshot_info[/(?<=<date>).*(?=<\/date>)/] + 'Z' # UTC time
      snapshot_time_in_utc = Time.strptime(snapshot_time_str, '%Y-%m-%d %H:%M:%S%z')
      snapshot_time_local = snapshot_time_in_utc.localtime
      snapshot_label = snapshot_time_local.strftime('%a %m/%d %l:%M %p')
      logger.puts("  #{snapshot_label} -> #{snapshot_pathname}")
      snapshots << {label: snapshot_label, pathname: snapshot_pathname}
    end
  end
  snapshots
end

# Get list of available snapshots for the file specified by 'pathname' where
# only snapshots where the file contents changed is retained in the list.
#
# @param pathname [String|Pathname] path of file
#
# @return [Array<Hash>] list of snapshots [{:label, :pathname}, ...]
#   of each different snapshot.
def differing_snapshots(pathname)
  pathname = Pathname(pathname).realpath # convert to Pathname if String
  avail_snapshots = available_snapshots(pathname)
  diff_snapshots = []
  last_different_pathname = pathname
  avail_snapshots.reverse_each do |avail_snapshot|
    # logger.puts("#{avail_snapshot[:label]} -> #{avail_snapshot[:pathname]}")
    # logger.puts("  comparing with: #{last_different_pathname}")
    if FileUtils.identical?(avail_snapshot[:pathname], last_different_pathname)
      # logger.puts("  [identical]")
    else
      # logger.puts("  [DIFFERENT]")
      last_different_pathname = avail_snapshot[:pathname]
      diff_snapshots << avail_snapshot
    end
  end
  logger.puts("\ndiffering_snapshots:")
  diff_snapshots.reverse_each do |diff_snapshot|
    logger.puts("  #{diff_snapshot[:label]} -> #{diff_snapshot[:pathname]}")
  end
  diff_snapshots.reverse
end

# Copy the 'snapshot_path' file out to /tmp where apps that are not running as
# root (like rubymine) can access it.
#
# @param snapshot_label [String]
# @param snapshot_path [String]
# @return [String] new temp file path
def copy_to_tempfile(snapshot_label, snapshot_path)
  dest_path = Pathname.new(Dir.tmpdir) + snapshot_label.gsub(' ', '_').gsub('/', '-') + File.basename(snapshot_path)
  logger.puts("  copy_to_tempfile:")
  logger.puts("    src:  #{snapshot_label} -> #{snapshot_path}")
  logger.puts("    dest: #{dest_path}")
  dest_path.parent.mkpath
  FileUtils.cp(snapshot_path, dest_path)
  dest_path
end

# Copy the 'snapshot_path' file out to /tmp where apps that are not running as
# root (like rubymine) can access it.
#
# @param snapshot_label [String]
# @param snapshot_path [String]
def delete_tempfile(snapshot_label, snapshot_path)
  temp_path = Pathname.new(Dir.tmpdir) + snapshot_label.gsub(' ', '_').gsub('/', '-') + File.basename(snapshot_path)
  logger.puts("  delete_tempfile:")
  logger.puts("    tempfile: #{temp_path}")
  FileUtils.rmtree(File.dirname(temp_path))
end

# Parse & sanitize args passed on the command line and invoke the appropriate action
#
# Commands:
#   compare-with-snapshot-util --differing-snapshots <local-path> --> CSV output: {"label", "path"} - else {"error": "bah!"}
#   compare-with-snapshot-util --copy-to-tempfile <snapshot-label> <snapshot-path> --> {"path"} - else {"error": "bah!"}
#   compare-with-snapshot-util --delete-tempfile <snapshot-label> <snapshot-path> --> "" - else {"error": "bah!"}
#
def main
  logger.puts("\n\n--- #{Time.now.strftime('%a %m/%d %l:%M %p')} ----------------------------------------------------------")
  logger.puts("\ncompare-with-snapshot-util #{ARGV[0]} #{ARGV[1..-1].map(&:inspect).join(' ')}")

  # compare-with-snapshot-util --differing-snapshots <local-path> --> json output: [{"label": "", "path": ""}, ...]
  if ARGV[0] == "--differing-snapshots"
    unless File.file?(ARGV[1])
      msg = "ERROR: arg 1 (local-path) is not a file or does not exist"
      logger.puts("  #{msg}")
      puts "#{{error: msg}.to_json}"
      exit 1
    end
    begin
      snapshots = differing_snapshots(ARGV[1])
      puts snapshots.to_json
      logger.puts("\n  SUCCESS")
      exit 0
    rescue => e
      logger.puts("  ERROR: #{e.message}")
      puts "#{{error: e.message}.to_json}"
      exit 1
    end
  # compare-with-snapshot-util --copy-to-tempfile <snapshot-label> <snapshot-path> --> {"path": ""}
  elsif ARGV[0] == "--copy-to-tempfile"
    unless ARGV[1] =~ /[A-Z][a-z]{2} \d\d\/\d\d (?:\d| )\d:\d\d (?:AM|PM)/
      msg = "ERROR: arg 1 (snapshot-label) is not in correct format"
      logger.puts("  #{msg}")
      puts "#{{error: msg}.to_json}"
      exit 1
    end
    unless File.file?(ARGV[2])
      msg = "ERROR: arg 2 (snapshot-path) is not a file or does not exist"
      logger.puts("  #{msg}")
      puts "#{{error: msg}.to_json}"
      exit 1
    end
    begin
      temp_pathname = copy_to_tempfile(ARGV[1], ARGV[2])
      logger.puts("  SUCCESS")
      puts "#{{path: temp_pathname}.to_json}"
      exit 0
    rescue => e
      logger.puts("  ERROR: #{e.message}")
      puts "#{{error: e.message}.to_json}"
      exit 1
    end
  # compare-with-snapshot-util --delete-tempfile <snapshot-label> <snapshot-path> --> success/fail response
  elsif ARGV[0] == "--delete-tempfile"
    unless ARGV[1] =~ /[A-Z][a-z]{2} \d\d\/\d\d (?:\d| )\d:\d\d (?:AM|PM)/
      msg = "ERROR: arg 1 (snapshot-label) is not in correct format"
      logger.puts("  #{msg}")
      puts "#{{error: msg}.to_json}"
      exit 1
    end
    unless File.file?(ARGV[2]) # makes sure that only previously created tempfiles can be deleted
      msg = "ERROR: arg 2 (snapshot-path) is not a file or does not exist"
      logger.puts("  #{msg}")
      puts "#{{error: msg}.to_json}"
      exit 1
    end
    begin
      delete_tempfile(ARGV[1], ARGV[2])
      logger.puts("  SUCCESS")
      exit 0
    rescue => e
      logger.puts("  ERROR: #{e.message}")
      puts "#{{error: e.message}.to_json}"
      exit 1
    end
  end
end


main