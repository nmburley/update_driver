#!/usr/bin/perl
use strict;
use warnings;
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use File::Spec;
use JSON qw(decode_json);
use File::Slurp;
use FindBin;
use POSIX qw(strftime);
use Cwd;

# ----------------------------
# CONFIG / Defaults
# ----------------------------
my $config_path = File::Spec->catfile($FindBin::Bin, "config.json");
my $config_json = read_file($config_path) or die "Cannot read $config_path: $!";
my $config = decode_json($config_json);

my $base_version    = $config->{base_version} // die "base_version missing";
my $build_root      = $config->{linux}->{build_version_dir} // die "linux.build_version_dir missing";
my $src_base_dir    = $config->{linux}->{src_base_dir} // die "linux.src_base_dir missing";
my $driver_rpm      = $config->{linux}->{driver_rpm} // die "linux.driver_rpm missing";
my $driver_url      = $config->{linux}->{driver_url} // die "linux.driver_url missing";

my $NPROC  = $config->{linux}->{nproc} || 4;
my $MAKE   = $config->{linux}->{make}  || "make";
my $mim_tag = $config->{linux}->{mim_tag} || "v2.2.4";
my $psql_ver = $config->{linux}->{psql_ver} || "REL-17_00_0006-mimalloc";

# ----------------------------
# Directories (sandboxed build + final TOOLBOX destination)
# ----------------------------
my $sandbox_root    = "/scratch/postgres_driver_build";          # everything builds/extracts here
my $src_workdir     = "$sandbox_root/src";                       # tarballs & extracted sources
my $localprefix     = "$sandbox_root/local";                     # install prefix for `make install`
my $custom_root     = "/tc_work/nmb/TOOLBOX/lnx64/psqlODBC/17.00.0006-mimalloc"; # final destination root
my $custom_lib_dir  = "$custom_root/lib";
my $inc_dir         = "$custom_root/inc";

# ensure dirs exist
sub safe_mkdir { my ($d)=@_; return if -d $d; make_path($d) or die "Failed to mkdir $d"; }
safe_mkdir($_) for ($sandbox_root, $src_workdir, $localprefix, "$localprefix/lib", "$localprefix/lib64", $custom_root, $custom_lib_dir, $inc_dir);

# ----------------------------
# Helpers
# ----------------------------
sub run { my ($c)=@_; print "RUN: $c\n"; system($c)==0 or die "Failed: $c\n"; }
sub run_warn { my ($c)=@_; print "RUN (warn): $c\n"; system($c)==0 or warn "Warn: $c\n"; }

sub find_shared_lib {
    my ($prefix,$re)=@_;
    for my $d ("$prefix/lib64","$prefix/lib") {
        next unless -d $d;
        opendir(my $dh,$d) or next;
        while(my $f=readdir($dh)) {
            if($f =~ /$re/) { closedir($dh); return "$d/$f"; }
        }
        closedir($dh);
    }
    return;
}

# ----------------------------
# Step 0: Install Postgres system packages (best-effort)
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

# move extracted .so files from sandbox to localprefix/lib
my $extracted_lib_dir = "$sandbox_root/usr/pgsql-$base_version/lib";
if (-d $extracted_lib_dir) {
    opendir(my $dh, $extracted_lib_dir) or die "Cannot open $extracted_lib_dir: $!";
    while (my $f = readdir($dh)) {
        next unless $f =~ /\.so/;
        copy("$extracted_lib_dir/$f", "$localprefix/lib/$f") or warn "Copy failed $f";
    }
    closedir($dh);
    remove_tree("$sandbox_root/usr");
} else {
    warn "RPM lib dir $extracted_lib_dir missing (ok if not provided in rpm)";
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

# ----------------------------
# Copy OpenSSL libraries (libssl, libcrypto)
# ----------------------------
for my $openssl_lib (qw(libssl.so.3 libcrypto.so.3)) {
    my $src = "/lib64/$openssl_lib";
    if (-e $src) {
        copy($src, "$custom_lib_dir/$openssl_lib") 
            or warn "Failed to copy $openssl_lib to TOOLBOX/lib";
    } else {
        warn "$openssl_lib not found on system";
    }
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

# libpsqlodbc.so -> psqlodbcw.so
symlink("psqlodbcw.so","libpsqlodbc.so") unless -e "libpsqlodbc.so";

# libpq.so -> libpq.so.5 -> libpq.so.5.17
{
    my @pqfiles = glob("libpq.so*");
    my $actual = (grep {! -l $_} @pqfiles)[0] // "";
    if ($actual eq "") { warn "libpq actual file not found\n"; }
    else {
        rename $actual, "libpq.so.5.17" unless $actual eq "libpq.so.5.17";
        unlink "libpq.so.5" if -e "libpq.so.5";
        unlink "libpq.so" if -e "libpq.so";
        symlink("libpq.so.5.17","libpq.so.5");
        symlink("libpq.so.5","libpq.so");
    }
}

# ----------------------------
# Step 8: Copy headers
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
print "\n✅ Build & copy to TOOLBOX complete.\n";
print "TOOLBOX layout:\n";
print "  $custom_root/\n";
print "    lib/  -> shared libs (.so)\n";
print "    inc/  -> headers\n";
print "    configure_postgresql_driver.pl\n";
print "\n📄 Check /etc/unixODBC/odbcinst.ini if needed.\n";
print "🚀 Run: build_and_test -pom all -postgresql\n";
