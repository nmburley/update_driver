#!/usr/bin/perl
use strict;
use warnings;
use File::Path qw(make_path remove_tree);
use Cwd;

# Configurable variables
my $version     = "17.06";
my $base_dir    = "/tc_work/nmb/TOOLBOX/wntx64/psqlODBC/$version";
my $lib_dir     = "$base_dir/lib";
my $temp_dir    = "/tmp/msi_extract";
my $msi_file    = "/path/to/psqlodbc_x64.msi";  # adjust path to your MSI
my $zip_file    = "$base_dir/psqlodbc_x64.zip";

# Ensure base directories exist
make_path($lib_dir);

# Clean any old temp data
remove_tree($temp_dir, { error => \my $err });
make_path($temp_dir);

# 1. Extract MSI to temp dir using 7zip
system("7z x \"$msi_file\" -o\"$temp_dir\" > /dev/null") == 0
    or die "Failed to extract MSI\n";

# 2. Find and move bin directory contents to lib_dir
my $bin_dir = "$temp_dir/bin";
if (-d $bin_dir) {
    system("cp -p \"$bin_dir\"/* \"$lib_dir\"") == 0
        or die "Failed to copy bin files to lib\n";
} else {
    die "No bin directory found in MSI extraction\n";
}

# 3. Create zip containing MSI + README
my $docs_dir = "$temp_dir/docs";
my $readme_file = "$docs_dir/README";
if (-f $readme_file) {
    system("cp -p \"$readme_file\" \"$base_dir\"") == 0
        or die "Failed to copy README\n";
} else {
    warn "README not found in docs directory\n";
}

# Copy MSI to base dir for zipping
system("cp -p \"$msi_file\" \"$base_dir\"") == 0
    or die "Failed to copy MSI to base dir\n";

# Create the zip
my $cwd = getcwd();
chdir($base_dir) or die "Cannot chdir to $base_dir\n";
system("zip -j \"$zip_file\" \"README\" \"" . (split('/', $msi_file))[-1] . "\"") == 0
    or die "Failed to create zip file\n";
unlink("$base_dir/README");
unlink("$base_dir/" . (split('/', $msi_file))[-1]);
chdir($cwd);

# 4. Cleanup temp dir
remove_tree($temp_dir);

print "✅ Extraction complete. Files in: $lib_dir\n";
print "✅ Zip created: $zip_file\n";
