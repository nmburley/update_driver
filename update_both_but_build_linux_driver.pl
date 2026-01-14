#!/usr/bin/env perl
use strict;
use warnings;
use File::Path qw(make_path remove_tree);
use File::Spec::Functions qw(catfile catdir);
use Cwd qw(abs_path);
use File::Basename qw(dirname basename);
use Archive::Tar;
use POSIX qw(strftime);

# -------- CONFIG --------
my $HOME = $ENV{HOME} || die "HOME not set\n";

# Workspace and package tree
my $WORKDIR     = catdir($HOME, "build_odbc");
my $LOCALPREFIX = catdir($HOME, ".local");          
my $PACKAGE_DIR = catdir($WORKDIR, "package");      
my $LIB_DIR     = catdir($PACKAGE_DIR, "lib");      
my $INC_DIR     = catdir($PACKAGE_DIR, "inc");      
my $SRC_DIR     = catdir($WORKDIR, "src");          

# Versions / URLs
my $LIBTOOL_VER   = "2.4.6";
my $LIBTOOL_TGZ   = "https://ftp.gnu.org/gnu/libtool/libtool-$LIBTOOL_VER.tar.gz";
my $MIMALLOC_TAG  = "v2.2.4";   
my $MIMALLOC_TGZ  = "https://github.com/microsoft/mimalloc/archive/refs/tags/$MIMALLOC_TAG.tar.gz";
my $PSQLODBC_VER  = "REL-17_00_0006-mimalloc";
my $PSQLODBC_TGZ  = "https://github.com/postgresql-interfaces/psqlodbc/archive/refs/tags/$PSQLODBC_VER.tar.gz";

# Tools
my $MAKE = $ENV{MAKE} || "make";
my $CMAKE = "cmake";   
my $NPROC = 1;
if (`which nproc 2>/dev/null`) {
    chomp($NPROC = `nproc`);
}

# -------- helper subs --------
sub run {
    my ($cmd) = @_;
    print "+ $cmd\n";
    system($cmd) == 0 or die "Command failed: $cmd\n";
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

# -------- main --------
print "Starting psqlODBC $PSQLODBC_VER packaging with mimalloc\n";

safe_mkdir($WORKDIR);
safe_mkdir($SRC_DIR);
safe_mkdir($PACKAGE_DIR);
safe_mkdir($LIB_DIR);
safe_mkdir($INC_DIR);
safe_mkdir($LOCALPREFIX);

# Clean intermediate dirs
remove_tree(catdir($WORKDIR,"libtool-$LIBTOOL_VER")) if -d catdir($WORKDIR,"libtool-$LIBTOOL_VER");
remove_tree(catdir($WORKDIR,"mimalloc-$MIMALLOC_TAG")) if -d catdir($WORKDIR,"mimalloc-$MIMALLOC_TAG");
remove_tree(catdir($WORKDIR,"psqlodbc-$PSQLODBC_VER")) if -d catdir($WORKDIR,"psqlodbc-$PSQLODBC_VER");

chdir $WORKDIR or die "cd $WORKDIR: $!\n";

# 1️⃣ Build libtool/libltdl
print "\n==> Building libtool/$LIBTOOL_VER (libltdl)...\n";
my $libtool_tgz_local = catfile($SRC_DIR, "libtool-$LIBTOOL_VER.tar.gz");
unless (-e $libtool_tgz_local) {
    run("wget -c -O '$libtool_tgz_local' '$LIBTOOL_TGZ'");
}
run("tar xzf '$libtool_tgz_local' -C '$WORKDIR'");
chdir catdir($WORKDIR,"libtool-$LIBTOOL_VER") or die $!;
run("./configure --prefix='$LOCALPREFIX'");
run("$MAKE -j$NPROC");
run("$MAKE install");

# Locate libltdl
my @lib_dirs = ("$LOCALPREFIX/lib64", "$LOCALPREFIX/lib");
my $libltdl_path;
foreach my $d (@lib_dirs) {
    next unless -d $d;
    opendir my $dh, $d or next;
    while (my $f = readdir $dh) {
        if ($f =~ /^libltdl\.so(?:\.\d+)*$/) { $libltdl_path = catfile($d,$f); last; }
    }
    closedir $dh;
    last if $libltdl_path;
}
die "libltdl not found\n" unless $libltdl_path;

# 2️⃣ Build mimalloc
print "\n==> Building mimalloc $MIMALLOC_TAG ...\n";
my $mim_tgz_local = catfile($SRC_DIR, "mimalloc-$MIMALLOC_TAG.tar.gz");
unless (-e $mim_tgz_local) {
    run("wget -c -O '$mim_tgz_local' '$MIMALLOC_TGZ'");
}
run("tar xzf '$mim_tgz_local' -C '$WORKDIR'");
my ($mim_dir) = glob("$WORKDIR/mimalloc*");
chdir $mim_dir or die $!;
safe_mkdir("build");
chdir "build";
run("$CMAKE .. -DCMAKE_INSTALL_PREFIX='$LOCALPREFIX' -DCMAKE_BUILD_TYPE=Release");
run("$MAKE -j$NPROC");
run("$MAKE install");

# Locate libmimalloc
my $libm_path;
foreach my $d (@lib_dirs) {
    next unless -d $d;
    opendir my $dh, $d or next;
    while (my $f = readdir $dh) {
        if ($f =~ /^libmimalloc\.so(?:\.\d+)*$/) { $libm_path = catfile($d,$f); last; }
    }
    closedir $dh;
    last if $libm_path;
}
die "libmimalloc not found\n" unless $libm_path;

# 3️⃣ Download and extract psqlODBC
print "\n==> Downloading psqlODBC $PSQLODBC_VER ...\n";
my $psql_tgz_local = catfile($SRC_DIR, "psqlodbc-$PSQLODBC_VER.tar.gz");
unless (-e $psql_tgz_local) {
    run("wget -c -O '$psql_tgz_local' '$PSQLODBC_TGZ'");
}
run("tar xzf '$psql_tgz_local' -C '$WORKDIR'");
chdir catdir($WORKDIR,"psqlodbc-$PSQLODBC_VER") or die $!;

# autoreconf if needed
if (! -e "configure") { run("autoreconf -fi"); }

# 4️⃣ Configure psqlODBC with mimalloc & libltdl
remove_tree("build") if -d "build";
safe_mkdir("build");
chdir "build";
my $ldflags = "-L$LOCALPREFIX/lib -L$LOCALPREFIX/lib64 -lmimalloc -lltdl -lpq";
my $cppflags = "-I$LOCALPREFIX/include -I$LOCALPREFIX/include/mimalloc-2.2 -I/usr/pgsql-17/include";
my $configure_cmd = "../configure --with-mimalloc LDFLAGS='$ldflags' CPPFLAGS='$cppflags' --prefix='$LOCALPREFIX'";
run($configure_cmd);

# 5️⃣ Build and install
run("$MAKE -j$NPROC");
run("$MAKE install");

# 6️⃣ Stage built libs
my $installed_libdir = (-d catdir($LOCALPREFIX,"lib64")) ? catdir($LOCALPREFIX,"lib64") : catdir($LOCALPREFIX,"lib");
opendir my $ldh, $installed_libdir or die $!;
my @psql_libs = grep { /^libpsqlodbc/ } readdir $ldh;
closedir $ldh;
die "No built psqlodbc libs found\n" unless @psql_libs;
foreach my $f (@psql_libs) { copy_file(catfile($installed_libdir,$f), catfile($LIB_DIR,$f)); }

# Stage libmimalloc and libltdl with symlinks
copy_file($libm_path, catfile($LIB_DIR, basename($libm_path)));
chdir $LIB_DIR;
symlink(basename($libm_path), "libmimalloc.so.2") unless -e "libmimalloc.so.2";
copy_file($libltdl_path, catfile($LIB_DIR, basename($libltdl_path)));
symlink(basename($libltdl_path), "libltdl.so.7") unless -e "libltdl.so.7";
chdir $WORKDIR;

# Stage system libpq if available
my $sys_libpq;
foreach my $d ("/usr/pgsql-17/lib", "/usr/lib64") {
    next unless -d $d;
    opendir my $pdh, $d or next;
    while (my $f = readdir $pdh) { 
        if ($f =~ /^libpq\.so(?:\.\d+)*$/) { $sys_libpq = catfile($d,$f); last; }
    }
    closedir $pdh;
    last if $sys_libpq;
}
copy_file($sys_libpq, catfile($LIB_DIR, basename($sys_libpq))) if $sys_libpq;
chdir $WORKDIR;

# 7️⃣ Copy headers
my @hdrs = qw(sql.h sqlext.h sqltypes.h sqlucode.h odbcinst.h odbcinstext.h);
foreach my $h (@hdrs) {
    foreach my $d ("/usr/include", "/usr/include64", "/usr/pgsql-17/include", "$LOCALPREFIX/include") {
        if (-f catfile($d,$h)) { copy_file(catfile($d,$h), catfile($INC_DIR,$h)); last; }
    }
}
# libltdl headers
if (-d catdir($LOCALPREFIX,"include","libltdl")) { run("cp -av '".catdir($LOCALPREFIX,"include","libltdl")."' '$INC_DIR/libltdl'"); }
# mimalloc headers
my $mim_inc = catdir($LOCALPREFIX,"include");
opendir my $mdh, $mim_inc or die $!;
while (my $entry = readdir $mdh) {
    if ($entry =~ /^mimalloc/i && -d catdir($mim_inc,$entry)) {
        run("cp -av '".catdir($mim_inc,$entry)."' '$INC_DIR/'"); last;
    }
}
closedir $mdh;

# 8️⃣ Create manifest and tarball
print "\n==> Creating manifest and tarball...\n";
my $ts = strftime("%Y%m%d-%H%M%S", localtime);
my $manifest = catfile($PACKAGE_DIR, "manifest.json");
open my $mf, '>', $manifest or die $!;
print $mf "{\n";
print $mf qq{  "package_version": "$PSQLODBC_VER-mimalloc",\n};
print $mf qq{  "built_at": "$ts",\n};
print $mf qq{  "libs": [\n};
opendir my $ld, $LIB_DIR or die $!;
my @libs = grep { /\.so/ } readdir $ld;
closedir $ld;
for my $i (0..$#libs) { print $mf qq{    "$libs[$i]"} . ($i < $#libs ? ",\n" : "\n"); }
print $mf qq{  ]\n};
print $mf "}\n";
close $mf;

my $tarname = catfile($WORKDIR, "psqlodbc-${PSQLODBC_VER}-mimalloc-$ts.tar.gz");
chdir $PACKAGE_DIR or die $!;
run("tar czf '$tarname' .");
print "Created package: $tarname\n";

print "\nDone. Staged package at $PACKAGE_DIR\n";
run("ls -l '$PACKAGE_DIR'");
