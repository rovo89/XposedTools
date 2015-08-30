#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin;

use Xposed;

use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use Data::Dumper;
use File::Basename;
use File::Copy;
use File::Path qw(make_path remove_tree);
use Getopt::Std;
use POSIX qw(strftime);
use Tie::IxHash;
use Term::ANSIColor;

our $VERSION = '1.0';

my %opts;
$| = 1;

# Main routine
sub main() {
    $Getopt::Std::STANDARD_HELP_VERSION = 1;
    getopts('') || exit 2;

    # Load the config file
    print_status("Loading config file $Bin/build.conf...", 0);
    $Xposed::cfg = Xposed::load_config("$Bin/build.conf") || exit 1;

    # Check some build requirements
    print_status('Checking requirements...', 0);
    Xposed::check_requirements() || exit 1;

    print_status('Creating ZIP archives...', 0);
    foreach my $platform ('arm', 'x86', 'arm64', 'armv5') {
        create_zip($platform) if -d "$Bin/zipstatic/$platform" || exit 1;
    }

    print_status('Done!', 0);
}

sub create_zip() {
    my $platform = shift;

    # Create a new ZIP file
    my $zip = Archive::Zip->new();
    $zip->addTree($Bin . '/zipstatic/_uninstaller/', '') == AZ_OK || return 0;
    $zip->addTree($Bin . '/zipstatic/' . $platform . '/', '') == AZ_OK || return 0;

    # Set last modification time to "now"
    my $now = time();
    foreach my $member($zip->members()) {
        $member->setLastModFileDateTimeFromUnix($now);
    }

    # Write the ZIP file to disk
    my $outdir = $Xposed::cfg->val('General', 'outdir');
    my $zipname = sprintf('%s/uninstaller/xposed-uninstaller-%s-%s.zip', $outdir, strftime('%Y%m%d', localtime()), $platform);
    make_path(dirname($zipname));

    print "$zipname\n";
    $zip->writeToFileNamed($zipname) == AZ_OK || return 0;

    Xposed::sign_zip($zipname);

    return 1;
}

sub HELP_MESSAGE() {
}

sub VERSION_MESSAGE() {
    print "Xposed uninstaller creation script, version $VERSION\n";
}

main();
