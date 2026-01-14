#!/usr/bin/env -S PERL5LIB= /usr/bin/perl
use strict;
use warnings;
use File::Path qw(make_path remove_tree);
use Cwd;
use File::Basename;
use JSON;
use File::Slurp;
use FindBin;
use POSIX qw(strftime);
use File::Spec;
use File::Spec::Functions qw(catfile catdir);
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use File::Copy qw(copy);

# Convert Unix-style to Windows-style path for msiexec
sub to_windows_path {
    my ($path) = @_;
    # If your path is Unix style and starts with /c/, convert it to C:\ etc.
    if ($path =~ m{^/([a-zA-Z])(/|$)}) {
        $path =~ s{^/([a-zA-Z])}{\U$1:};
    }
    $path =~ s{/}{\\}g;  # replace forward slash with backslash
    return $path;
}

# Path to config.json in the same directory as the script
my $config_path = File::Spec->catfile($FindBin::Bin, "config.json");

# Read the JSON file
my $config_json = read_file($config_path)
    or die "Cannot read $config_path: $!";

# Decode the JSON
my $config = decode_json($config_json);

my $base_version = $config->{base_version};
my $win_version_path = $config->{base_version}.$config->{secondary_version};
my $linux_version = $config->{base_version}.$config->{secondary_version}.$config->{third_version};

# Linux config
my $linux_cfg = $config->{linux};
my $build_root = $linux_cfg->{build_version_dir};
my $src_base_dir = $linux_cfg->{src_base_dir};
my $driver_rpm = $linux_cfg->{driver_rpm};
my $driver_url = $linux_cfg->{driver_url};
my $mim_tag = $config->{linux}->{mim_tag} || "v2.2.4";
my $psql_ver = $config->{linux}->{psql_ver} || "REL-17_00_0006-mimalloc";

# Windows config
my $windows_cfg = $config->{windows};
my $windows_dir = $windows_cfg->{windows_dir};
my $windows_msi_url = $windows_cfg->{windows_msi_url};

# Tools
my $MAKE = $ENV{MAKE} || "make";
my $CMAKE = "cmake";   
my $NPROC = 1;
if (`which nproc 2>/dev/null`) {
    chomp($NPROC = `nproc`);
}

# --- Helpers ---

sub run_warn {
    my ($cmd) = @_;
    print "RUN (warn): $cmd\n";
    system($cmd) == 0 or warn "Warning: command failed: $cmd\n";
}

sub run {
    my ($cmd) = @_;
    print "Running: $cmd\n";
    system($cmd) == 0 or die "Failed: $cmd\n";
}

sub safe_mkdir {
    my ($d) = @_;
    unless (-d $d) { make_path($d) or die "Failed to create $d: $!\n"; }
}

sub copy_file {
    my ($src, $dst) = @_;
    die "Missing source $src\n" unless -e $src;
    safe_mkdir(dirname($dst));
    run("cp -av '$src' '$dst'");
}

sub find_shared_lib {
    my ($prefix, $re) = @_;
    for my $d ("$prefix/lib64", "$prefix/lib") {
        next unless -d $d;
        opendir(my $dh, $d) or next;
        while (my $f = readdir($dh)) {
            if ($f =~ /$re/) {
                closedir($dh);
                return "$d/$f";
            }
        }
        closedir($dh);
    }
    return;
}

# Mimalloc-enabled Linux driver preparation
sub prepare_linux_driver_mimalloc {
    print "\n=== Preparing Linux driver WITH mimalloc ===\n";

    # ----------------------------
    # Sandbox + TOOLBOX paths
    # ----------------------------
    my $sandbox_root    = "/scratch/postgres_driver_build";
    my $src_workdir     = "$sandbox_root/src";
    my $localprefix     = "$sandbox_root/local";
    my $custom_root     = "/tc_work/nmb/TOOLBOX/lnx64/psqlODBC/17.00.0006-mimalloc";
    my $custom_lib_dir  = "$custom_root/lib";
    my $inc_dir         = "$custom_root/inc";

    # Ensure dirs exist
    safe_mkdir($_) for ($sandbox_root, $src_workdir, $localprefix, "$localprefix/lib", "$localprefix/lib64", $custom_root, $custom_lib_dir, $inc_dir);

    # ----------------------------
    # Step 0: Install Postgres system packages
    # ----------------------------
    for my $cmd (
        "sudo yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm",
        "sudo dnf -qy module disable postgresql || true",
        "sudo yum install -y postgresql${base_version} postgresql${base_version}-server postgresql${base_version}-devel --skip-broken"
    ) { run_warn($cmd); }

    # ----------------------------
    # Step 1: Extract driver RPM into sandbox
    # ----------------------------
    unless (-e $driver_rpm) { run("wget -O '$driver_rpm' '$driver_url'"); }

    my $rpm_extract_marker = "$sandbox_root/.rpm_extracted";
    unless (-e $rpm_extract_marker) {
        run("cd '$sandbox_root' && rpm2cpio '$driver_rpm' | cpio -idmv");
        open(my $mfh, ">", $rpm_extract_marker) or warn "Could not write rpm marker: $!";
        print $mfh strftime("%Y-%m-%d %H:%M:%S", localtime), "\n";
        close($mfh);
    }
    unlink $driver_rpm or warn "Could not delete $driver_rpm";

    my $extracted_lib_dir = "$sandbox_root/usr/pgsql-$base_version/lib";
    if (-d $extracted_lib_dir) {
        opendir(my $dh, $extracted_lib_dir) or die "Cannot open $extracted_lib_dir: $!";
        while (my $f = readdir($dh)) {
            next unless $f =~ /\.so$/;
            copy("$extracted_lib_dir/$f", "$localprefix/lib/$f") or warn "Copy failed $f";
        }
        closedir($dh);
        remove_tree("$sandbox_root/usr");
    } else {
        warn "RPM lib dir $extracted_lib_dir missing (ok if not in rpm)";
    }

    # ----------------------------
    # Step 2: Copy system ODBC and libpq
    # ----------------------------
    for my $f (qw(libodbc.so libodbc.so.2 libodbc.so.2.0.0 libodbcinst.so libpq.so.5 libpq.so.5.17)) {
        my $src = "/usr/lib64/$f";
        next unless -e $src;
        copy($src, "$localprefix/lib/$f") or warn "Copy failed $f";
    }

    # ----------------------------
    # Step 3: Copy headers
    # ----------------------------
    safe_mkdir("$localprefix/include");
    for my $f (qw(autotest.h odbcinst.h odbcinstext.h sql.h sqlext.h sqltypes.h sqlucode.h uodbc_extras.h uodbc_stats.h)) {
        my $src = "/usr/include/$f";
        next unless -e $src;
        copy($src, "$localprefix/include/$f") or warn "Copy header $f";
    }
    my $unixodbc_header = "/usr/include/unixODBC/unixodbc_conf.h";
    copy($unixodbc_header, "$localprefix/include/unixodbc_conf.h") if -e $unixodbc_header;

    # ----------------------------
    # Step 4: Build libtool / libltdl
    # ----------------------------
    my $libtool_ver = "2.4.6";
    my $libtool_url = "https://ftp.gnu.org/gnu/libtool/libtool-$libtool_ver.tar.gz";
    my $libtool_tgz = "$src_workdir/libtool-$libtool_ver.tar.gz";
    safe_mkdir($src_workdir);
    unless (-e $libtool_tgz) { run("wget -c -O '$libtool_tgz' '$libtool_url'"); }

    run("tar xzf '$libtool_tgz' -C '$sandbox_root'");
    chdir("$sandbox_root/libtool-$libtool_ver") or die $!;
    run("./configure --prefix='$localprefix'"); run("$MAKE -j$NPROC"); run("$MAKE install");

    # find libltdl shared lib
    my $libltdl_path = find_shared_lib($localprefix, qr/^libltdl\.so/);
    die "libltdl not found under $localprefix" unless $libltdl_path;
    print "Found libltdl: $libltdl_path\n";

    # ----------------------------
    # Step 5: Build mimalloc
    # ----------------------------
    my $mim_url = "https://github.com/microsoft/mimalloc/archive/refs/tags/$mim_tag.tar.gz";
    my $mim_tgz = "$src_workdir/mimalloc-$mim_tag.tar.gz";
    unless (-e $mim_tgz) { run("wget -c -O '$mim_tgz' '$mim_url'"); }

    run("tar xzf '$mim_tgz' -C '$sandbox_root'");
    my ($mim_dir) = glob("$sandbox_root/mimalloc-*");
    die "mimalloc dir not found" unless $mim_dir;
    chdir($mim_dir) or die $!;
    safe_mkdir("build"); chdir("build") or die $!;
    run("cmake .. -DCMAKE_INSTALL_PREFIX='$localprefix' -DCMAKE_BUILD_TYPE=Release");
    run("$MAKE -j$NPROC"); run("$MAKE install");

    # ----------------------------
    # Step 6: Build psqlODBC
    # ----------------------------
    my $psql_url = "https://github.com/postgresql-interfaces/psqlodbc/archive/refs/tags/$psql_ver.tar.gz";
    my $psql_tgz = "$src_workdir/psqlodbc-$psql_ver.tar.gz";
    unless (-e $psql_tgz) { run("wget -c -O '$psql_tgz' '$psql_url'"); }

    run("tar xzf '$psql_tgz' -C '$sandbox_root'");
    my $psql_src = glob("$sandbox_root/psqlodbc-*");
    die "psqlODBC source not found" unless $psql_src && -d $psql_src;
    chdir($psql_src) or die $!;
    run("autoreconf -fi") unless -e "configure";
    remove_tree("build") if -d "build";
    safe_mkdir("build"); chdir("build") or die $!;

    my $mim_inc = (-d "$localprefix/include/mimalloc-$mim_tag") ? "$localprefix/include/mimalloc-$mim_tag" : "$localprefix/include";
    my $ldflags = "-L$localprefix/lib -L$localprefix/lib64 -lmimalloc -lltdl -lpq";
    my $cppflags = "-I$localprefix/include -I$mim_inc -I/usr/pgsql-$base_version/include";

    run("../configure --with-mimalloc LDFLAGS='$ldflags' CPPFLAGS='$cppflags' --prefix='$localprefix'");
    run("$MAKE -j$NPROC"); run("$MAKE install");

    print "\n=== Copying OpenSSL libraries (libssl, libcrypto) ===\n";
	my @ssl_libs = qw(libssl.so.3 libcrypto.so.3);
	my @ssl_dirs = qw(/lib64 /usr/lib64 /usr/local/lib64);

	foreach my $link (@ssl_libs) {
		my $found = 0;

		print "\nLooking for $link...\n";

		foreach my $dir (@ssl_dirs) {
			my $src_link = "$dir/$link";

			print "  Checking $src_link ... ";

			if (-l $src_link) {
				print "FOUND symlink\n";

				my $real = readlink($src_link);
				my $src_real = "$dir/$real";
				my $dest_real = "$custom_lib_dir/$real";
				my $dest_link = "$custom_lib_dir/$link";

				print "  Symlink points to: $real\n";
				print "  Copying real file: $src_real -> $dest_real\n";

				my $cmd = "cp $src_real $dest_real";
				print "  Running: $cmd\n";
				system($cmd) == 0 or warn "  FAILED to copy $src_real\n";

				print "  Creating symlink: $dest_link -> $real\n";

				unlink $dest_link if -e $dest_link;
				symlink($real, $dest_link)
					or warn "  FAILED to symlink $dest_link -> $real\n";

				$found = 1;
				last;
			}
			else {
				print "not a symlink\n";
			}
		}

		warn "!! $link NOT FOUND in ANY standard directory !!\n"
			unless $found;
	}
    # ----------------------------
    # Step 7: Copy shared libs to TOOLBOX lib
    # ----------------------------
    safe_mkdir($custom_lib_dir);
    my @wanted_patterns = (
        qr/^libmimalloc.*\.so/,
        qr/^libltdl.*\.so/,
        qr/^libodbc.*\.so/,
        qr/^libodbcinst.*\.so/,
        qr/^libpsqlodbc.*\.so/,
        qr/^psqlodbca.*\.so/,
        qr/^psqlodbcw.*\.so/,
        qr/^libpq.*\.so/,
    );

    for my $d ("$localprefix/lib","$localprefix/lib64") {
        next unless -d $d;
        opendir(my $dh,$d) or next;
        while(my $f=readdir($dh)) {
            for my $pat (@wanted_patterns) {
                if($f =~ $pat) {
                    copy("$d/$f","$custom_lib_dir/$f") or warn "Copy $f failed";
                    last;
                }
            }
        }
        closedir($dh);
    }

    # ----------------------------
    # Step 7b: Ensure symlinks
    # ----------------------------
    chdir($custom_lib_dir);
    symlink("psqlodbcw.so","libpsqlodbc.so") unless -e "libpsqlodbc.so";

    my @pqfiles = glob("libpq.so*");
    my $actual = (grep {! -l $_} @pqfiles)[0] || "";
    if ($actual eq "") { warn "libpq actual file not found\n"; }
    else {
        rename $actual, "libpq.so.5.17" unless $actual eq "libpq.so.5.17";
        unlink "libpq.so.5" if -e "libpq.so.5";
        unlink "libpq.so"   if -e "libpq.so";
        symlink("libpq.so.5.17","libpq.so.5");
        symlink("libpq.so.5","libpq.so");
    }

    # ----------------------------
    # Step 8: Copy headers to TOOLBOX
    # ----------------------------
    safe_mkdir($inc_dir);
    run("cp -r $localprefix/include/* $inc_dir/ 2>/dev/null || true");
    run("cp -r /usr/pgsql-$base_version/include/* $inc_dir/ 2>/dev/null || true");

    # ----------------------------
    # Step 9: Copy configure_postgresql_driver.pl
    # ----------------------------
    opendir(my $dhv,$src_base_dir) or die "Cannot open $src_base_dir: $!";
    my @versions = grep { /^\d+\.\d+$/ && -d "$src_base_dir/$_" } readdir($dhv);
    closedir($dhv);

    @versions = sort {
        my ($am,$an) = split(/\./,$a); $an ||= 0;
        my ($bm,$bn) = split(/\./,$b); $bn ||= 0;
        $am <=> $bm || $an <=> $bn
    } @versions;

    if (@versions) {
        my $latest_version = $versions[-1];
        my $source_file = "$src_base_dir/$latest_version/configure_postgresql_driver.pl";
        my $target_file = "$custom_root/configure_postgresql_driver.pl";
        if (-e $source_file) {
            copy($source_file, $target_file) or warn "Failed to copy $source_file -> $target_file";
            open(my $in, '<', $target_file) or die "Cannot open $target_file: $!";
            my @lines = <$in>; close($in);
            foreach (@lines) { s/^\s*my\s+\$driver_level\s*=\s*[\d\.\'"]+\s*;/my \$driver_level = $latest_version;/; }
            open(my $out, '>', $target_file) or die "Cannot write $target_file: $!"; print $out @lines; close($out);
            print "Copied and updated configure_postgresql_driver.pl\n";
        } else { warn "configure_postgresql_driver.pl not found at $source_file\n"; }
    } else { warn "No version directories found under $src_base_dir\n"; }

    # ----------------------------
    # Done
    # ----------------------------
    print "\n✅ Linux mimalloc driver build & copy complete.\n";
    print "TOOLBOX layout:\n";
    print "  $custom_root/\n";
    print "    lib/  -> shared libs (.so)\n";
    print "    inc/  -> headers\n";
    print "    configure_postgresql_driver.pl\n";
}

# Linux driver preparation
sub prepare_linux_driver {
    print "\n=== Preparing Linux driver ===\n";

    # Install repo and packages
    my @install_cmds = (
        "sudo yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm",
        "sudo dnf -qy module disable postgresql",
        "sudo yum install -y postgresql17 postgresql17-server postgresql17-devel --skip-broken",
    );

    foreach my $cmd (@install_cmds) {
        print "Running: $cmd\n";
        system($cmd) == 0 or warn "Warning: command failed: $cmd\n";
    }

    # Create build dirs
    unless (-d $build_root) {
        print "Creating build directory: $build_root\n";
        make_path($build_root) or die "Failed to create $build_root: $!";
    }
    chdir($build_root) or die "Cannot cd to $build_root: $!";

    my $custom_lib_dir = "$build_root/lib";
    unless (-d $custom_lib_dir) {
        make_path($custom_lib_dir) or die "Failed to create $custom_lib_dir: $!";
    }

    # Download and extract RPM
    unless (-e $driver_rpm) {
        run("wget -O $driver_rpm $driver_url");
    }
    run("rpm2cpio $driver_rpm | cpio -idmv");
    unlink $driver_rpm or warn "Warning: could not delete $driver_rpm: $!";

    my $extracted_lib_dir = "$build_root/usr/pgsql-$base_version/lib";

    unless (-d $custom_lib_dir) {
        make_path($custom_lib_dir) or die "Failed to create $custom_lib_dir: $!";
    }

    if (-d $extracted_lib_dir) {
        opendir(my $dh, $extracted_lib_dir) or die "Cannot open $extracted_lib_dir: $!";
        while (my $file = readdir($dh)) {
            next unless $file =~ /\.so$/;
            my $src = "$extracted_lib_dir/$file";
            my $dest = "$custom_lib_dir/$file";
            run("cp $src $dest");
        }
        closedir($dh);
        run("rm -rf $build_root/usr");
    } else {
        die "Expected extracted directory $extracted_lib_dir not found.\n";
    }

    # Copy libodbc files
    my $base_odbc = "/usr/lib64";
	
	print "\n=== Copying OpenSSL libraries (libssl, libcrypto) ===\n";

	my @ssl_libs = qw(libssl.so.3 libcrypto.so.3);
	my @ssl_dirs = qw(/lib64 /usr/lib64 /usr/local/lib64);

	foreach my $link (@ssl_libs) {
		my $found = 0;

		print "\nLooking for $link...\n";

		foreach my $dir (@ssl_dirs) {
			my $src_link = "$dir/$link";

			print "  Checking $src_link ... ";

			if (-l $src_link) {
				print "FOUND symlink\n";

				my $real = readlink($src_link);
				my $src_real = "$dir/$real";
				my $dest_real = "$custom_lib_dir/$real";
				my $dest_link = "$custom_lib_dir/$link";

				print "  Symlink points to: $real\n";
				print "  Copying real file: $src_real -> $dest_real\n";

				my $cmd = "cp $src_real $dest_real";
				print "  Running: $cmd\n";
				system($cmd) == 0 or warn "  FAILED to copy $src_real\n";

				print "  Creating symlink: $dest_link -> $real\n";

				unlink $dest_link if -e $dest_link;
				symlink($real, $dest_link)
					or warn "  FAILED to symlink $dest_link -> $real\n";

				$found = 1;
				last;
			}
			else {
				print "not a symlink\n";
			}
		}

		warn "!! $link NOT FOUND in ANY standard directory !!\n"
			unless $found;
	}
		
	my @odbc_files = qw(libodbc.so libodbc.so.2 libodbc.so.2.0.0 libodbcinst.so);
    foreach my $file (@odbc_files) {
        my $src = "$base_odbc/$file";
        my $dest = "$custom_lib_dir/$file";
        if (-e $src) {
            my $cmd = "cp $src $dest";
            print "Running: $cmd\n";
            system($cmd) == 0 or warn "Failed to copy $src to $dest: $!";
        } else {
            warn "Source file $src does not exist\n";
        }
    }

    # Copy PostgreSQL 17 libpq shared libs and create symlink
    my $pg_lib_dir = "/usr/pgsql-17/lib";
    my @libpq_files = qw(libpq.so.5 libpq.so.5.17);

    foreach my $file (@libpq_files) {
        my $src = "$pg_lib_dir/$file";
        my $dest = "$custom_lib_dir/$file";

        if (-e $src) {
            my $cmd = "cp $src $dest";
            print "Copied $src to $dest\n";
            system($cmd) == 0 or warn "Failed to copy $src to $dest: $!";
        } else {
            warn "Source file $src does not exist\n";
        }
    }

    my $src = "$custom_lib_dir/psqlodbcw.so";
    my $dest = "$custom_lib_dir/libpsqlodbc.so";

    if (-e $src) {
        my $cmd = "cp $src $dest";
        print "Copied $src to $dest\n";
        system($cmd) == 0 or warn "Failed to copy $src to $dest: $!";
    } else {
        warn "Source file $src does not exist\n";
    }

    # Create missing symlink
    chdir $custom_lib_dir or die "Cannot cd to $custom_lib_dir: $!";
    if (! -e "libpq.so") {
        symlink("libpq.so.5", "libpq.so") or warn "Failed to create symlink libpq.so -> libpq.so.5: $!";
        print "Created symlink libpq.so -> libpq.so.5\n";
    }

    # Create inc directory and copy header files
    my $inc_dir = "$build_root/inc";
    unless (-d $inc_dir) {
        make_path($inc_dir) or die "Failed to create directory $inc_dir\n";
    }

    my @usr_include_headers = qw(
        autotest.h
        odbcinst.h
        odbcinstext.h
        sql.h
        sqlext.h
        sqltypes.h
        sqlucode.h
        uodbc_extras.h
        uodbc_stats.h
    );

    foreach my $file (@usr_include_headers) {
        my $source = "/usr/include/$file";
        my $dest = "$inc_dir/$file";
        if (-e $source) {
            system("cp", $source, $dest) == 0
                or warn "Failed to copy $file\n";
        } else {
            warn "Missing file: $source\n";
        }
    }

    my $unixodbc_header = "/usr/include/unixODBC/unixodbc_conf.h";
    if (-e $unixodbc_header) {
        system("cp", $unixodbc_header, "$inc_dir/") == 0
            or warn "Failed to copy unixodbc_conf.h\n";
    } else {
        warn "Missing file: $unixodbc_header\n";
    }

    # Copy configure_postgresql_driver.pl from toolbox latest version and patch $driver_level
    opendir(my $dh, $src_base_dir) or die "Cannot open directory $src_base_dir: $!";
    my @versions = grep { /^\d+\.\d+$/ && -d "$src_base_dir/$_" } readdir($dh);
    closedir $dh;

    @versions = sort {
        my ($a_major, $a_minor) = split(/\./, $a);
        my ($b_major, $b_minor) = split(/\./, $b);
        $a_major <=> $b_major || $a_minor <=> $b_minor;
    } @versions;

    my $latest_version = $versions[-1];
    my $source_file = "$src_base_dir/$latest_version/configure_postgresql_driver.pl";
    my $target_file = "$build_root/configure_postgresql_driver.pl";

    if (-e $source_file) {
        system("cp", $source_file, $build_root) == 0
            or die "Failed to copy $source_file to $build_root\n";
        print "Copied configure_postgresql_driver.pl from version $latest_version\n";

        open(my $in, '<', $target_file) or die "Cannot open $target_file: $!";
        my @lines = <$in>;
        close($in);

        # Update Description and driverPath lines
        foreach (@lines) {
            # Fix Description line
            s/^(\s*Description\s*=\s*).*$/\1ODBC version $linux_version-mimalloc for PostgreSQL/;

            # Fix driverPath — update the version in the path
            s|(psqlODBC/)[0-9.]+(/lib/psqlodbcw\.so)|$1$linux_version$2|;
        }

        open(my $out, '>', $target_file) or die "Cannot write to $target_file: $!";
        print $out @lines;
        close($out);

        print "Updated \$driver_level in $target_file to $latest_version\n";
    } else {
        die "File not found: $source_file\n";
    }

    print "\nLinux driver build and copy complete.\n";
}

# Windows driver preparation
sub prepare_windows_driver {
    print "\n=== Preparing Windows driver ===\n";

    # Check config vars
    die "windows_dir is not defined in config.json\n" unless $windows_dir;
    die "windows_msi_url is not defined in config.json\n" unless $windows_msi_url;

    # Create target directories
    make_path($windows_dir) unless -d $windows_dir;
    my $lib_dir = "$windows_dir/lib";
    make_path($lib_dir) unless -d $lib_dir;

    # Download MSI if missing
    my ($msi_filename) = $windows_msi_url =~ /([^\/]+)$/;
    my $msi_local = "$windows_dir/$msi_filename";

    unless (-e $msi_local) {
        run("pwsh -Command \"Invoke-WebRequest -Uri '$windows_msi_url' -OutFile '$msi_local'\"");
    } else {
        print "MSI file already exists: $msi_local\n";
    }

    # Prepare temp extraction directory
    my $temp_extract_dir = "C:\\temp\\psqlodbc_install";

    if (-d $temp_extract_dir) {
        run("rm -rf $temp_extract_dir");
    }
    make_path($temp_extract_dir);

    # Convert to Windows paths as this was originally written for linux
    my $msi_local_win = to_windows_path($msi_local);
    my $temp_extract_dir_win = to_windows_path($temp_extract_dir);

    # Run administrative install to extract MSI contents
    my $msiexec_cmd = qq{msiexec /a "$msi_local_win" /qn TARGETDIR="$temp_extract_dir_win"};
    print "Running: $msiexec_cmd\n";
    system($msiexec_cmd) == 0 or die "Failed to extract MSI using msiexec\n";

    # Define path to DLLs inside extracted MSI folder
    my $dll_dir = "$temp_extract_dir\\PFiles64\\psqlODBC\\$win_version_path\\bin";

    if (-d $dll_dir) {
        opendir(my $dh, $dll_dir) or die "Cannot open $dll_dir: $!";
        
		while (my $file = readdir($dh)) {
            next if $file =~ /^\./;
            next unless $file =~ /\.dll$/i;
            my $src = "$dll_dir\\$file";
            my $dest = "$lib_dir\\$file";
            run("copy \"$src\" \"$dest\"");
        }
    closedir($dh);
    } else {
        warn "DLL directory $dll_dir does not exist, skipping DLL copy.\n";
    }

    # Copy the README out of the docs dir
    my $readme_file = "$temp_extract_dir\\PFiles64\\psqlODBC\\$win_version_path\\docs\\README.txt";
    if (-e $readme_file) {
        print "Found README file at $readme_file\n";
        # Copy README to windows_dir
        run("copy \"$readme_file\" \"$windows_dir\"");
    } else {
        warn "README file not found at $readme_file\n";
    }

    # Create ZIP archive including MSI and README
    my $zip_file = "$windows_dir/psqlodbc_x64.zip";
    my $zip = Archive::Zip->new();

    # Add MSI file itself
    $zip->addFile($msi_local, $msi_filename);

    # Add README file
    my $readme_zip_name = 'README.txt';  # or 'README' depending on actual file
    if (-e $readme_file) {
        $zip->addFile($readme_file, $readme_zip_name);
    } else {
        warn "README file not found for zipping: $readme_file\n";
    }

    unless ($zip->writeToFileNamed($zip_file) == AZ_OK) {
        die "Failed to write ZIP file $zip_file\n";
    }
    print "Created ZIP archive $zip_file containing MSI and README\n";

    # Optionally clean up temp extraction directory
    run("rm -rf $temp_extract_dir");
	# Delete MSI and README after zipping
    my $msi_in_dir = File::Spec->catfile($windows_dir, $msi_filename);
    my $readme_in_dir = File::Spec->catfile($windows_dir, 'README.txt');

    unlink $msi_in_dir or warn "Could not delete MSI file $msi_in_dir: $!";
    unlink $readme_in_dir or warn "Could not delete README file $readme_in_dir: $!";

    print "\nThe Windows driver build and copy complete.\n";
}

sub run_download {
    my ($url, $output) = @_;
    print "Downloading $url to $output\n";
    my $ps_command = qq{powershell -Command "Invoke-WebRequest -Uri '$url' -OutFile '$output'"};
    system($ps_command) == 0 or die "Failed to download $url\n";
}

# Main routine
sub main {
if ($^O =~ /MSWin32/i) {
    print "Running Windows driver preparation\n";
    prepare_windows_driver();
} elsif ($^O =~ /linux/i) {
	#print "Running standard Linux driver preparation\n";
    #prepare_linux_driver();

    print "Running mimalloc-enabled Linux driver preparation\n";
    prepare_linux_driver_mimalloc();
} else {
    die "Unsupported platform: $^O\n";
}
}

main();
