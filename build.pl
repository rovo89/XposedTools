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

our $VERSION = '0.9';

my %opts;
$| = 1;

# Main routine
sub main() {
    $Getopt::Std::STANDARD_HELP_VERSION = 1;
    getopts('a:fis:t:v', \%opts) || usage(2);

    # Load the config file
    print_status("Loading config file $Bin/build.conf...", 0);
    $Xposed::cfg = Xposed::load_config("$Bin/build.conf") || exit 1;

    # Check some build requirements
    print_status('Checking requirements...', 0);
    Xposed::check_requirements() || exit 1;

    my $action = $opts{'a'} || 'build';

    # Determine build targets
    my @targets;
    if ($action eq 'build' || $action eq 'prunelogs') {
        my $target_spec = $opts{'t'} || '';
        print_status("Expanding targets from '$target_spec'...", 0);
        @targets = Xposed::expand_targets($target_spec, 1);
        if (!@targets) {
            print_error('No valid targets specified');
            usage(2);
        }
        print "\n";
    }

    if ($action eq 'build') {
        # Check whether flashing is possible
        if ($opts{'f'} && $#targets != 0) {
            print_error('Flashing is only supported for a single target!');
            exit 1;
        }

        # Build the specified targets
        foreach my $target (@targets) {
            all_in_one($target->{'platform'}, $target->{'sdk'}, !$opts{'v'}) || exit 1;
        }
    } elsif ($action eq 'prunelogs') {
        # Remove old logs
        foreach my $target (@targets) {
            prune_logs($target->{'platform'}, $target->{'sdk'});
        }
    } else {
        print_error("Unknown action specified: $action");
        usage(2);
    }

    print_status('Done!', 0);
}

# Print usage and exit
sub usage($) {
    my $exit = shift;
    print STDERR <<USAGE;

This script helps to compile and package the Xposed executables and libraries.

Usage: $0 [-v] [-i] [-f] [-a <action>][-t <targets>] [-s <steps>]
  -a   Execute <action>. The default is "build".
  -f   Flash the files after building and performs a soft reboot. Requires step "zip".
  -t   Build for targets specified in <targets>.
  -s   Limit build steps to <steps>. By default, all steps are performed.
  -i   Incremental build. Compile faster by skipping dependencies (like mm/mmm).
  -v   Verbose mode. Display the build log instead of redirecting it to a file.

Possible actions are:
  build       Builds the native executables and libraries.
  prunelogs   Removes logs which are older than 24 hours.

Format of <targets> is: <platform>:<sdk>[/<platform2>:<sdk2>/...]
  <platform> is a comma-separated list of: arm, x86, arm64 (and up to SDK 17, also armv5)
  <sdk> is a comma-separated list of integers (e.g. 21 for Android 5.0)
  Both platform and SDK accept the wildcard "all".

Values for <steps> are provided as a comma-separated list of:
  compile   Compile executables and libraries.
  collect   Collect compiled files and put them in the output directory.
  prop      Create the xposed.prop file.
  zip       Create the flashable ZIP file.


Examples:
$0 -t arm:all/x86,arm64:21
   (build ARM files for all SDKs, plus x86 and arm64 files for SDK 21)

USAGE
    exit $exit if $exit >= 0;
}

sub HELP_MESSAGE() {
    usage(-1);
}

sub VERSION_MESSAGE() {
    print "Xposed build script, version $VERSION\n";
}

# Returns whether a certain build step should be performed
sub should_perform_step($) {
    my $step = shift;
    return 1 if !$opts{'s'};
    my @steps = split(m/[, ]+/, $opts{'s'});
    foreach (@steps) {
        return 1 if $step eq $_;
    }
    return 0;
}

# Performs all build steps for one platform/SDK combination
sub all_in_one($$;$) {
    my $platform = shift;
    my $sdk = shift;
    my $silent = shift || 0;

    print_status("Processing SDK $sdk, platform $platform...", 0);

    compile($platform, $sdk, $silent) || return 0;
    if ($platform ne 'host' && $platform ne 'hostd') {
        collect($platform, $sdk) || return 0;
        create_xposed_prop($platform, $sdk, !$silent) || return 0;
        create_zip($platform, $sdk) || return 0;
    }

    print "\n\n";

    return 1;
}

# Compile Xposed (and possibly ART) for one SDK/platform
sub compile($$;$) {
    my $platform = shift;
    my $sdk = shift;
    my $silent = shift || 0;

    should_perform_step('compile') || return 1;
    print_status("Compiling...", 1);

    my @params = Xposed::get_make_parameters($platform);
    my @targets = qw(xposed);
    my @makefiles = qw(frameworks/base/cmds/xposed/Android.mk);

    # Version-specific targets
    if ($sdk < 21) {
        push @targets, qw/libxposed_dalvik/;
    } else {
        push @targets, qw/libxposed_art/;
        push @targets, qw/libart libart-compiler libart-disassembler libsigchain/;
        push @targets, qw/dex2oat oatdump patchoat/;
        push @makefiles, qw(art/Android.mk);
    }

    if ($platform eq 'host') {
        $ENV{'ART_BUILD_HOST_NDEBUG'} = 'true';
        @targets = qw(
            out/host/linux-x86/bin/dex2oat
            out/host/linux-x86/bin/oatdump
        );
        @makefiles = qw(art/Android.mk);
    } elsif ($platform eq 'hostd') {
        $ENV{'ART_BUILD_HOST_DEBUG'} = 'true';
        @targets = qw(
            out/host/linux-x86/bin/dex2oatd
            out/host/linux-x86/bin/oatdumpd
        );
        @makefiles = qw(art/Android.mk);
    }

    my $result = Xposed::compile($platform, $sdk, \@params, \@targets, \@makefiles, $opts{'i'}, $silent);

    delete($ENV{'ART_BUILD_HOST_NDEBUG'});
    delete($ENV{'ART_BUILD_HOST_DEBUG'});

    return $result;
}

# Collect final files into a single directory
sub collect($$) {
    my $platform = shift;
    my $sdk = shift;

    should_perform_step('collect') || return 1;
    print_status("Collecting compiled files...", 1);

    my $coldir = Xposed::get_collection_dir($platform, $sdk);
    make_path($coldir);
    my $rootdir = Xposed::get_rootdir($sdk) || return 0;
    my $outdir = Xposed::get_outdir($platform) || return 0;

    # Clear collection directory
    remove_tree($coldir . '/files');
    return 0 if -e $coldir . '/files';

    # Copy files
    my $files = get_compiled_files($platform, $sdk);
    while( my ($file, $target) = each(%$files)) {
        $file = $rootdir . '/' . $outdir . $file;
        $target = $coldir . '/files' . $target;
        print "$file => $target\n";
        make_path(dirname($target));
        if (!copy($file, $target)) {
            print_error("Copy failed: $!");
            return 0;
        }
    }

    return 1;
}

# Returns a hash paths of compiled files
sub get_compiled_files($$) {
    my $platform = shift;
    my $sdk = shift;

    my %files;
    tie(%files, 'Tie::IxHash');

    if ($sdk < 21) {
        $files{'/system/bin/app_process_xposed'} = '/system/bin/app_process_xposed';
        $files{$_} = $_ foreach qw(
            /system/lib/libxposed_dalvik.so
        );
    } else {
        $files{$_} = $_ foreach qw(
            /system/bin/app_process32_xposed
            /system/lib/libxposed_art.so

            /system/lib/libart.so
            /system/lib/libart-compiler.so
            /system/lib/libart-disassembler.so
            /system/lib/libsigchain.so

            /system/bin/dex2oat
            /system/bin/oatdump
            /system/bin/patchoat
        );
    }

    if ($platform eq 'arm64') {
        # libart-disassembler is required by oatdump only, which is a 64-bit executable
        delete $files{'/system/lib/libart-disassembler.so'};

        $files{$_} = $_ foreach qw(
            /system/bin/app_process64_xposed
            /system/lib64/libxposed_art.so

            /system/lib64/libart.so
            /system/lib64/libart-disassembler.so
            /system/lib64/libsigchain.so
        );
    }

    return \%files;
}

# Creates the /system/xposed.prop file
sub create_xposed_prop($$;$) {
    my $platform = shift;
    my $sdk = shift;
    my $print = shift || 0;

    should_perform_step('prop') || return 1;
    print_status("Creating xposed.prop file...", 1);

    # Open the file
    my $coldir = Xposed::get_collection_dir($platform, $sdk);
    my $propfile = $coldir . '/files/system/xposed.prop';
    print "$propfile\n";
    make_path(dirname($propfile));
    if (!open(PROPFILE, '>', $propfile)) {
        print_error("Could not write to $propfile: $!");
        return 0;
    }

    # Prepare variables
    my $version = $Xposed::cfg->val('Build', 'version');
    $version = sprintf($version, strftime('%Y%m%d', localtime())) if $version =~ m/%s/;
    if ($platform eq 'armv5') {
        $platform = 'arm';
    }

    # Calculate minimum / maximum compatible SDK versions
    my $minsdk = $sdk;
    my $maxsdk = $sdk;

    if ($sdk >= 15 && $sdk <= 19) {
        $minsdk = 15;
        $maxsdk = 19;
    }

    # Write to file
    my $content = <<EOF;
version=$version
arch=$platform
minsdk=$minsdk
maxsdk=$maxsdk
EOF

    print PROPFILE $content;
    print $content if $print;

    # Close the file
    close(PROPFILE);

    return 1;
}

# Create a flashable ZIP file with the compiled and some static files
sub create_zip($$) {
    my $platform = shift;
    my $sdk = shift;

    should_perform_step('zip') || return 1;
    print_status("Creating flashable ZIP file...", 1);

    # Create a new ZIP file
    my $zip = Archive::Zip->new();
    my $outdir = $Xposed::cfg->val('General', 'outdir');
    my $coldir = Xposed::get_collection_dir($platform, $sdk);
    make_path($coldir);
    $zip->addTree($coldir . '/files/', '') == AZ_OK || return 0;
    $zip->addDirectory('system/framework/') || return 0;
    $zip->addFile("$outdir/java/XposedBridge.jar", 'system/framework/XposedBridge.jar') || return 0;
    # TODO: We probably need different files for older releases
    $zip->addTree($Bin . '/zipstatic/_all/', '') == AZ_OK || return 0;
    $zip->addTree($Bin . '/zipstatic/' . $platform . '/', '') == AZ_OK || return 0;

    # Set last modification time to "now"
    my $now = time();
    foreach my $member($zip->members()) {
        $member->setLastModFileDateTimeFromUnix($now);
    }

    # Write the ZIP file to disk
    $Xposed::cfg->val('Build', 'version') =~ m/^(\d+)(.*)/;
    my ($version, $suffix) = ($1, $2);
    if ($suffix) {
        $suffix = sprintf($suffix, strftime('%Y%m%d', localtime()));
        $suffix =~ s/[\s\/|*"?<:>%()]+/-/g;
        $suffix =~ s/-{2,}/-/g;
        $suffix =~ s/^-|-$//g;
        $suffix = '-' . $suffix if $suffix;
    }
    my $zipname = sprintf('%s/xposed-v%d-sdk%d-%s%s.zip', $coldir, $version, $sdk, $platform, $suffix);
    print "$zipname\n";
    $zip->writeToFileNamed($zipname) == AZ_OK || return 0;

    Xposed::sign_zip($zipname);

    # Flash the file (if requested)
    if ($opts{'f'}) {
        print_status("Flashing ZIP file...", 1);
        system("adb push $zipname /data/local/tmp/xposed.zip") == 0 || return 0;
        system("adb push $Bin/zipstatic/$platform/META-INF/com/google/android/update-binary /data/local/tmp/update-binary") == 0 || return 0;
        system("adb shell 'chmod 700 /data/local/tmp/update-binary'") == 0  || return 0;
        system("adb shell su -c 'NO_UIPRINT=1 /data/local/tmp/update-binary 2 1 /data/local/tmp/xposed.zip'") == 0  || return 0;
        system("adb shell 'rm /data/local/tmp/update-binary /data/local/tmp/xposed.zip'") == 0 || return 0;
        system("adb shell su -c 'stop; sleep 2; start'") == 0 || return 0;
    }

    return 1;
}

# Remove old logs
sub prune_logs($$) {
    my $platform = shift;
    my $sdk = shift;
    my $cutoff = shift || (time() - 86400);

    my $logdir = Xposed::get_collection_dir($platform, $sdk) . '/logs';
    return if !-d $logdir;

    print_status("Cleaning $logdir...", 1);

    opendir(DIR, $logdir) || return;
    foreach my $file (sort readdir(DIR)) {
        next if ($file !~ m/\.log$/);
        my $filepath = $logdir . '/' . $file;
        my $modtime = (stat($filepath))[9];
        if ($modtime < $cutoff) {
            print "[REMOVE]  $file\n";
            unlink($filepath);
        } else {
            print "[KEEP]    $file\n";
        }
    }
    closedir(DIR);

    print "\n";
}

main();
