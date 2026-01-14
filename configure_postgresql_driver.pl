#!/usr/bin/env perl
#
# @<COPYRIGHT>@
#=====================================================================================================
# Copyright 2018.
# Siemens Product Lifecycle Management Software Inc.
# All Rights Reserved.
#=====================================================================================================
# @<COPYRIGHT>@
#
# File description:
#    Inserts or Modifies the entry of PostgreSQL ODBC driver version into the odbcinst.ini file.
#=====================================================================================================

use warnings;
use strict;
use Getopt::Long;

my ($printHelp, $tc_root_foss_dir, $driver_lib_path);

GetOptions(
    "teamcenter_root_foss_directory=s" => \$tc_root_foss_dir,
    "driver_lib_path=s"           => \$driver_lib_path,
    "h"                           => \$printHelp,
    "help"                        => \$printHelp
);
		   
if($printHelp)
{
	showUsage();
    exit 1;
}
my $odbcinst_validate = qx{which odbcinst};
if( !$odbcinst_validate )
{
	print "unixODBC driver manager is not installed on this host.\n";
	print "Please install unixODBC driver manager version 2.3.1 or higher from: http://www.unixodbc.org/ \n";
	print "and follow the instructions mentioned at: http://www.unixodbc.org/download.html \n";
	print "and then, rerun this script.\n\n";
	print "DISCLAIMER: By downloading and installing this software you will defend, indemnify and \n";
    print "hold harmless Siemens PLM Software Inc. arising from a claim that the software infringes \n";
    print "any copyright, patent or trade secret.\n\n";
	exit 1;
}
my @odbcLocationArray = split(" ", qx{odbcinst -j});
my $odbcInstFile = $odbcLocationArray[3];

my $postgresValidation = qx {odbcinst -q -d -n PostgreSQL_TC_x64};
my $postgresqlNotThereErrorMsg = "SQLGetPrivateProfileString failed with";

if (index($postgresValidation, $postgresqlNotThereErrorMsg) != -1) 
{
	insertPostgresEntry();
} else {
	print "\nRemoving the existing entries of PostgreSQL_TC_x64...\n";
	removePostgresEntry();
	insertPostgresEntry();
}

print "\nThe odbcinst.ini file has been modified successfully with PostgreSQL entries.\n";
exit;

sub insertPostgresEntry
{
	my $driverPath;

    if ($driver_lib_path) {
        $driverPath = $driver_lib_path;
    } else {
        $tc_root_foss_dir ||= $ENV{FOSS_REPOSITORY_HOME};
        if ($tc_root_foss_dir){ 
            $driverPath = "$tc_root_foss_dir/artifacts/Teamcenter/lnx64/psqlODBC/17.06/lib/psqlodbcw.so";
        } else {
            print "The Teamcenter root FOSS directory cannot be found.\n";
            exit 1;
        }
    }
	
    open(my $fh, '>>', $odbcInstFile) or die "Could not open file '$odbcInstFile' $!";
	print $fh "\n[PostgreSQL_TC_x64]\n";
	print $fh "Description     = ODBC version 17.06 for PostgreSQL\n";
    print $fh "Driver          = $driverPath\n";
    print $fh "Driver64        = $driverPath\n";
	print $fh "FileUsage       = 1\n";
	close $fh;
}

sub removePostgresEntry
{
	my $postgresValidation = qx {odbcinst -q -d -n PostgreSQL_TC_x64};
	my @odbcLocationArray = split("\n", $postgresValidation);
	my $count = scalar (@odbcLocationArray);
	
	open(FILE, "<$odbcInstFile") or die "Could not open file '$odbcInstFile' $!";
	my @lines = <FILE>;
	close(FILE);
	my @newlines;
	my $foundPostgres = 0;
	foreach(@lines) 
	{
	   if($foundPostgres eq 1 && $count ne 0 )
	   {
			--$count;
	   }
	   elsif($_ =~ '^\[PostgreSQL_TC_x64\]')
	   {
			$foundPostgres = 1;
			--$count;
	   }
	   else
	   {
			push(@newlines,$_);
	   }
	}
	
	open(FILE, ">$odbcInstFile") or die "Could not open file '$odbcInstFile' $!";
	print FILE @newlines;
	close(FILE);
}

sub showUsage
{
	print "\n\n***DESCRIPTION***\n\n";
	print "Modifies the odbcinst.ini file with entry for PostgreSQL Database.\n";
    print "Usage:\n";
    print "  --teamcenter_root_foss_directory=<Path to TC root foss directory>\n";
    print "  --driver_lib_path=<Full path to psqlodbcw.so shared object>\n";
    print "  -h | --help for this message\n\n";
}