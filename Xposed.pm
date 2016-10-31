package Xposed;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(print_status print_error);

use Config::IniFiles;
use File::Path qw(make_path);
use File::ReadBackwards;
use File::Tail;
use FindBin qw($Bin);
use POSIX qw(strftime);
use Term::ANSIColor;

our $cfg;
my $MAX_SUPPORTED_SDK = 23;

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

sub timestamp() {
    return strftime('%Y%m%d_%H%M%S', localtime());
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
    my $cfg = Config::IniFiles->new( -file => $cfgname, -handle_trailing_comment => 1);
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
    my $version = $cfg->val('Build', 'version');
    if (!$version || $version !~ m/^\d+/) {
        print_error('[Build][version] must begin with an integer');
        return 0;
    }
    if ($version =~ m/^\d+\s*$/ && !$cfg->val('Build', 'official')) {
        print_error('[Build][version] should contain your custom suffix');
        return 0;
    }
    return 1;
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

# Expands the list of targets and replaces the "all" wildcard
sub expand_targets($;$) {
    my $spec = shift;
    my $print = shift || 0;

    my @result;
    my %seen;
    foreach (split(m/[\/ ]+/, $spec)) {
        my ($pfspec, $sdkspec) = split(m/[: ]+/, $_, 2);
        my @pflist = ($pfspec ne 'all' && $pfspec ne 'all+') ? split(m/[, ]/, $pfspec) : ('arm', 'x86', 'arm64', 'armv5');
        if ($pfspec eq 'all+') {
            push @pflist, 'host';
            push @pflist, 'hostd';
            $pfspec = 'all';
        }
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

# Check target SDK version and platform
sub check_target_sdk_platform($$;$) {
    my $platform = shift;
    my $sdk = shift;
    my $wildcard = shift || 0;

    if ($sdk < 15 || $sdk == 20 || $sdk > $MAX_SUPPORTED_SDK) {
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
    } elsif ($platform eq 'host' || $platform eq 'hostd') {
        if ($sdk < 21) {
            print_error('host builds are not supported prior to Android 5.0 (SDK 21)') unless $wildcard;
            return 0;
        }
    } elsif ($platform ne 'arm' && $platform ne 'x86') {
        print_error("Unsupported target platform $platform");
        return 0;
    }

    return 1;
}

# Returns the Xposed version
sub get_version() {
    my $version = $Xposed::cfg->val('Build', 'version');
    if ($version =~ m/%s/) {
        $version = sprintf($version, strftime('%Y%m%d', localtime()));
    }
    return $version;
}

# Returns the Xposed version number and the suffix to be used in file names
sub get_version_for_filename(;$) {
    my $version = shift || get_version();
    $version =~ m/^(\d+)(.*)/;
    my ($version_num, $suffix) = ($1, $2);
    if ($suffix) {
        $suffix =~ s/[\s\/|*"?<:>%()]+/-/g;
        $suffix =~ s/-{2,}/-/g;
        $suffix =~ s/^-|-$//g;
        $suffix = '-' . $suffix if $suffix;
    }
    return ($version_num, $suffix);
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

# Returns the directory to store symlinks to the ZIPs per versions
sub get_version_dir(;$) {
    my ($version, $suffix) = get_version_for_filename(shift);
    return sprintf('%s/versions/v%d%s', $cfg->val('General', 'outdir'), $version, $suffix);
}

# Determines the mode that has to be passed to the "lunch" command
sub get_lunch_mode($$) {
    my $platform = shift;
    my $sdk = shift;

    if ($platform eq 'arm' || $platform eq 'armv5' || $platform eq 'host' || $platform eq 'hostd') {
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

# Get default make parameters
sub get_make_parameters($$) {
    my $platform = shift;
    my $sdk = shift;

    my @params = split(m/\s+/, $cfg->val('Build', 'makeflags', '-j4'));

    # ARMv5 build need some special parameters
    if ($platform eq 'armv5') {
        push @params, 'OUT_DIR=out_armv5';
        push @params, 'TARGET_ARCH_VARIANT=armv5te';
        push @params, 'ARCH_ARM_HAVE_TLS_REGISTER=false';
        push @params, 'TARGET_CPU_SMP=false';
    } elsif ($sdk < 23) {
        push @params, 'TARGET_CPU_SMP=true';
    } elsif ($platform eq 'x86') {
        push @params, 'arch_variant_cflags=\'-march=prescott -mno-ssse3\'';
    }

    return @params;
}

sub compile($$$$$;$$$) {
    my $platform = shift;
    my $sdk = shift;
    my $params = shift;
    my $targets = shift;
    my $makefiles = shift;
    my $incremental = shift || 0;
    my $silent = shift || 0;
    my $logprefix = shift || 'build';

    # Initialize some general build parameters
    my $rootdir = get_rootdir($sdk) || return 0;
    my $lunch_mode = get_lunch_mode($platform, $sdk) || return 0;

    # Build the command string
    my $cdcmd = 'cd ' . $rootdir;
    my $envsetupcmd = '. build/envsetup.sh >/dev/null';
    my $lunchcmd = 'lunch ' . $lunch_mode . ' >/dev/null';
    my $makecmd = $incremental ? "ONE_SHOT_MAKEFILE='" . join(' ', @$makefiles) . "' make -C $rootdir -f build/core/main.mk " : 'make ';
    $makecmd .= join(' ', @$params, @$targets);
    my $cmd = join(' && ', $cdcmd, $envsetupcmd, $lunchcmd, $makecmd);
    print colored('Executing: ', 'magenta'), $cmd, "\n";

    my ($logfile, $tailpid);
    if ($silent) {
        my $logdir = get_collection_dir($platform, $sdk) . '/logs';
        make_path($logdir);
        $logfile = sprintf('%s/%s_%s.log', $logdir, $logprefix, timestamp());
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
        print colored('Build was successful!', 'green'), "\n\n" if $sdk < 21;
        return 1;
    } else {
        print colored('Build failed!', 'red'), "\n" if $sdk < 21;
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
        print "\n" if $silent || $sdk < 21;
        return 0;
    }
}

sub sign_zip($) {
    my $file = shift;
    my $signed = $file . '.signed';
    my $cmd = "java -jar $Bin/signapk.jar -w $Bin/signkey.x509.pem $Bin/signkey.pk8 $file $signed";
    system("bash -c \"$cmd\"") == 0 || return 0;
    rename($signed, $file);
    return 1;
}

sub gpg_sign($;$) {
    my $file = shift;
    unlink($file . '.asc');

    my $release = shift // 1;
    my $sign = $cfg->val('GPG', 'sign');
    return 1 if !$sign || $sign ne 'all' && !($release && $sign eq 'release');

    my $cmd = 'gpg -ab ';
    my $user = $cfg->val('GPG', 'user');
    $cmd .= "-u '$user' " if $user;
    $cmd .= $file;
    return system($cmd) == 0;
}

1;
