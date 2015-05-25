#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);

use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use Config::IniFiles;
use Data::Dumper;
use File::Basename;
use File::Copy;
use File::Path qw(make_path remove_tree);
use File::ReadBackwards;
use File::Tail;
use Getopt::Std;
use POSIX qw(strftime);
use Term::ANSIColor;
use Tie::IxHash;

our $VERSION = '0.9';

my $cfg;
my %opts;
$| = 1;

# Main routine
sub main() {
    $Getopt::Std::STANDARD_HELP_VERSION = 1;
    getopts('a:is:t:v', \%opts) || usage(2);

    # Load the config file
    print_status("Loading config file $Bin/build.conf...", 0);
    $cfg = load_config("$Bin/build.conf") || exit 1;

    # Check some build requirements
    print_status('Checking requirements...', 0);
    check_requirements() || exit 1;

    my $action = $opts{'a'} || 'build';

    # Determine build targets
    my @targets;
    if ($action eq 'build' || $action eq 'prunelogs') {
        my $target_spec = $opts{'t'} || '';
        print_status("Expanding targets from '$target_spec'...", 0);
        @targets = expand_targets($target_spec, 1);
        if (!@targets) {
            print_error('No valid targets specified');
            usage(2);
        }
        print "\n";
    }

    if ($action eq 'build') {
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

Usage: $0 [-v] [-a <action>][-t <targets>] [-s <steps>]
  -a   Execute <action>. The default is "build".
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

sub print_status($$) {
    my $text = shift;
    my $level = shift;
    my $color = ('black on_white', 'white on_blue')[$level];
    print colored($text, $color), "\n";
}

sub print_error($) {
    my $text = shift;
    print STDERR colored("ERROR: $text", 'red'), "\n";
}

# Expands the list of targets and replaces the "all" wildcard
sub expand_targets($;$) {
    my $spec = shift;
    my $print = shift || 0;

    my @result;
    my %seen;
    foreach (split(m/[\/ ]+/, $spec)) {
        my ($pfspec, $sdkspec) = split(m/[: ]+/, $_, 2);
        my @pflist = ($pfspec ne 'all') ? split(m/[, ]/, $pfspec) : ('arm', 'x86', 'arm64', 'armv5');
        my @sdklist = ($sdkspec ne 'all') ? split(m/[, ]/, $sdkspec) : $cfg->Parameters('AospDir');
        foreach my $sdk (@sdklist) {
            foreach my $pf (@pflist) {
                next if !check_target_sdk_platform($pf, $sdk, $pfspec eq 'all' || $sdkspec eq 'all');
                next if $seen{"$pf/$sdk"}++;
                push @result, { platform => $pf, sdk => $sdk };
                print "  SDK $sdk, platform $pf\n" if $print;
            }
        }
    }
    return @result;
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

# Load and return a config file in .ini format
sub load_config($) {
    my $cfgname = shift;

    # Make sure that the file is readable
    if (!-r $cfgname) {
        print_error("$cfgname doesn't exist or isn't readable");
        return undef;
    }

    # Load the file
    $cfg = Config::IniFiles->new( -file => $cfgname, -handle_trailing_comment => 1);
    if (!$cfg) {
        print_error("Could not read $cfgname:");
        print STDERR "   $_\n" foreach (@Config::IniFiles::errors);
        return undef;
    }

    # Trim trailing spaces of each value
    foreach my $section ($cfg->Sections()) {
        foreach my $key ($cfg->Parameters($section)) {
            my $value = $cfg->val($section, $key);
            if ($value =~ s/\s+$//) {
                $cfg->setval($section, $key, $value);
            }
        }
    }

    return $cfg;
}

# Makes sure that some important exist
sub check_requirements() {
    my $outdir = $cfg->val('General', 'outdir');
    if (!-d $outdir) {
        print_error('[General][outdir] must point to a directory');
        return 0;
    }
    my $jar = "$outdir/java/XposedBridge.jar";
    if (!-r $jar) {
        print_error("$jar doesn't exist or isn't readable");
        return 0;
    }
    return 1;
}

# Performs all build steps for one platform/SDK combination
sub all_in_one($$;$) {
    my $platform = shift;
    my $sdk = shift;
    my $silent = shift || 0;

    print_status("Processing SDK $sdk, platform $platform...", 0);

    compile($platform, $sdk, $silent) || return 0;
    collect($platform, $sdk) || return 0;
    create_xposed_prop($platform, $sdk, !$silent) || return 0;
    create_zip($platform, $sdk) || return 0;

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

    # Initialize some general build parameters
    my $rootdir = get_rootdir($sdk) || return 0;
    my $outdir = get_outdir($platform) || return 0;
    my $lunch_mode = get_lunch_mode($platform, $sdk) || return 0;
    my @targets = qw(xposed);
    my @makefiles = qw(frameworks/base/cmds/xposed/Android.mk);
    my @params = split(m/\s+/, $cfg->val('Build', 'makeflags', '-j4'));

    # ARMv5 build need some special parameters
    if ($platform eq 'armv5') {
        push @params, 'OUT_DIR=out_armv5';
        push @params, 'TARGET_ARCH_VARIANT=armv5te';
        push @params, 'ARCH_ARM_HAVE_TLS_REGISTER=false';
        push @params, 'TARGET_CPU_SMP=false';
    } else {
        push @params, 'TARGET_CPU_SMP=true';
    }

    # Version-specific targets
    if ($sdk < 21) {
        push @targets, qw/libxposed_dalvik/;
    } else {
        push @targets, qw/libxposed_art/;
        push @targets, qw/libart libart-compiler libart-disassembler libsigchain/;
        push @targets, qw/dex2oat oatdump patchoat/;
        push @makefiles, qw(art/Android.mk);
    }

    # Build the command string
    my $cdcmd = 'cd ' . $rootdir;
    my $envsetupcmd = '. build/envsetup.sh >/dev/null';
    my $lunchcmd = 'lunch ' . $lunch_mode . ' >/dev/null';
    my $makecmd = $opts{'i'} ? "ONE_SHOT_MAKEFILE='" . join(' ', @makefiles) . "' make -C $rootdir -f build/core/main.mk " : 'make ';
    $makecmd .= join(' ', @params, @targets);
    my $cmd = join(' && ', $cdcmd, $envsetupcmd, $lunchcmd, $makecmd);
    print colored('Executing: ', 'magenta'), $cmd, "\n";

    my ($logfile, $tailpid);
    if ($silent) {
        my $logdir = get_collection_dir($platform, $sdk) . '/logs';
        make_path($logdir);
        $logfile = sprintf('%s/build_%s.log', $logdir, timestamp());
        print colored('Log: ', 'magenta'), $logfile, "\n";
        $cmd = "{ $cmd ;} &> $logfile";
        $tailpid = start_tail_process($logfile);
    }

    # Execute the command
    my $rc = system("bash -c \"$cmd\"");

    # Stop progress indicator process
    if ($tailpid) {
        kill('TERM', $tailpid);
        waitpid($tailpid, 0);
    }

    # Return the result
    if ($rc == 0) {
        print colored('Build was successful!', 'green'), "\n\n";
        return 1;
    } else {
        print colored('Build failed!', 'red'), "\n";
        if ($silent) {
            print "Last 10 lines from the log:\n";
            my $tail = File::ReadBackwards->new($logfile);
            my @lines;
            for (1..10) {
                last if $tail->eof();
                unshift @lines, $tail->readline();
            }
            print "   $_" foreach (@lines);
        }
        print "\n";
        return 0;
    }
}

# Start a separate process to display the last line of the log
sub start_tail_process($) {
    my $logfile = shift;

    my $longest = 0;
    local $SIG{'TERM'} = sub {
        print "\r", ' ' x $longest, color('reset'), "\n" if $longest;
        exit 0;
    };

    my $pid = fork();
    return $pid if ($pid > 0);

    my $file = File::Tail->new(name => $logfile, ignore_nonexistant => 1, interval => 5, tail => 1);
    while (defined(my $line = $file->read())) {
        $line = substr($line, 0, 80);
        $line =~ s/\s+$//;
        my $len = length($line);
        if ($len < $longest) {
            $line .= ' ' x ($longest - $len);
        } else {
            $longest = $len;
        }
        print "\r", colored($line, 'yellow');
    }
    exit 0;
}

sub timestamp() {
    return strftime('%Y%m%d_%H%M%S', localtime());
}

# Collect final files into a single directory
sub collect($$) {
    my $platform = shift;
    my $sdk = shift;

    should_perform_step('collect') || return 1;
    print_status("Collecting compiled files...", 1);

    my $coldir = get_collection_dir($platform, $sdk);
    make_path($coldir);
    my $rootdir = get_rootdir($sdk) || return 0;
    my $outdir = get_outdir($platform) || return 0;

    # Clear collection directory
    remove_tree($coldir . '/files');

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
    my $coldir = get_collection_dir($platform, $sdk);
    my $propfile = $coldir . '/files/system/xposed.prop';
    print "$propfile\n";
    make_path(dirname($propfile));
    if (!open(PROPFILE, '>', $propfile)) {
        print_error("Could not write to $propfile: $!");
        return 0;
    }

    # Prepare variables
    my $version = sprintf($cfg->val('Build', 'version', 'Custom build (%s)'), strftime('%Y%m%d', localtime()));
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
    my $outdir = $cfg->val('General', 'outdir');
    my $coldir = get_collection_dir($platform, $sdk);
    make_path($coldir);
    $zip->addTree($coldir . '/files', '') == AZ_OK || return 0;
    $zip->addDirectory('system/framework/') || return 0;
    $zip->addFile("$outdir/java/XposedBridge.jar", 'system/framework/XposedBridge.jar') || return 0;
    # TODO: We probably need different files for older releases
    $zip->addTree($Bin . '/zipstatic/_all', '') == AZ_OK || return 0;
    $zip->addTree($Bin . '/zipstatic/' . $platform, '') == AZ_OK || return 0;

    # Set last modification time to "now"
    my $now = time();
    foreach my $member($zip->members()) {
        $member->setLastModFileDateTimeFromUnix($now);
    }

    # Write the ZIP file to disk
    my $zipname = sprintf('%s/xposed-sdk%d-%s.zip', $coldir, $sdk, $platform);
    print "$zipname\n";
    $zip->writeToFileNamed($zipname) == AZ_OK || return 0;

    # TODO: Sign the resulting zip without breaking some "unzip" in some recoveries

    return 1;
}

# Check target SDK version and platform
sub check_target_sdk_platform($$;$) {
    my $platform = shift;
    my $sdk = shift;
    my $wildcard = shift || 0;

    if ($sdk < 15 || $sdk == 20 || $sdk > 21) {
        print_error("Unsupported SDK version $sdk");
        return 0;
    }

    if ($platform eq 'armv5') {
        if ($sdk > 17) {
            print_error('ARMv5 builds are only supported up to Android 4.2 (SDK 17)') unless $wildcard;
            return 0;
        }
    } elsif ($platform eq 'arm64') {
        if ($sdk < 21) {
            print_error('arm64 builds are not supported prior to Android 5.0 (SDK 21)') unless $wildcard;
            return 0;
        }
    } elsif ($platform ne 'arm' && $platform ne 'x86') {
        print_error("Unsupported target platform $platform");
        return 0;
    }

    return 1;
}

# Returns the root of the AOSP tree for the specified SDK
sub get_rootdir($) {
    my $sdk = shift;

    my $dir = $cfg->val('AospDir', $sdk);
    if (!$dir) {
        print_error("No root directory has been configured for SDK $sdk");
        return undef;
    } elsif ($dir !~ m/^/) {
        print_error("Root directory $dir must be an absolute path");
        return undef;
    } elsif (!-d $dir) {
        print_error("$dir is not a directory");
        return undef;
    } else {
        # Trim trailing slashes
        $dir =~ s|/+$||;
        return $dir;
    }
}

# Determines the root directory where compiled files are put
sub get_outdir($) {
    my $platform = shift;

    if ($platform eq 'arm') {
        return 'out/target/product/generic';
    } elsif ($platform eq 'armv5') {
        return 'out_armv5/target/product/generic';
    } elsif ($platform eq 'x86' || $platform eq 'arm64') {
        return 'out/target/product/generic_' . $platform;
    } else {
        print_error("Could not determine output directory for $platform");
        return undef;
    }
}

# Determines the directory where compiled files etc. are collected
sub get_collection_dir($$) {
    my $platform = shift;
    my $sdk = shift;
    return sprintf('%s/sdk%d/%s', $cfg->val('General', 'outdir'), $sdk, $platform);
}

# Determines the mode that has to be passed to the "lunch" command
sub get_lunch_mode($$) {
    my $platform = shift;
    my $sdk = shift;

    if ($platform eq 'arm' || $platform eq 'armv5') {
        return ($sdk <= 17) ? 'full-eng' : 'aosp_arm-eng';
    } elsif ($platform eq 'x86') {
        return ($sdk <= 17) ? 'full_x86-eng' : 'aosp_x86-eng';
    } elsif ($platform eq 'arm64' && $sdk >= 21) {
        return 'aosp_arm64-eng';
    } else {
        print_error("Could not determine lunch mode for SDK $sdk, platform $platform");
        return undef;
    }
}

# Remove old logs
sub prune_logs($$) {
    my $platform = shift;
    my $sdk = shift;
    my $cutoff = shift || (time() - 86400);

    my $logdir = get_collection_dir($platform, $sdk) . '/logs';
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
